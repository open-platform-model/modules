# Bazarr — Implementation Tasks

**Module:** `opmodel.dev/modules/bazarr@v1`  
**Tier:** 2  
**Reference:** `design.md` in this directory

---

## Step 1: Scaffold Module Directory

Create the module directory structure:

```bash
mkdir -p modules/bazarr/cue.mod
```

Expected layout when complete:

```
modules/bazarr/
  cue.mod/
    module.cue       ← Step 2
  module.cue         ← Step 3
  components.cue     ← Step 4
  README.md          ← Step 5
```

---

## Step 2: Create cue.mod/module.cue

File: `modules/bazarr/cue.mod/module.cue`

```cue
module: "opmodel.dev/modules/bazarr@v1"
language: {
	version: "v0.15.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/core/v1alpha1@v1": {
		v: "v1.3.1"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.3"
	}
}
```

> **Do not manually edit version pins after creation.** Run `task update-deps` from the workspace root to upgrade them.

After creating this file, run from `modules/`:

```bash
task tidy
```

This fetches dependencies from the registry and creates `cue.mod/gen/` and `cue.mod/pkg/`.

---

## Step 3: Write module.cue

File: `modules/bazarr/module.cue`

Key elements to implement, in order:

1. **Package declaration:** `package bazarr`
2. **Imports:** `m "opmodel.dev/core/v1alpha1/module@v1"` and `schemas "opmodel.dev/opm/v1alpha1/schemas@v1"`
3. **Module definition:** embed `m.#Module`
4. **Metadata block** with `modulePath`, `name`, `version`, `description`, `defaultNamespace`
5. **`#storageVolume` definition** — copy the shape from `jellyfin/module.cue` (identical pattern)
6. **`#exportarrSidecar` definition** — image + port + apiKey
7. **`#bazarrIntegration` definition** — url + apiKey + optional baseUrl
8. **`#bazarrConfig` definition** — optional sonarr/radarr integrations + logLevel
9. **`#config` definition** — all fields per `design.md` schema section
10. **`debugValues` block** — concrete values for `cue vet -c` validation

```cue
// Package bazarr defines the Bazarr subtitle manager module.
// Single stateful container using the LinuxServer.io image.
// - module.cue: metadata and config schema
// - components.cue: workload, init container, optional exportarr sidecar
package bazarr

import (
	m       "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "bazarr"
	version:          "0.1.0"
	description:      "Bazarr subtitle manager — automatic subtitle downloads for Sonarr and Radarr"
	defaultNamespace: "bazarr"
}

#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string
	storageClass?: string
	server?:       string
	path?:         string
}

#exportarrSidecar: {
	image: schemas.#Image & {
		repository: string | *"ghcr.io/onedr0p/exportarr"
		tag:        string | *"latest"
		digest:     string | *""
	}
	port:   int | *9707
	apiKey: schemas.#Secret
}

#bazarrIntegration: {
	url:      string
	apiKey:   schemas.#Secret
	baseUrl?: string | *""
}

#bazarrConfig: {
	sonarr?:   #bazarrIntegration
	radarr?:   #bazarrIntegration
	logLevel?: "DEBUG" | "INFO" | "WARNING" | "ERROR" | *"INFO"
}

#config: {
	image: schemas.#Image & {
		repository: string | *"lscr.io/linuxserver/bazarr"
		tag:        string | *"latest"
		digest:     string | *""
	}

	port:     int & >0 & <=65535 | *6767
	puid:     int | *1000
	pgid:     int | *1000
	timezone: string | *"Europe/Stockholm"
	umask?:   string

	storage: {
		config: #storageVolume & {
			mountPath: *"/config" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"5Gi"
		}
		tv: #storageVolume & {
			mountPath: *"/tv" | string
		}
		movies: #storageVolume & {
			mountPath: *"/movies" | string
		}
	}

	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"
	resources?:  schemas.#ResourceRequirementsSchema

	exportarr?:   #exportarrSidecar
	bazarrConfig?: #bazarrConfig
}

debugValues: {
	image: {
		repository: "lscr.io/linuxserver/bazarr"
		tag:        "latest"
		digest:     ""
	}
	port:        6767
	puid:        3005
	pgid:        3005
	timezone:    "Europe/Stockholm"
	serviceType: "ClusterIP"
	storage: {
		config: {
			mountPath:    "/config"
			type:         "pvc"
			size:         "5Gi"
			storageClass: "local-path"
		}
		tv: {
			mountPath: "/tv"
			type:      "nfs"
			server:    "192.168.1.10"
			path:      "/mnt/data/media/tv"
		}
		movies: {
			mountPath: "/movies"
			type:      "nfs"
			server:    "192.168.1.10"
			path:      "/mnt/data/media/movies"
		}
	}
	bazarrConfig: {
		logLevel: "INFO"
	}
}
```

