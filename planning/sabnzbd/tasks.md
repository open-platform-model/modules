# SABnzbd OPM Module — Implementation Tasks

## Step 1: Scaffold Module Directory

Run from the workspace root:

```bash
mkdir -p modules/sabnzbd/cue.mod
```

Files to create:

```
modules/sabnzbd/
  cue.mod/
    module.cue        ← CUE module identity and deps
  module.cue          ← Module metadata + #config schema
  components.cue      ← Workload component definitions
  README.md           ← Usage and configuration reference
```

## Step 2: Create cue.mod/module.cue

Create `modules/sabnzbd/cue.mod/module.cue` with the following exact content:

```cue
module: "opmodel.dev/modules/sabnzbd@v1"
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

Create `modules/sabnzbd/module.cue`. Implement in order:

**1. Package declaration and imports:**
```cue
package sabnzbd

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
	name:             "sabnzbd"
	version:          "0.1.0"
	description:      "SABnzbd — Usenet download client with NZB queue management and post-processing"
	defaultNamespace: "sabnzbd"
}
```

**3. `#storageVolume` definition** (identical shape to `modules/jellyfin/module.cue`):
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

**4. `#usenetServer` definition:**
```cue
#usenetServer: {
	name:        string
	host:        string
	port:        int | *563
	ssl:         bool | *true
	connections: int | *8
	username?:   schemas.#Secret
	password?:   schemas.#Secret
}
```

**5. `#downloadCategory` definition:**
```cue
#downloadCategory: {
	name:    string
	dir?:    string
	pp?:     int | *3
	script?: string
}
```

**6. `#config` schema** — key fields:
- `image`: `schemas.#Image & { repository: string | *"lscr.io/linuxserver/sabnzbd", tag: string | *"latest", digest: string | *"" }`
- `port: int & >0 & <=65535 | *8080`
- `puid: int | *1000`, `pgid: int | *1000`
- `timezone: string | *"Europe/Stockholm"`
- `umask?: string`
- `storage.config`: `#storageVolume & { mountPath: *"/config" | string, type: *"pvc" | ..., size: string | *"10Gi" }`
- `storage.downloads`: `#storageVolume & { mountPath: *"/downloads" | string }`
- `storage.incomplete?`: `#storageVolume & { mountPath: *"/incomplete-downloads" | string }`
- `serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"`
- `resources?: schemas.#ResourceRequirementsSchema`
- `sabnzbdConfig?`: object with `hostWhitelist?`, `downloadDir?`, `completeDir?`, `incompleteDir?`, `apiKey?: schemas.#Secret`, `servers?: [...#usenetServer]`, `categories?: [...#downloadCategory]`

**7. `debugValues` block** with fully concrete values that exercise the entire schema surface for `cue vet -c`:
- Include both `downloads` and `incomplete` storage volumes
- Include a `sabnzbdConfig` with one `servers` entry (use `value:` for credentials) and two `categories`

## Step 4: Write components.cue

Create `modules/sabnzbd/components.cue`. Implement a single component `sabnzbd` inside `#components`.

**Imports:**
```cue
package sabnzbd

import (
	resources_config   "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage  "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	traits_workload    "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network     "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security    "opmodel.dev/opm/v1alpha1/traits/security@v1"
)
```

**Traits to embed in the `sabnzbd` component:**
```cue
sabnzbd: {
	resources_workload.#Container
	resources_storage.#Volumes
	resources_config.#ConfigMaps
	traits_workload.#Scaling
	traits_workload.#RestartPolicy
	traits_workload.#InitContainers
	traits_network.#Expose
	traits_security.#SecurityContext

	metadata: name: "sabnzbd"
	metadata: labels: "core.opmodel.dev/workload-type": "stateful"
```

**Key implementation points:**

1. **`_allVolumes` hidden map** — combine config, downloads, and optionally incomplete into a uniform map for volume rendering (mirrors the jellyfin pattern):
   ```cue
   _allVolumes: {
       config:    #config.storage.config
       downloads: #config.storage.downloads
       if #config.storage.incomplete != _|_ {
           incomplete: #config.storage.incomplete
       }
   }
   ```

