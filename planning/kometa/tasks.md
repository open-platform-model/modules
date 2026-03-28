# Kometa Module Implementation Tasks

**Tier:** 3  
**Workload type:** CronJob (scheduled task)  
**Key patterns:** `#ScheduledTaskWorkload` blueprint, `encoding/yaml` config rendering,
env-var-based secret injection, subPath ConfigMap mount

---

## Step 1: Scaffold Module Directory

Create the module directory structure:

```bash
mkdir -p modules/kometa/cue.mod
```

Expected layout after all steps:
```
modules/kometa/
  cue.mod/
    module.cue        ← Step 2
  module.cue          ← Step 3
  components.cue      ← Step 4
  README.md           ← Step 5
```

---

## Step 2: Create cue.mod/module.cue

Create `modules/kometa/cue.mod/module.cue`:

```cue
module: "opmodel.dev/modules/kometa@v1"
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

> Do **not** manually edit version pins. Run `task update-deps` from the workspace root
> after scaffolding to pull the latest compatible versions.

---

## Step 3: Write module.cue

Create `modules/kometa/module.cue`. This file defines the `#ScheduledTaskWorkload`
schema and all Kometa-specific types including the library definition DSL.

```cue
// Package kometa defines the Kometa metadata manager module.
// Scheduled-task (CronJob) workload that enriches Plex library metadata on a schedule:
// - module.cue: metadata and config schema
// - components.cue: component definitions
package kometa

import (
	m       "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "kometa"
	version:          "0.1.0"
	description:      "Kometa metadata manager - automated collection artwork and metadata overlays for Plex"
	defaultNamespace: "kometa"
}

// #storageVolume is the shared schema for all storage entries.
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string  // required when type == "pvc"
	storageClass?: string  // optional; only used when type == "pvc"
	server?:       string  // required when type == "nfs"
	path?:         string  // required when type == "nfs"
}

// #kometaPath — a single path entry in metadata_path or overlay_path.
// Exactly one field should be set per entry.
#kometaPath: {
	pmm?:  string  // PMM preset name, e.g. "basic", "imdb", "ribbon"
	file?: string  // Local file path inside the container
	url?:  string  // Remote URL to a YAML definition
	git?:  string  // Git path (Kometa git resolver format)
}

// #kometaLibrary — configuration for a single Plex library.
// The library name key must exactly match the Plex library display name.
#kometaLibrary: {
	// Metadata collection definitions applied to this library
	metadataPaths?: [...#kometaPath]
	// Overlay definitions (badges, ratings, resolution labels, etc.)
	overlayPaths?: [...#kometaPath]
	// Mass operations applied to all items in the library
	operations?: {
		massCriticRatingUpdate?:        string  // e.g. "mdb_tomatoesaudience"
		massAudienceRatingUpdate?:      string
		massContentRatingUpdate?:       string
		massEpisodeCriticRatingUpdate?: string  // TV libraries only
	}
	// Override run time for this library (e.g. "03:00"); omit to use global schedule
	scheduleTimes?: string
}

// #config — top-level module configuration schema
#config: {
	// Container image — not LinuxServer.io; no PUID/PGID
	image: schemas.#Image & {
		repository: string | *"kometateam/kometa"
		tag:        string | *"latest"
		digest:     string | *""
	}

	// Container timezone (IANA format) — affects Kometa's internal scheduler
	timezone: string | *"Europe/Stockholm"

	// CronJob schedule expression — when to run the metadata pass
	schedule: string | *"0 2 * * *"

	// Storage volumes
	storage: {
		// Persistent cache for overlay images, posters, and logs between runs
		config: #storageVolume & {
			mountPath: *"/config" | string
			type:      *"pvc" | "emptyDir" | "nfs"
			size:      string | *"2Gi"
		}
	}

	// Resource requests and limits
	resources?: schemas.#ResourceRequirementsSchema

	// Plex server URL — full HTTP URL including port
	plexUrl: string

	// Plex authentication token — delivered via KOMETA_PLEX_TOKEN env var
	plexToken: schemas.#Secret & {
		$secretName:  string | *"kometa-secrets"
		$dataKey:     string | *"plex-token"
		$description: "Plex authentication token for Kometa"
	}

	// TMDb API key — delivered via KOMETA_TMDB_APIKEY env var (optional)
	tmdbApiKey?: schemas.#Secret & {
		$secretName:  string | *"kometa-secrets"
		$dataKey:     string | *"tmdb-api-key"
		$description: "TMDb API key for metadata enrichment"
	}

	// Tautulli connection for play count stats (optional)
	// WARNING: Kometa has no env var override for tautulli.apikey.
	// The API key will appear in the ConfigMap. See design.md for alternatives.
	tautulli?: {
		url:    string
		apiKey: schemas.#Secret
	}

	// Library definitions keyed by exact Plex library name
	libraries?: [LibraryName=string]: #kometaLibrary
}

debugValues: {
	image: {
		repository: "kometateam/kometa"
		tag:        "latest"
		digest:     ""
	}
	timezone: "Europe/Stockholm"
	schedule: "0 2 * * *"
	storage: {
		config: {
			mountPath:    "/config"
			type:         "pvc"
			size:         "2Gi"
			storageClass: "local-path"
		}
	}
	resources: {
		requests: { cpu: "200m", memory: "512Mi" }
		limits:   { cpu: "2000m", memory: "2Gi" }
	}
	plexUrl: "http://plex.plex.svc.cluster.local:32400"
	plexToken: {
		$secretName: "kometa-secrets"
		$dataKey:    "plex-token"
	}
	tmdbApiKey: {
		$secretName: "kometa-secrets"
		$dataKey:    "tmdb-api-key"
	}
	libraries: {
		Movies: {
			metadataPaths: [{ pmm: "basic" }, { pmm: "imdb" }]
			overlayPaths:  [{ pmm: "ribbon" }]
			operations: {
				massCriticRatingUpdate: "mdb_tomatoesaudience"
			}
		}
		"TV Shows": {
			metadataPaths: [{ pmm: "basic" }]
			operations: {
				massEpisodeCriticRatingUpdate: "tmdb"
			}
		}
	}
}
```