---

## Step 4: Write components.cue

File: `modules/bazarr/components.cue`

### Imports

```cue
package bazarr

import (
	"encoding/yaml"

	resources_config   "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage  "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload    "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network     "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security    "opmodel.dev/opm/v1alpha1/traits/security@v1"
)
```

### `#components` structure

```cue
#components: {
	bazarr: {
		resources_workload.#Container
		resources_storage.#Volumes
		resources_config.#ConfigMaps
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_network.#Expose
		traits_security.#SecurityContext

		metadata: name: "bazarr"
		metadata: labels: "core.opmodel.dev/workload-type": "stateful"

		_volumes: spec.volumes

		spec: {
			scaling: count: 1
			restartPolicy: "Always"

			// --- Init container: seed config.yaml on first boot ---
			// Pattern: busybox copies /seed/config.yaml → /config/config/config.yaml
			// only if the destination file does not already exist.
			if #config.bazarrConfig != _|_ {
				initContainers: [{
					name: "config-seed"
					image: {
						repository: "busybox"
						tag:        "latest"
						digest:     ""
					}
					command: ["sh", "-c", """
						mkdir -p /config/config
						[ -f /config/config/config.yaml ] || cp /seed/config.yaml /config/config/config.yaml
						"""]
					volumeMounts: {
						config: {
							name:      "config"
							mountPath: "/config"
						}
						"bazarr-config": {
							name:      "bazarr-config"
							mountPath: "/seed"
							readOnly:  true
						}
					}
				}]
			}

			container: {
				name:  "bazarr"
				image: #config.image
				ports: http: {
					name:       "http"
					targetPort: #config.port
				}
				env: {
					PUID: { name: "PUID", value: "\(#config.puid)" }
					PGID: { name: "PGID", value: "\(#config.pgid)" }
					TZ:   { name: "TZ",   value: #config.timezone  }
					if #config.umask != _|_ {
						UMASK: { name: "UMASK", value: #config.umask }
					}
				}
				livenessProbe: {
					httpGet: { path: "/", port: #config.port }
					initialDelaySeconds: 30
					periodSeconds:       10
					timeoutSeconds:      5
					failureThreshold:    3
				}
				readinessProbe: {
					httpGet: { path: "/", port: #config.port }
					initialDelaySeconds: 15
					periodSeconds:       10
					timeoutSeconds:      3
					failureThreshold:    3
				}
				if #config.resources != _|_ {
					resources: #config.resources
				}
				volumeMounts: {
					config: _volumes["config"] & { mountPath: #config.storage.config.mountPath }
					tv:     _volumes["tv"]     & { mountPath: #config.storage.tv.mountPath }
					movies: _volumes["movies"] & { mountPath: #config.storage.movies.mountPath }
				}
			}

			// --- Optional Exportarr sidecar ---
			if #config.exportarr != _|_ {
				sidecarContainers: [{
					name:  "exportarr"
					image: #config.exportarr.image
					env: {
						PORT:   { name: "PORT",   value: "\(#config.exportarr.port)" }
						URL:    { name: "URL",    value: "http://localhost:\(#config.port)" }
						APIKEY: {
							name: "APIKEY"
							valueFrom: secretKeyRef: {
								name: #config.exportarr.apiKey.$secretName
								key:  #config.exportarr.apiKey.$dataKey
							}
						}
					}
					ports: metrics: {
						name:       "metrics"
						targetPort: #config.exportarr.port
					}
				}]
			}

			expose: {
				ports: http: container.ports.http & { exposedPort: #config.port }
				type: #config.serviceType
			}

			// --- ConfigMap for config.yaml seed ---
			if #config.bazarrConfig != _|_ {
				configMaps: {
					"bazarr-config": {
						immutable: false
						data: {
							"config.yaml": yaml.Marshal({
								general: {
									ip:         "0.0.0.0"
									port:       #config.port
									base_url:   ""
									use_sonarr: #config.bazarrConfig.sonarr != _|_
									use_radarr: #config.bazarrConfig.radarr != _|_
								}
								// NOTE: apikey fields are seeded as empty strings.
								// Configure via Bazarr UI after first boot, or extend
								// the init container to patch values from Secrets.
								if #config.bazarrConfig.sonarr != _|_ {
									sonarr: {
										ip:       "sonarr.sonarr.svc.cluster.local"
										port:     8989
										apikey:   ""
										base_url: #config.bazarrConfig.sonarr.baseUrl
									}
								}
								if #config.bazarrConfig.radarr != _|_ {
									radarr: {
										ip:       "radarr.radarr.svc.cluster.local"
										port:     7878
										apikey:   ""
										base_url: #config.bazarrConfig.radarr.baseUrl
									}
								}
								log: { level: #config.bazarrConfig.logLevel }
							})
						}
					}
				}
			}

			// --- Volumes ---
			volumes: {
				// config PVC/NFS/emptyDir
				config: {
					name: "config"
					if #config.storage.config.type == "pvc" {
						persistentClaim: {
							size: #config.storage.config.size
							if #config.storage.config.storageClass != _|_ {
								storageClass: #config.storage.config.storageClass
							}
						}
					}
					if #config.storage.config.type == "nfs" {
						nfs: { server: #config.storage.config.server, path: #config.storage.config.path }
					}
					if #config.storage.config.type == "emptyDir" { emptyDir: {} }
				}

				// tv volume
				tv: {
					name: "tv"
					if #config.storage.tv.type == "pvc" {
						persistentClaim: {
							size: #config.storage.tv.size
							if #config.storage.tv.storageClass != _|_ {
								storageClass: #config.storage.tv.storageClass
							}
						}
					}
					if #config.storage.tv.type == "nfs" {
						nfs: { server: #config.storage.tv.server, path: #config.storage.tv.path }
					}
					if #config.storage.tv.type == "emptyDir" { emptyDir: {} }
				}

				// movies volume
				movies: {
					name: "movies"
					if #config.storage.movies.type == "pvc" {
						persistentClaim: {
							size: #config.storage.movies.size
							if #config.storage.movies.storageClass != _|_ {
								storageClass: #config.storage.movies.storageClass
							}
						}
					}
					if #config.storage.movies.type == "nfs" {
						nfs: { server: #config.storage.movies.server, path: #config.storage.movies.path }
					}
					if #config.storage.movies.type == "emptyDir" { emptyDir: {} }
				}

				// ConfigMap volume for seed — only when bazarrConfig is set
				if #config.bazarrConfig != _|_ {
					"bazarr-config": {
						name:      "bazarr-config"
						configMap: spec.configMaps["bazarr-config"]
					}
				}
			}
		}
	}
}
```