2. **`_volumes: spec.volumes`** alias for volumeMount references.

3. **Volume rendering** — iterate `_allVolumes` with a type-switch for `pvc`/`emptyDir`/`nfs`:
   ```cue
   volumes: {
       for name, v in _allVolumes {
           (name): {
               "name": name
               if v.type == "pvc" {
                   persistentClaim: {
                       size: v.size
                       if v.storageClass != _|_ { storageClass: v.storageClass }
                   }
               }
               if v.type == "emptyDir" { emptyDir: {} }
               if v.type == "nfs" { nfs: { server: v.server, path: v.path } }
           }
       }
       // ConfigMap seed volume — only when sabnzbdConfig is set
       if #config.sabnzbdConfig != _|_ {
           "sabnzbd-config-seed": {
               name:      "sabnzbd-config-seed"
               configMap: spec.configMaps["sabnzbd-config-seed"]
           }
       }
   }
   ```

4. **Main container env vars:**
   ```cue
   env: {
       PUID: { name: "PUID", value: "\(#config.puid)" }
       PGID: { name: "PGID", value: "\(#config.pgid)" }
       TZ:   { name: "TZ",   value: #config.timezone }
       if #config.umask != _|_ {
           UMASK: { name: "UMASK", value: #config.umask }
       }
   }
   ```

5. **Port declaration:** `ports: http: { name: "http", targetPort: 8080 }`

6. **Volume mounts** — iterate `_allVolumes`, plus conditionally mount the ConfigMap seed (init container only, not main container):
   ```cue
   volumeMounts: {
       for vName, v in _allVolumes {
           (vName): _volumes[vName] & { mountPath: v.mountPath }
       }
   }
   ```

7. **Expose block:**
   ```cue
   expose: {
       ports: http: container.ports.http & { exposedPort: #config.port }
       type: #config.serviceType
   }
   ```

8. **Conditional init container** — runs when `sabnzbdConfig != _|_`. Uses `alpine:latest` to copy the seed INI only if the file is absent:
   ```cue
   if #config.sabnzbdConfig != _|_ {
       initContainers: [{
           name:    "config-seed"
           image:   { repository: "alpine", tag: "latest", digest: "" }
           command: ["sh", "-c"]
           args:    ["test -f /config/sabnzbd.ini || cp /seed/sabnzbd.ini /config/sabnzbd.ini"]
           volumeMounts: {
               config: _volumes.config & { mountPath: "/config" }
               "sabnzbd-config-seed": _volumes["sabnzbd-config-seed"] & {
                   mountPath: "/seed"
                   readOnly:  true
               }
           }
       }]
   }
   ```

9. **Conditional ConfigMap** — renders the INI seed using CUE string interpolation. Build the `[servers]` and `[categories]` sections using hidden helper fields:

   ```cue
   if #config.sabnzbdConfig != _|_ {
       // Hidden field: build INI server blocks from the servers list
       _serversIni: strings.Join([for i, s in (#config.sabnzbdConfig.servers | *[]) {
           """
           [servers]
           name\(i) = \(s.name)
           host\(i) = \(s.host)
           port\(i) = \(s.port)
           ssl\(i) = \(s.ssl)
           connections\(i) = \(s.connections)
           """
       }], "\n")

       configMaps: {
           "sabnzbd-config-seed": {
               immutable: false
               data: {
                   "sabnzbd.ini": """
                       [misc]
                       host_whitelist = \(#config.sabnzbdConfig.hostWhitelist | *"*")
                       port = \(#config.port)
                       download_dir = \(#config.sabnzbdConfig.downloadDir | *#config.storage.downloads.mountPath)
                       complete_dir = \(#config.sabnzbdConfig.completeDir | *"\(#config.storage.downloads.mountPath)/complete")

                       \(_serversIni)
                       """
               }
           }
       }
   }
   ```

   > **Implementation note:** CUE's string interpolation for multi-line INI content is straightforward but watch indentation — CUE triple-quoted strings (`"""`) strip leading whitespace up to the closing `"""` indent level. Test with `cue eval` to verify the rendered output.

