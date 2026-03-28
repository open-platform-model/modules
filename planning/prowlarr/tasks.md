# Prowlarr — Implementation Tasks

**Module:** `opmodel.dev/modules/prowlarr@v1`  
**Tier:** 3  
**Reference:** `design.md` in this directory

---

## Step 1: Scaffold Module Directory

Create the module directory structure:

```bash
mkdir -p modules/prowlarr/cue.mod
```

Expected layout when complete:

```
modules/prowlarr/
  cue.mod/
    module.cue       ← Step 2
  module.cue         ← Step 3
  components.cue     ← Step 4
  README.md          ← Step 5
```

---

## Step 2: Create cue.mod/module.cue

File: `modules/prowlarr/cue.mod/module.cue`

```cue
module: "opmodel.dev/modules/prowlarr@v1"
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

File: `modules/prowlarr/module.cue`

Key elements to implement, in order:

1. **Package declaration:** `package prowlarr`
2. **Imports:** `m "opmodel.dev/core/v1alpha1/module@v1"` and `schemas "opmodel.dev/opm/v1alpha1/schemas@v1"`
3. **Module definition:** embed `m.#Module`
4. **Metadata block** with `modulePath`, `name`, `version`, `description`, `defaultNamespace`
5. **`#storageVolume` definition** — copy the shape from `jellyfin/module.cue` (identical pattern)
6. **`#exportarrSidecar` definition** — image + port + apiKey
7. **`#servarrConfig` definition** — authMethod, authRequired, branch, logLevel, urlBase, instanceName
8. **`#config` definition** — all fields per `design.md` schema section
9. **`debugValues` block** — concrete values for `cue vet -c` validation

```cue
// Package prowlarr defines the Prowlarr indexer manager module.
// Single stateful container using the LinuxServer.io image.
// - module.cue: metadata and config schema
// - components.cue: workload, init container, optional exportarr sidecar
package prowlarr

import (
	m       "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "prowlarr"
	version:          "0.1.0"
	description:      "Prowlarr indexer manager — centralised indexer configuration for the arr stack"
	defaultNamespace: "prowlarr"
}

// #storageVolume — shared schema for all volume entries
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string
	storageClass?: string
	server?:       string
	path?:         string
}

// #exportarrSidecar — optional Prometheus metrics sidecar
#exportarrSidecar: {
	image: schemas.#Image & {
		repository: string | *"ghcr.io/onedr0p/exportarr"
		tag:        string | *"latest"
		digest:     string | *""
	}
	port:   int | *9707
	apiKey: schemas.#Secret
}

// #servarrConfig — Servarr XML config seed values
// Shared pattern with Sonarr and Radarr
#servarrConfig: {
	authMethod?:   "Forms" | "Basic" | "External" | *"External"
	authRequired?: "Enabled" | "DisabledForLocalAddresses" | *"DisabledForLocalAddresses"
	branch?:       string | *"master"
	logLevel?:     "trace" | "debug" | "info" | "warn" | "error" | *"info"
	urlBase?:      string | *""
	instanceName?: string | *"Prowlarr"
}

#config: {
	image: schemas.#Image & {
		repository: string | *"lscr.io/linuxserver/prowlarr"
		tag:        string | *"latest"
		digest:     string | *""
	}

	port:     int & >0 & <=65535 | *9696
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
	}

	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"
	resources?:  schemas.#ResourceRequirementsSchema

	exportarr?:    #exportarrSidecar
	servarrConfig?: #servarrConfig
}

debugValues: {
	image: {
		repository: "lscr.io/linuxserver/prowlarr"
		tag:        "latest"
		digest:     ""
	}
	port:        9696
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
	}
	servarrConfig: {
		authMethod:   "External"
		authRequired: "DisabledForLocalAddresses"
		branch:       "master"
		logLevel:     "info"
		urlBase:      ""
		instanceName: "Prowlarr"
	}
}
```

---

## Step 4: Write components.cue

File: `modules/prowlarr/components.cue`

### Imports

```cue
package prowlarr

import (
	resources_config   "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage  "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload    "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network     "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security    "opmodel.dev/opm/v1alpha1/traits/security@v1"
)
```

Note: `encoding/yaml` is **not** imported here — Prowlarr uses XML string interpolation,
not YAML marshalling, so no `encoding/yaml` or `encoding/xml` import is needed.

### `#components` structure

The key pattern is the **Servarr XML init-copy**. The config.xml is rendered as a CUE
multi-line string and stored in a ConfigMap. An init container copies it to `/config/config.xml`
only if the file does not already exist.