### Key patterns to note

- **Init container guard:** `if #config.bazarrConfig != _|_` — init container and its ConfigMap volume are only emitted when the operator sets `bazarrConfig`. Without it, Bazarr starts fresh and uses its own defaults.
- **Exportarr guard:** `if #config.exportarr != _|_` — sidecar container is entirely absent when not configured.
- **Config path:** Bazarr's config is at `/config/config/config.yaml` (the nested `config/` subdir within `/config`). The init container `mkdir -p /config/config` ensures the subdirectory exists before copying.
- **API keys in YAML:** `apikey: ""` is intentional — these are seeded empty. See design.md for the limitation and enhancement path.

---

## Step 5: Write README.md

Create `modules/bazarr/README.md` covering:
- Overview (1–2 sentences)
- Architecture diagram (copy from design.md)
- Quick start: minimal release values example
- Full `#config` reference table
- Storage section: how to configure shared NFS mounts with Sonarr/Radarr
- Exportarr metrics: how to enable + what Secret to create
- Known limitations: API key seeding (must configure via UI or extend init container)

---

## Step 6: Tidy & Validate

From `modules/`:

```bash
# Fetch/update dependencies
task tidy

# Format all CUE files
task fmt

# Validate schema (abstract — no concrete check)
task vet

# Validate with debugValues (concrete check)
task vet CONCRETE=true
```