---

## Step 4: Write components.cue

Create `modules/kometa/components.cue`. This uses the `#ScheduledTaskWorkload` blueprint
for CronJob scheduling. Key implementation points:

- `KOMETA_RUN=true` is **required** — without it, Kometa enters its internal scheduler
  loop and the Job Pod never exits, causing the CronJob to hang indefinitely
- `KOMETA_CONFIG` points to `/config/config.yml` (the subPath-mounted ConfigMap file)
- `plexToken` and `tmdbApiKey` are delivered via `secretKeyRef` env vars
- The config PVC is mounted at `/config/`; the ConfigMap file is overlaid at
  `/config/config.yml` via `subPath` — preserving the cache directory underneath
- `encoding/yaml` renders the full `config.yml` from the `#config.libraries` CUE struct

```cue
// Components defines the Kometa scheduled metadata manager workload.
// CronJob workload — runs on schedule and exits; no persistent HTTP service.
package kometa

import (
	"encoding/yaml"

	blueprints_workload "opmodel.dev/opm/v1alpha1/blueprints/workload@v1"
	resources_config    "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_storage   "opmodel.dev/opm/v1alpha1/resources/storage@v1"
)

// #components contains the Kometa CronJob workload definition.
#components: {

	/////////////////////////////////////////////////////////////////
	//// Kometa - Plex Metadata Manager (CronJob)
	/////////////////////////////////////////////////////////////////

	kometa: {
		blueprints_workload.#ScheduledTaskWorkload
		resources_config.#ConfigMaps
		resources_storage.#Volumes

		metadata: name: "kometa"
		metadata: labels: "core.opmodel.dev/workload-type": "scheduled-task"

		_volumes: spec.volumes

		spec: {
			scheduledTaskWorkload: {
				container: {
					name:  "kometa"
					image: #config.image
					env: {
						TZ: { name: "TZ", value: #config.timezone }
						// KOMETA_CONFIG tells Kometa where to find its config file
						KOMETA_CONFIG: { name: "KOMETA_CONFIG", value: "/config/config.yml" }
						// KOMETA_RUN=true forces immediate execution then exit.
						// This is essential for CronJob usage — without it, Kometa
						// enters its internal scheduler and the Job Pod never completes.
						KOMETA_RUN: { name: "KOMETA_RUN", value: "true" }
						// Plex token — injected from Secret, not embedded in config.yml
						KOMETA_PLEX_TOKEN: {
							name: "KOMETA_PLEX_TOKEN"
							valueFrom: secretKeyRef: {
								name: #config.plexToken.$secretName
								key:  #config.plexToken.$dataKey
							}
						}
						// TMDb API key — injected from Secret when configured
						if #config.tmdbApiKey != _|_ {
							KOMETA_TMDB_APIKEY: {
								name: "KOMETA_TMDB_APIKEY"
								valueFrom: secretKeyRef: {
									name: #config.tmdbApiKey.$secretName
									key:  #config.tmdbApiKey.$dataKey
								}
							}
						}
					}
					if #config.resources != _|_ {
						resources: #config.resources
					}
					volumeMounts: {
						// Persistent config volume — cache, logs, overlay images
						config: _volumes["config"] & {
							mountPath: #config.storage.config.mountPath
						}
						// ConfigMap mounted as a single file over the config volume.
						// subPath ensures only config.yml is overlaid — the rest of
						// /config/ remains the persistent PVC cache directory.
						"kometa-config": _volumes["kometa-config"] & {
							mountPath: "\(#config.storage.config.mountPath)/config.yml"
							subPath:   "config.yml"
							readOnly:  true
						}
					}
				}

				// OnFailure: retry on transient failures (API timeouts, network issues)
				restartPolicy: "OnFailure"

				cronJobConfig: {
					scheduleCron: #config.schedule
					// Forbid: prevent overlapping runs if a job takes longer than expected
					concurrencyPolicy:          "Forbid"
					successfulJobsHistoryLimit: 3
					failedJobsHistoryLimit:     1
				}
			}

			// ConfigMap: full config.yml rendered from #config using encoding/yaml
			configMaps: {
				"kometa-config": {
					immutable: false
					data: {
						// Plex token and TMDb key are intentionally omitted from the
						// YAML — Kometa reads them from KOMETA_PLEX_TOKEN and
						// KOMETA_TMDB_APIKEY environment variables instead.
						"config.yml": yaml.Marshal({
							plex: {
								url: #config.plexUrl
								// token: omitted — delivered via KOMETA_PLEX_TOKEN env var
							}

							if #config.tmdbApiKey != _|_ {
								tmdb: {
									// apikey: omitted — delivered via KOMETA_TMDB_APIKEY env var
									region: ""
								}
							}

							if #config.tautulli != _|_ {
								tautulli: {
									url: #config.tautulli.url
									// WARNING: apikey appears in ConfigMap (not a Secret).
									// See design.md §Declarative Configuration Strategy
									// for the init-container patch alternative.
									apikey: ""  // placeholder — set manually or use init patch
								}
							}

							if #config.libraries != _|_ {
								libraries: {
									for libName, lib in #config.libraries {
										(libName): {
											if lib.metadataPaths != _|_ {
												metadata_path: [
													for p in lib.metadataPaths {
														if p.pmm != _|_  { pmm:  p.pmm }
														if p.file != _|_ { file: p.file }
														if p.url != _|_  { url:  p.url }
														if p.git != _|_  { git:  p.git }
													},
												]
											}
											if lib.overlayPaths != _|_ {
												overlay_path: [
													for p in lib.overlayPaths {
														if p.pmm != _|_  { pmm:  p.pmm }
														if p.file != _|_ { file: p.file }
														if p.url != _|_  { url:  p.url }
														if p.git != _|_  { git:  p.git }
													},
												]
											}
											if lib.operations != _|_ {
												operations: {
													if lib.operations.massCriticRatingUpdate != _|_ {
														mass_critic_rating_update: lib.operations.massCriticRatingUpdate
													}
													if lib.operations.massAudienceRatingUpdate != _|_ {
														mass_audience_rating_update: lib.operations.massAudienceRatingUpdate
													}
													if lib.operations.massContentRatingUpdate != _|_ {
														mass_content_rating_update: lib.operations.massContentRatingUpdate
													}
													if lib.operations.massEpisodeCriticRatingUpdate != _|_ {
														mass_episode_critic_rating_update: lib.operations.massEpisodeCriticRatingUpdate
													}
												}
											}
											if lib.scheduleTimes != _|_ {
												schedule_time: lib.scheduleTimes
											}
										}
									}
								}
							}
						})
					}
				}
			}

			// Volumes: persistent config PVC and ConfigMap file volume
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
					if #config.storage.config.type == "emptyDir" {
						emptyDir: {}
					}
					if #config.storage.config.type == "nfs" {
						nfs: {
							server: #config.storage.config.server
							path:   #config.storage.config.path
						}
					}
				}
				"kometa-config": {
					name:      "kometa-config"
					configMap: spec.configMaps["kometa-config"]
				}
			}
		}
	}
}
```