10. **No liveness/readiness probes** in the initial implementation — SABnzbd starts slowly. Add an `httpGet` probe on `/api?mode=version` once startup time is characterized in the dev environment.

## Step 5: Write README.md

Create `modules/sabnzbd/README.md` covering:
- What SABnzbd is and its role in the arr-stack (download backend for Sonarr/Radarr)
- Quick start: minimum `values:` block (image, port, puid, pgid, storage.config, storage.downloads)
- Full `#config` field reference (table: field, type, default, description)
- Storage layout table (config, downloads, incomplete)
- Network section (port 8080, serviceType options, Ingress notes, `hostWhitelist`)
- Usenet server configuration (fields, SSL, connections)
- Category configuration for Sonarr/Radarr integration (name, dir, pp values)
- Secrets: `apiKey`, server username/password — `value:` vs `secretKeyRef:`
- Config seeding: how the init container works, that it runs once, that runtime changes are preserved
- Upgrade notes: backing up `/config` PVC before SABnzbd major version upgrades

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
- CUE string interpolation in `_serversIni` may require `import "strings"` — add it to the components.cue imports if needed
- The `schemas.#Secret` type in `servers[].username` / `servers[].password` must be referenced correctly; confirm with `cue vet`
- `storage.incomplete?` being optional means the `_allVolumes` guard `if #config.storage.incomplete != _|_` is required

## Step 7: Create Dev Release

Scaffold the release directory from the workspace root:

```bash
mkdir -p releases/kind_opm_dev/sabnzbd/cue.mod
```

**Create `releases/kind_opm_dev/sabnzbd/cue.mod/module.cue`:**
```cue
module: "opmodel.dev/releases/kind_opm_dev/sabnzbd@v0"
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
	"opmodel.dev/modules/sabnzbd@v1": {
		v: "v0.1.0"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.3"
	}
}
```

**Create `releases/kind_opm_dev/sabnzbd/release.cue`:**
```cue
package sabnzbd

import (
	mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
	m  "opmodel.dev/modules/sabnzbd@v1"
)

mr.#ModuleRelease

metadata: {
	name:      "sabnzbd"
	namespace: "sabnzbd"
}

#module: m

values: {
	port:        8080
	puid:        3005
	pgid:        3005
	timezone:    "Europe/Stockholm"
	umask:       "002"
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
			size:         "10Gi"
			storageClass: "standard"
		}
		downloads: {
			mountPath: "/downloads"
			type:      "nfs"
			server:    "192.168.1.1"
			path:      "/mnt/data/downloads"
		}
	}

	sabnzbdConfig: {
		hostWhitelist: "sabnzbd.kind.larnet.eu,*"
		downloadDir:   "/downloads"
		completeDir:   "/downloads/complete"
		apiKey: {value: "dev-api-key-replace-in-prod"}
		categories: [{
			name: "tv"
			dir:  "tv"
			pp:   3
		}, {
			name: "movies"
			dir:  "movies"
			pp:   3
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

> **Sequencing note:** The release `cue.mod` references `opmodel.dev/modules/sabnzbd@v1` at `v0.1.0`. This version must exist in the registry before `task tidy` can resolve it. Publish the module first (Step 9), then run release validation.

## Step 9: Publish Module

Run from `modules/`:

```bash
# Check version status and confirm v0.1.0 is ready to publish
task versions

# Dry run — preview what would be published without actually publishing
task publish:dry

# Publish the sabnzbd module
task publish:one MODULE=sabnzbd
```

After a successful publish, the module is available at `opmodel.dev/modules/sabnzbd@v1:v0.1.0`.

Update the release `cue.mod` dep version to match the published version if it differs, then re-run from `releases/`:

```bash
task tidy
task check
```