All four commands must pass before proceeding.

If `task vet CONCRETE=true` fails on a missing field in `debugValues`, add the required concrete value there. Do not relax the `#config` constraints.

---

## Step 7: Create Dev Release

Create the release file at `releases/<env>/bazarr/release.cue`:

```cue
package bazarr

import (
	mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
	m  "opmodel.dev/modules/bazarr@v1"
)

mr.#ModuleRelease

metadata: {
	name:      "bazarr"
	namespace: "bazarr"
}

#module: m

values: {
	image: {
		repository: "lscr.io/linuxserver/bazarr"
		tag:        "latest"
		digest:     ""
	}
	port:        6767
	puid:        3005
	pgid:        3005
	timezone:    "Europe/Stockholm"
	serviceType: "ClusterIP"

	storage: {
		config: {
			mountPath:    "/config"
			type:         "pvc"
			size:         "5Gi"
			storageClass: "local-path"
		}
		tv: {
			mountPath: "/tv"
			type:      "nfs"
			server:    "192.168.1.10"
			path:      "/mnt/data/media/tv"
		}
		movies: {
			mountPath: "/movies"
			type:      "nfs"
			server:    "192.168.1.10"
			path:      "/mnt/data/media/movies"
		}
	}

	bazarrConfig: {
		sonarr: {
			url:    "http://sonarr.sonarr.svc.cluster.local:8989"
			apiKey: { $secretName: "sonarr-secrets", $dataKey: "api-key" }
		}
		radarr: {
			url:    "http://radarr.radarr.svc.cluster.local:7878"
			apiKey: { $secretName: "radarr-secrets", $dataKey: "api-key" }
		}
		logLevel: "INFO"
	}
}
```

Also create the Kubernetes namespace and required Secrets before deploying:

```bash
kubectl create namespace bazarr
# Create bazarr-secrets only if enabling Exportarr:
kubectl create secret generic bazarr-secrets \
  --namespace bazarr \
  --from-literal=api-key=<bazarr-api-key>
```

---

## Step 8: Validate Release

From `releases/`:

```bash
task fmt
task vet
task check
```

All must pass. If the release references a module version not yet published, publish the module first (Step 9), then re-run.

---

## Step 9: Publish Module

From `modules/`:

```bash
# Preview what will be published
task publish:dry

# Publish bazarr module only
task publish:one MODULE=bazarr
```

After publishing, update `releases/<env>/bazarr/cue.mod/module.cue` with the new version pin (or run `task update-deps` from the workspace root).

> Verify the module appears in the registry:
> ```bash
> opm module versions opmodel.dev/modules/bazarr
> ```