---

## Step 5: Write README.md

Create `modules/kometa/README.md` with:
- Overview: what Kometa does (metadata, overlays, collections) and supported backends
- Architecture: CronJob lifecycle diagram, config file flow, secret injection
- Prerequisites: Plex server running and accessible; TMDb API key obtained
- Quick start: minimal release values block with single library
- Configuration reference: table of all `#config` fields with types, defaults, descriptions
- Library configuration: explain `#kometaLibrary` fields, PMM preset names
- Secret creation instructions:
  ```bash
  kubectl create secret generic kometa-secrets \
    --namespace kometa \
    --from-literal=plex-token=<your-plex-token> \
    --from-literal=tmdb-api-key=<your-tmdb-api-key>
  ```
- How to get the Plex token: Account → Preferences → (view page source) → `X-Plex-Token`
- Tautulli limitation: explain why the API key appears in ConfigMap and reference design.md
- Manual trigger: how to run Kometa immediately via `kubectl create job`
- Troubleshooting: `KOMETA_RUN=true` requirement; subPath mount behaviour

---

## Step 6: Tidy & Validate

Run from `modules/`:

```bash
# Tidy CUE dependencies for the new module
task tidy

# Format all CUE files
task fmt

# Validate schema (non-concrete)
task vet

# Validate with concrete debugValues
task vet CONCRETE=true

# Combined check (fmt + vet)
task check
```

