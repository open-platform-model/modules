# Seerr OPM Module — Implementation Tasks

## Step 1: Scaffold Module Directory

Run from the workspace root:

```bash
mkdir -p modules/seerr/cue.mod
```

Files to create:

```
modules/seerr/
  cue.mod/
    module.cue        ← CUE module identity and deps
  module.cue          ← Module metadata + #config schema
  components.cue      ← Workload component definitions
  README.md           ← Usage and configuration reference
```

## Step 2: Create cue.mod/module.cue

Create `modules/seerr/cue.mod/module.cue` with the following exact content:

```cue
module: "opmodel.dev/modules/seerr@v1"
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

> Do not manually edit version pins after creation. Use `task update-deps` from the workspace root to keep dep versions current.

## Step 3: Write module.cue

Create `modules/seerr/module.cue`. Implement in order:

**1. Package declaration and imports:**
```cue
package seerr

import (
	m       "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)
```

**2. Module embedding and metadata:**
```cue
m.#Module

metadata: {
	modulePath:       "opmodel.dev/modules"
	name:             "seerr"
	version:          "0.1.0"
	description:      "Seerr — media request management and discovery, routes to Sonarr/Radarr"
	defaultNamespace: "seerr"
}
```

**3. `#storageVolume` definition** (same shape as all other modules):
```cue
#storageVolume: {
	mountPath:     string
	type:          "pvc" | "emptyDir" | "nfs"
	size?:         string
	storageClass?: string
	server?:       string
	path?:         string
}
```

**4. Integration instance schemas** — Sonarr and Radarr share the same shape; keep them as distinct named types for clarity:
```cue
#seerrSonarrInstance: {
	name:      string
	hostname:  string
	port:      int | *8989
	apiKey:    schemas.#Secret
	useSsl:    bool | *false
	baseUrl?:  string
	isDefault: bool | *false
	is4k:      bool | *false
}

#seerrRadarrInstance: {
	name:      string
	hostname:  string
	port:      int | *7878
	apiKey:    schemas.#Secret
	useSsl:    bool | *false
	baseUrl?:  string
	isDefault: bool | *false
	is4k:      bool | *false
}
```

**5. `#config` schema** — key fields:
- `image`: `schemas.#Image & { repository: string | *"ghcr.io/seerr-team/seerr", tag: string | *"v3.1.0", digest: string | *"" }`
- `port: int & >0 & <=65535 | *5055`
- `timezone: string | *"Europe/Stockholm"`
- `logLevel: "debug" | "info" | "warn" | "error" | *"info"`
- `storage.config`: `#storageVolume & { mountPath: *"/app/config" | string, type: *"pvc" | ..., size: string | *"5Gi" }`
- `serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"`
- `resources?: schemas.#ResourceRequirementsSchema`
- `seerrConfig?`: object with `applicationUrl?`, `applicationTitle?: string | *"Seerr"`, `sonarr?: [...#seerrSonarrInstance]`, `radarr?: [...#seerrRadarrInstance]`

**6. `debugValues` block** with fully concrete values that exercise the entire schema surface:
- Include `seerrConfig` with `applicationUrl`, one Sonarr instance, one Radarr instance (use `value:` for API keys)
- Use `pvc` with `storageClass: "local-path"` for the config volume

## Step 4: Write components.cue

Create `modules/seerr/components.cue`. Implement a single component `seerr` inside `#components`.

**Imports:**
```cue
package seerr

import (
	"encoding/json"

	resources_config   "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage  "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload    "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network     "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security    "opmodel.dev/opm/v1alpha1/traits/security@v1"
)
```

**Traits to embed in the `seerr` component:**
```cue
seerr: {
	resources_workload.#Container
	resources_storage.#Volumes
	resources_config.#ConfigMaps
	traits_workload.#Scaling
	traits_workload.#RestartPolicy
	traits_workload.#InitContainers
	traits_network.#Expose
	traits_security.#SecurityContext

	metadata: name: "seerr"
	metadata: labels: "core.opmodel.dev/workload-type": "stateful"
```

**Key implementation points:**

1. **`_volumes: spec.volumes`** alias for volumeMount references.

2. **Volume rendering** — single `config` volume using the standard type-switch:
   ```cue
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
           if #config.storage.config.type == "emptyDir" { emptyDir: {} }
           if #config.storage.config.type == "nfs" {
               nfs: {
                   server: #config.storage.config.server
                   path:   #config.storage.config.path
               }
           }
       }
       // settings.json seed volume — only when seerrConfig is set
       if #config.seerrConfig != _|_ {
           "seerr-config-seed": {
               name:      "seerr-config-seed"
               configMap: spec.configMaps["seerr-config-seed"]
           }
       }
   }
   ```

3. **Main container env vars:**
   ```cue
   env: {
       LOG_LEVEL: { name: "LOG_LEVEL", value: #config.logLevel }
       TZ:        { name: "TZ",        value: #config.timezone }
       PORT:      { name: "PORT",      value: "\(#config.port)" }
   }
   ```

4. **Port declaration:** `ports: http: { name: "http", targetPort: 5055 }`

5. **Volume mounts:**
   ```cue
   volumeMounts: {
       config: _volumes.config & { mountPath: #config.storage.config.mountPath }
   }
   ```

6. **Health probes** — Seerr provides a status endpoint. Add both probes:
   ```cue
   livenessProbe: {
       httpGet: { path: "/api/v1/status", port: 5055 }
       initialDelaySeconds: 30
       periodSeconds:       15
       timeoutSeconds:      5
       failureThreshold:    3
   }
   readinessProbe: {
       httpGet: { path: "/api/v1/status", port: 5055 }
       initialDelaySeconds: 15
       periodSeconds:       10
       timeoutSeconds:      3
       failureThreshold:    3
   }
   ```

7. **Expose block:**
   ```cue
   expose: {
       ports: http: container.ports.http & { exposedPort: #config.port }
       type: #config.serviceType
   }
   ```

8. **Conditional init container** — seeds `settings.json` only on first start:
   ```cue
   if #config.seerrConfig != _|_ {
       initContainers: [{
           name:    "config-seed"
           image:   { repository: "alpine", tag: "latest", digest: "" }
           command: ["sh", "-c"]
           args:    ["test -f /app/config/settings.json || cp /seed/settings.json /app/config/settings.json"]
           volumeMounts: {
               config: _volumes.config & { mountPath: "/app/config" }
               "seerr-config-seed": _volumes["seerr-config-seed"] & {
                   mountPath: "/seed"
                   readOnly:  true
               }
           }
       }]
   }
   ```

9. **Conditional ConfigMap** — renders `settings.json` using `json.Marshal`. Build a hidden `_settingsJson` struct to separate data construction from rendering:

   ```cue
   if #config.seerrConfig != _|_ {
       // Hidden struct — assembles the settings.json object from #config fields
       _settingsJson: {
           if #config.seerrConfig.applicationUrl != _|_ {
               applicationUrl: #config.seerrConfig.applicationUrl
           }
           applicationTitle: #config.seerrConfig.applicationTitle | *"Seerr"
           if #config.seerrConfig.sonarr != _|_ {
               sonarr: [for s in #config.seerrConfig.sonarr {
                   name:      s.name
                   hostname:  s.hostname
                   port:      s.port
                   apiKey:    s.apiKey.value
                   useSsl:    s.useSsl
                   isDefault: s.isDefault
                   is4k:      s.is4k
                   if s.baseUrl != _|_ { baseUrl: s.baseUrl }
               }]
           }
           if #config.seerrConfig.radarr != _|_ {
               radarr: [for r in #config.seerrConfig.radarr {
                   name:      r.name
                   hostname:  r.hostname
                   port:      r.port
                   apiKey:    r.apiKey.value
                   useSsl:    r.useSsl
                   isDefault: r.isDefault
                   is4k:      r.is4k
                   if r.baseUrl != _|_ { baseUrl: r.baseUrl }
               }]
           }
       }

       configMaps: {
           "seerr-config-seed": {
               immutable: false
               data: {
                   "settings.json": "\(json.Marshal(_settingsJson))"
               }
           }
       }
   }
   ```

   > **Secret handling note:** The `apiKey` field in Sonarr/Radarr instances uses `schemas.#Secret`. In the rendered JSON, `s.apiKey.value` extracts the literal string. Only the `value:` form of `#Secret` is supported when rendering into a config file. K8s `secretKeyRef:` cannot be resolved at CUE build time; document this constraint in the README.

## Step 5: Write README.md

Create `modules/seerr/README.md` covering:
- What Seerr is and its role (media request gateway between users and Sonarr/Radarr)
- Rebranding note: formerly Jellyseerr, rebranded to Seerr at v3.0 in February 2026
- Quick start: minimum `values:` block (image, port, storage.config)
- Full `#config` field reference table
- Storage layout (single config PVC, contains SQLite DB + settings)
- Network section (port 5055, serviceType, Ingress notes)
- Health check endpoint (`/api/v1/status`)
- First-run wizard: initial admin account requires UI setup — the module seeds server settings but not admin credentials
- Sonarr/Radarr integration: `seerrConfig.sonarr[]` and `seerrConfig.radarr[]` fields, `apiKey` secret usage
- Config seeding: init container behaviour, `settings.json` seeded once, runtime changes preserved
- Secrets: API keys use `value:` for dev; document how to use K8s Secrets with `secretKeyRef:` for production (env var injection pattern not applicable here — instruct operator to pre-create the K8s Secret and use `value:` pointing to a mounted env)
- Upgrading: SQLite database lives in `/app/config/db/` — back up the config PVC before major version upgrades

## Step 6: Tidy & Validate

Run from `modules/`:

```bash
# Tidy dependencies (resolves import paths against registry)
task tidy

# Format + validate schema
task check

# Validate with concreteness check (exercises debugValues)
task vet CONCRETE=true
```

All three commands must pass with zero errors before proceeding.

**Common issues:**
- `json.Marshal` on the `_settingsJson` struct — if any field contains a non-concrete value (e.g. an optional field that wasn't guarded with `if != _|_`), the vet will fail; ensure all branches are properly guarded
- `s.apiKey.value` — the `schemas.#Secret` type may require `& { value: string }` to constrain to the literal form; check that `value` is accessible without an explicit type assertion
- The `for` comprehension over `#config.seerrConfig.sonarr` fails if the list is absent — the outer `if #config.seerrConfig.sonarr != _|_` guard prevents this

## Step 7: Create Dev Release

Scaffold the release directory from the workspace root:

```bash
mkdir -p releases/kind_opm_dev/seerr/cue.mod
```

**Create `releases/kind_opm_dev/seerr/cue.mod/module.cue`:**
```cue
module: "opmodel.dev/releases/kind_opm_dev/seerr@v0"
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
	"opmodel.dev/modules/seerr@v1": {
		v: "v0.1.0"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.3"
	}
}
```

**Create `releases/kind_opm_dev/seerr/release.cue`:**
```cue
package seerr

import (
	mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
	m  "opmodel.dev/modules/seerr@v1"
)

mr.#ModuleRelease

metadata: {
	name:      "seerr"
	namespace: "seerr"
}

#module: m

values: {
	port:        5055
	timezone:    "Europe/Stockholm"
	logLevel:    "info"
	serviceType: "LoadBalancer"

	resources: {
		requests: {
			cpu:    "250m"
			memory: "512Mi"
		}
		limits: {
			cpu:    "2000m"
			memory: "2Gi"
		}
	}

	storage: {
		config: {
			type:         "pvc"
			size:         "5Gi"
			storageClass: "standard"
		}
	}

	seerrConfig: {
		applicationUrl:   "https://seerr.kind.larnet.eu"
		applicationTitle: "Seerr"
		sonarr: [{
			name:      "sonarr"
			hostname:  "sonarr.sonarr.svc.cluster.local"
			port:      8989
			apiKey:    {value: "dev-sonarr-api-key"}
			useSsl:    false
			isDefault: true
			is4k:      false
		}]
		radarr: [{
			name:      "radarr"
			hostname:  "radarr.radarr.svc.cluster.local"
			port:      7878
			apiKey:    {value: "dev-radarr-api-key"}
			useSsl:    false
			isDefault: true
			is4k:      false
		}]
	}
}
```

## Step 8: Validate Release

Run from `releases/`:

```bash
# Tidy release deps (requires module to be published first — see Step 9)
task tidy

# Format + validate
task check

# Validate with concrete values
task vet CONCRETE=true
```

> **Sequencing note:** The release `cue.mod` references `opmodel.dev/modules/seerr@v1` at `v0.1.0`. This version must exist in the registry before `task tidy` can resolve it. Publish the module first (Step 9), then run release validation.

## Step 9: Publish Module

Run from `modules/`:

```bash
# Check version status and confirm v0.1.0 is ready to publish
task versions

# Dry run — preview what would be published without actually publishing
task publish:dry

# Publish the seerr module
task publish:one MODULE=seerr
```

After a successful publish, the module is available at `opmodel.dev/modules/seerr@v1:v0.1.0`.

Update the release `cue.mod` dep version to match the published version if it differs, then re-run from `releases/`:

```bash
task tidy
task check
```