```cue
#components: {
	prowlarr: {
		resources_workload.#Container
		resources_storage.#Volumes
		resources_config.#ConfigMaps
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_network.#Expose
		traits_security.#SecurityContext

		metadata: name: "prowlarr"
		metadata: labels: "core.opmodel.dev/workload-type": "stateful"

		_volumes: spec.volumes

		spec: {
			scaling: count: 1
			restartPolicy: "Always"

			// --- Init container: seed config.xml on first boot ---
			// Pattern: busybox copies /seed/config.xml → /config/config.xml
			// only if the destination file does not already exist.
			// This preserves Prowlarr's auto-generated API key and runtime state.
			if #config.servarrConfig != _|_ {
				initContainers: [{
					name: "config-seed"
					image: {
						repository: "busybox"
						tag:        "latest"
						digest:     ""
					}
					command: ["sh", "-c", "[ -f /config/config.xml ] || cp /seed/config.xml /config/config.xml"]
					volumeMounts: {
						config: {
							name:      "config"
							mountPath: "/config"
						}
						"prowlarr-config-seed": {
							name:      "prowlarr-config-seed"
							mountPath: "/seed"
							readOnly:  true
						}
					}
				}]
			}

			container: {
				name:  "prowlarr"
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

			// --- ConfigMap: Servarr XML seed ---
			// Rendered via CUE string interpolation — no encoding/xml needed.
			// <ApiKey> is left empty so Prowlarr auto-generates a UUID on first boot.
			if #config.servarrConfig != _|_ {
				configMaps: {
					"prowlarr-config-seed": {
						immutable: false
						data: {
							"config.xml": """
								<Config>
								  <BindAddress>*</BindAddress>
								  <Port>\(#config.port)</Port>
								  <SslPort>6969</SslPort>
								  <EnableSsl>False</EnableSsl>
								  <LaunchBrowser>True</LaunchBrowser>
								  <ApiKey></ApiKey>
								  <AuthenticationMethod>\(#config.servarrConfig.authMethod)</AuthenticationMethod>
								  <AuthenticationRequired>\(#config.servarrConfig.authRequired)</AuthenticationRequired>
								  <Branch>\(#config.servarrConfig.branch)</Branch>
								  <LogLevel>\(#config.servarrConfig.logLevel)</LogLevel>
								  <SslCertPath></SslCertPath>
								  <SslCertPassword></SslCertPassword>
								  <UrlBase>\(#config.servarrConfig.urlBase)</UrlBase>
								  <InstanceName>\(#config.servarrConfig.instanceName)</InstanceName>
								  <UpdateMechanism>Docker</UpdateMechanism>
								</Config>
								"""
						}
					}
				}
			}

			// --- Volumes ---
			volumes: {
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

				// ConfigMap seed volume — only when servarrConfig is set
				if #config.servarrConfig != _|_ {
					"prowlarr-config-seed": {
						name:      "prowlarr-config-seed"
						configMap: spec.configMaps["prowlarr-config-seed"]
					}
				}
			}
		}
	}
}
```

### Key patterns to note

- **Servarr XML string interpolation:** Use CUE's triple-quoted multi-line string with `\(expr)` interpolation — no XML library needed. This is the same pattern Sonarr and Radarr use.
- **`<ApiKey>` is empty:** Prowlarr generates a UUID on first boot and writes it into `/config/config.xml`. Seeding it empty is intentional — if you pre-set a value, Prowlarr may overwrite it anyway.
- **No media volumes:** Unlike Bazarr, Prowlarr needs only the `config` volume. The `tv` and `movies` pattern from Bazarr does not apply here.
- **Init container guard:** `if #config.servarrConfig != _|_` — init container and ConfigMap seed volume are only emitted when `servarrConfig` is defined. Without it, Prowlarr self-initialises on first boot.
- **Exportarr guard:** `if #config.exportarr != _|_` — sidecar is entirely absent when not configured.

---

## Step 5: Write README.md

Create `modules/prowlarr/README.md` covering:
- Overview (1–2 sentences)
- Architecture diagram (copy from design.md)
- Quick start: minimal release values example
- Full `#config` reference table
- Servarr config seed: what fields are seeded and which are auto-generated
- Exportarr metrics: how to enable + what Secret to create
- Known limitations: API key is auto-generated (must capture from UI to use Exportarr)

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

Create the release file at `releases/<env>/prowlarr/release.cue`:

```cue
package prowlarr

import (
	mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
	m  "opmodel.dev/modules/prowlarr@v1"
)

mr.#ModuleRelease

metadata: {
	name:      "prowlarr"
	namespace: "prowlarr"
}

#module: m

values: {
	image: {
		repository: "lscr.io/linuxserver/prowlarr"
		tag:        "latest"
		digest:     ""
	}
	port:        9696
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
	}

	servarrConfig: {
		authMethod:   "External"
		authRequired: "DisabledForLocalAddresses"
		branch:       "master"
		logLevel:     "info"
		urlBase:      ""
		instanceName: "Prowlarr"
	}

	// Uncomment to enable Exportarr metrics (requires prowlarr-secrets Secret)
	// exportarr: {
	//     image: { repository: "ghcr.io/onedr0p/exportarr", tag: "latest", digest: "" }
	//     port:   9707
	//     apiKey: { $secretName: "prowlarr-secrets", $dataKey: "api-key" }
	// }
}
```

Create the namespace before deploying:

```bash
kubectl create namespace prowlarr
```

After first boot, retrieve the auto-generated API key from the Prowlarr UI
(Settings → General → API Key) and create the Secret if enabling Exportarr:

```bash
kubectl create secret generic prowlarr-secrets \
  --namespace prowlarr \
  --from-literal=api-key=<prowlarr-api-key>
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

# Publish prowlarr module only
task publish:one MODULE=prowlarr
```

After publishing, update `releases/<env>/prowlarr/cue.mod/module.cue` with the new version pin (or run `task update-deps` from the workspace root).

> Verify the module appears in the registry:
> ```bash
> opm module versions opmodel.dev/modules/prowlarr
> ```