Expected output: no errors. Common issues to watch for:

**`encoding/yaml` marshalling:**
- CUE list comprehensions inside `yaml.Marshal` must produce valid CUE lists — test
  with concrete `debugValues` to ensure the YAML output is well-formed
- Library keys with spaces (e.g. `"TV Shows"`) must be quoted in CUE struct literals

**`#ScheduledTaskWorkload` blueprint:**
- Verify the blueprint import path is correct: `blueprints_workload "opmodel.dev/opm/v1alpha1/blueprints/workload@v1"`
- Check that `cronJobConfig.scheduleCron` accepts a string (not an enum) — the schedule
  is a user-supplied cron expression

**subPath volume mount:**
- The `kometa-config` volumeMount uses `subPath: "config.yml"` — verify the OPM
  volumeMount schema accepts the `subPath` field

---

## Step 7: Create Dev Release

Create the release directory and file:

```bash
mkdir -p releases/dev/kometa
```

Create `releases/dev/kometa/release.cue`:

```cue
package kometa

import (
	mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
	m  "opmodel.dev/modules/kometa@v1"
)

mr.#ModuleRelease

metadata: {
	name:      "kometa"
	namespace: "kometa"
}

#module: m

values: {
	image: {
		repository: "kometateam/kometa"
		tag:        "latest"
		digest:     ""
	}
	timezone: "Europe/Stockholm"
	schedule: "0 2 * * *"
	storage: {
		config: {
			mountPath:    "/config"
			type:         "pvc"
			size:         "2Gi"
			storageClass: "local-path"
		}
	}
	resources: {
		requests: { cpu: "200m", memory: "512Mi" }
		limits:   { cpu: "2000m", memory: "2Gi" }
	}
	plexUrl: "http://plex.plex.svc.cluster.local:32400"
	plexToken: {
		$secretName: "kometa-secrets"
		$dataKey:    "plex-token"
	}
	tmdbApiKey: {
		$secretName: "kometa-secrets"
		$dataKey:    "tmdb-api-key"
	}
	libraries: {
		Movies: {
			metadataPaths: [
				{ pmm: "basic" }
				{ pmm: "imdb" }
			]
			overlayPaths: [
				{ pmm: "ribbon" }
			]
			operations: {
				massCriticRatingUpdate: "mdb_tomatoesaudience"
			}
		}
		"TV Shows": {
			metadataPaths: [
				{ pmm: "basic" }
			]
			operations: {
				massEpisodeCriticRatingUpdate: "tmdb"
			}
		}
	}
}
```

Before deploying, create the required secret:

```bash
kubectl create secret generic kometa-secrets \
  --namespace kometa \
  --from-literal=plex-token=<your-plex-token> \
  --from-literal=tmdb-api-key=<your-tmdb-api-key>
```

---

## Step 8: Validate Release

Run from `releases/`:

```bash
# Format and validate the release
task check

# Validate with concrete check
task vet CONCRETE=true
```

Common issues:
- Library name strings with spaces must be quoted: `"TV Shows": { ... }`
- All `schemas.#Secret` references must have concrete `$secretName` and `$dataKey`
- `plexUrl` must be a concrete string (no default in schema — required field)
- Verify the rendered `config.yml` is valid YAML by temporarily exporting it:
  ```bash
  cue export ./releases/dev/kometa/... --out yaml
  ```

---

## Step 9: Publish Module

After validation passes, publish from `modules/`:

```bash
# Preview what will be published
task publish:dry

# Publish only the kometa module
task publish:one MODULE=kometa

# Or publish all changed modules
task publish
```

Set environment variables before publishing:

```bash
export CUE_REGISTRY='opmodel.dev=localhost:5000+insecure,registry.cue.works'
export OPM_REGISTRY='opmodel.dev=localhost:5000+insecure,registry.cue.works'
```

Confirm the module is published:

```bash
task versions
```

The kometa module should show `v0.1.0`.

---

## Secret Injection: Tautulli Enhancement (Optional)

If strict secret segregation is required for the Tautulli API key, implement the init
container patch pattern instead of embedding the key in the ConfigMap:

1. Add a second `schemas.#Secret` volume to the pod for the Tautulli API key
2. Add an init container that uses `sed` to substitute a placeholder:
   ```sh
   sed "s/__TAUTULLI_KEY__/$(cat /secrets/tautulli-api-key)/g" \
     /seed/config.yml > /patched/config.yml
   ```
3. Mount an `emptyDir` volume at `/patched/`
4. Change the main container to mount from `/patched/config.yml` instead of the ConfigMap

This is a scope extension — implement only if required by the deployment environment.
Document the limitation in `DEPLOYMENT_NOTES.md` for the module.

---

## Post-Implementation Checklist

- [ ] `task check` passes in `modules/`
- [ ] `task vet CONCRETE=true` passes against debugValues (including YAML marshal)
- [ ] Dev release validates with `task vet CONCRETE=true` in `releases/`
- [ ] `KOMETA_RUN=true` env var present in components.cue — critical for CronJob exit
- [ ] `subPath: "config.yml"` correctly overlays config file over PVC mount
- [ ] Library comprehension handles optional fields correctly (`_|_` guards)
- [ ] Module published successfully with `task versions` showing correct version
- [ ] README.md includes Plex token retrieval instructions
- [ ] Tautulli limitation documented in both README.md and DEPLOYMENT_NOTES.md
- [ ] Manual trigger instructions: `kubectl create job --from=cronjob/kometa kometa-manual`
