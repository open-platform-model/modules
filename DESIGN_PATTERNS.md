# OPM Module Design Patterns

This document collects reusable CUE patterns found across the modules in this directory. Read it before writing a new module — most of what you need is already solved here.

Patterns are extracted from `modules/jellyfin/` and `modules/wolf/`. Every code example is taken from those sources verbatim.

---

## Table of Contents

1. [Catalog Schema Helpers](#1-catalog-schema-helpers)
2. [Local #storageVolume Definition](#2-local-storagevolume-definition)
3. [Volume Flattening with _allVolumes](#3-volume-flattening-with-_allvolumes)
4. [Volume Type-Switch Rendering](#4-volume-type-switch-rendering)
5. [ConfigMap Rendering](#5-configmap-rendering)
6. [Optional Field Guards with != _|_](#6-optional-field-guards-with--_)
7. [Private Schema Helpers (_#name)](#7-private-schema-helpers-_name)
8. [LinuxServer.io Environment Convention](#8-linuxserverio-environment-convention)
9. [Init Container Config-Seeding Pattern](#9-init-container-config-seeding-pattern)
10. [Sidecar Container Pattern](#10-sidecar-container-pattern)
11. [debugValues Block](#11-debugvalues-block)
12. [Component Trait Composition](#12-component-trait-composition)

---

## 1. Catalog Schema Helpers

Import `opmodel.dev/opm/v1alpha1/schemas@v1` and use its definitions instead of writing raw field constraints by hand. Three helpers cover almost all common needs.

### schemas.#Image

Represents a container image reference. Always embed and narrow the defaults for the module's primary image.

```cue
import schemas "opmodel.dev/opm/v1alpha1/schemas@v1"

image: schemas.#Image & {
    repository: string | *"linuxserver/jellyfin"
    tag:        string | *"latest"
    digest:     string | *""
}
```

`digest` defaults to `""` (resolved at deploy time). When a module uses multiple images — for example, a main container plus an init container and a sidecar — each gets its own `schemas.#Image` field:

```cue
// wolf/module.cue
image:     schemas.#Image & { repository: string | *"ghcr.io/games-on-whales/wolf", tag: string | *"stable", digest: string | *"" }
initImage: schemas.#Image & { repository: string | *"ttl.sh/wolf-init", tag: string | *"latest", digest: string | *"" }

dind: {
    image: schemas.#Image & { repository: string | *"docker", tag: string | *"dind", digest: string | *"" }
}
```

### schemas.#ResourceRequirementsSchema

Represents CPU/memory resource requests and limits. Mark the entire field optional with `?` — when absent, no resource constraints are applied to the container.

```cue
// jellyfin/module.cue
resources?: schemas.#ResourceRequirementsSchema & {
    requests?: {
        cpu?:    *"500m" | _
        memory?: *"1Gi" | _
    }
    limits?: {
        cpu?:    *"4000m" | _
        memory?: *"4Gi" | _
    }
}
```

In `components.cue`, propagate it conditionally:

```cue
if #config.resources != _|_ {
    resources: #config.resources
}
```

For modules with sidecars, each container that can have independent resource limits takes its own optional `resources?` field (see wolf's `dind.resources` and `manager.resources`).

### schemas.#Secret

Represents a reference to a value stored in a Kubernetes Secret. Use it wherever a sensitive string — API key, password, JWT secret — must be injected at runtime.

```cue
// wolf/module.cue
adminPassword: schemas.#Secret & {
    $secretName:  "wolfmanager"
    $dataKey:     "admin-password"
    $description: "WolfManager admin account password"
}
```

Three meta-fields describe the secret to tooling and humans:

- `$secretName` — the Kubernetes Secret object name
- `$dataKey` — the key within that Secret's `data` map
- `$description` — human-readable explanation

In `components.cue`, reference it via `from:` in the env entry:

```cue
Admin__Password: {
    name: "Admin__Password"
    from: #config.manager.adminPassword
}
```

---

## 2. Local #storageVolume Definition

Define a `#storageVolume` struct in `module.cue` to give all volumes in a module a uniform shape. This single definition drives both the user-facing schema and the rendering logic in `components.cue`.

```cue
// jellyfin/module.cue
#storageVolume: {
    mountPath:     string
    type:          "pvc" | "emptyDir" | "nfs"
    size?:         string // required when type == "pvc"
    storageClass?: string // optional, only used when type == "pvc"
    server?:       string // required when type == "nfs"
    path?:         string // required when type == "nfs"
}
```

Then use it in `#config.storage`, narrowing defaults per volume:

```cue
storage: {
    config: #storageVolume & {
        mountPath: *"/config" | string
        type:      *"pvc" | "emptyDir" | "nfs"
        size:      string | *"10Gi"
    }
    backup?: #storageVolume & {
        mountPath: *"/config/data/backups" | string
    }
    media?: [Name=string]: #storageVolume
}
```

The `type` discriminant drives the volume type-switch in `components.cue` (see pattern 4). The optional fields (`size?`, `storageClass?`, `server?`, `path?`) are only required when the matching `type` is selected — document this in inline comments.

For modules with more storage types, add `hostPath` alongside `pvc`, `emptyDir`, and `nfs`:

```cue
// wolf/module.cue — storage config with hostPath support
storage: {
    config: {
        type:          *"pvc" | "hostPath" | "nfs"
        size:          string | *"20Gi"
        storageClass?: string
        path?:         string
        hostPathType?: *"Directory" | "DirectoryOrCreate"
        nfsServer?:    string
        nfsPath?:      string
    }
}
```

---

## 3. Volume Flattening with _allVolumes

When a module has a mix of required and optional volumes that all need to be rendered the same way, flatten them into a single hidden map first. This lets a single comprehension in `components.cue` handle the rendering loop.

```cue
// jellyfin/components.cue
_allVolumes: {
    config: #config.storage.config
    if #config.storage.backup != _|_ {
        backup: #config.storage.backup
    }
    if #config.storage.media != _|_ {
        for name, v in #config.storage.media {
            (name): v
        }
    }
}
```

The `_` prefix marks this as a hidden field — it is not part of the module's output, only an intermediate value. The `if != _|_` guards skip absent optional volumes. The `for ... in` loop spreads a named map (e.g., `media: { movies: ..., tvshows: ... }`) into top-level entries.

After flattening, a single comprehension renders all volumes and all volumeMounts uniformly:

```cue
volumeMounts: {
    for vName, v in _allVolumes {
        (vName): _volumes[vName] & {
            mountPath: v.mountPath
        }
    }
}
```

---

## 4. Volume Type-Switch Rendering

In `components.cue`, render each volume's backing storage by switching on the `type` field. CUE evaluates all `if` branches that are true — exactly one will be true for each volume entry.

```cue
// jellyfin/components.cue
volumes: {
    for name, v in _allVolumes {
        (name): {
            "name": name
            if v.type == "pvc" {
                persistentClaim: {
                    size: v.size
                    if v.storageClass != _|_ {
                        storageClass: v.storageClass
                    }
                }
            }
            if v.type == "emptyDir" {
                emptyDir: {}
            }
            if v.type == "nfs" {
                nfs: {
                    server: v.server
                    path:   v.path
                }
            }
        }
    }
}
```

For modules that also support `hostPath`, extend the switch:

```cue
// wolf/components.cue
if #config.storage.config.type == "hostPath" {
    hostPath: {
        path: #config.storage.config.path
        type: #config.storage.config.hostPathType
    }
}
```

The optional `storageClass` is itself guarded: `if v.storageClass != _|_`. This avoids emitting an empty field when the user has not provided a storage class.

---

## 5. ConfigMap Rendering

CUE can render structured config files directly into ConfigMap data values at build time. Use the encoding packages from the standard library.

### JSON — encoding/json

```cue
// jellyfin/components.cue
import "encoding/json"

configMaps: {
    "jellyfin-logging": {
        immutable: false
        data: {
            "logging.json": "\(json.Marshal({
                Serilog: {
                    MinimumLevel: {
                        Default: #config.logging.defaultLevel
                        if #config.logging.overrides != _|_ {
                            Override: #config.logging.overrides
                        }
                    }
                }
            }))"
        }
    }
}
```

### TOML — encoding/toml

```cue
// wolf/components.cue
import "encoding/toml"

data: {
    "config.toml": "\(toml.Marshal(#WolfTomlConfig & {
        config_version: #config.configVersion
        hostname:       #config.wolf.hostname
        uuid:           #config.uuid
        profiles:       #config.profiles
        if #config.gstreamer != _|_ {
            gstreamer: #config.gstreamer
        }
    }))"
}
```

### Template strings — XML, INI, and other formats

For formats without a CUE encoder (XML, INI), use CUE's multi-line string interpolation:

```cue
// sonarr/components.cue (planned)
_configXml: """
    <?xml version="1.0" encoding="utf-8"?>
    <Config>
      <BindAddress>*</BindAddress>
      <Port>\(#config.port)</Port>
      <AuthenticationMethod>\(_servarr.authMethod)</AuthenticationMethod>
      <Branch>\(_servarr.branch)</Branch>
      <LogLevel>\(_servarr.logLevel)</LogLevel>
      <UpdateMechanism>Docker</UpdateMechanism>
    </Config>
    """
```

Computed local values (like `_servarr` above) resolve optional config fields to their defaults before interpolation, keeping the template itself clean.

### Immutable vs mutable ConfigMaps

- Use `immutable: true` when a config change must trigger a pod restart (e.g., Wolf's `config.toml`). A content hash in the name forces rollout.
- Use `immutable: false` for seed configs that are only read by an init container. The pod can pick up changes on its next restart without the ConfigMap being recreated.

---

## 6. Optional Field Guards with != _|_

CUE represents an absent optional field as bottom (`_|_`). Use `!= _|_` to check whether an optional field has been set before referencing it.

**In module.cue (schema):** Mark optional fields with `?`.

```cue
publishedServerUrl?: string
logging?: { ... }
resources?: schemas.#ResourceRequirementsSchema
```

**In components.cue (rendering):** Guard every use of an optional field.

```cue
// Single guard
if #config.publishedServerUrl != _|_ {
    JELLYFIN_PublishedServerUrl: {
        name:  "JELLYFIN_PublishedServerUrl"
        value: #config.publishedServerUrl
    }
}

// Chained guards — both must be true
if #config.resources != _|_ if #config.resources.gpu != _|_ {
    securityContext: supplementalGroups: [44, 109]
}

// Guard on a nested optional struct
if #config.gpu.type == "nvidia" if #config.gpu.nvidia != _|_ {
    "nvidia-driver": volumes["nvidia-driver"] & {
        mountPath: "/usr/nvidia"
    }
}
```

Chain multiple `if` conditions without `&&` — CUE evaluates them in sequence. This is idiomatic for checking a value type discriminant and then an optional sub-field.

---

## 7. Private Schema Helpers (_#name)

Use `_#name` (leading underscore + hash) to define a private schema that is only used internally within a module file. The underscore makes it a hidden field in CUE's output; the hash makes it a definition.

```cue
// wolf/module.cue
_#portSchema: uint & >0 & <=65535

#config: {
    networking: {
        httpsPort:   _#portSchema | *47984
        httpPort:    _#portSchema | *47989
        controlPort: _#portSchema | *47999
        rtspPort:    _#portSchema | *48010
        videoPort:   _#portSchema | *48100
        audioPort:   _#portSchema | *48200
    }
}
```

This keeps the constraint DRY when the same type is applied to many fields. Without `_#portSchema`, each port field would need to repeat `uint & >0 & <=65535` inline.

The same pattern applies to any repeated primitive constraint: log levels, storage class names, or enum sets used in more than two places.

---

## 8. LinuxServer.io Environment Convention

All LinuxServer.io images (Jellyfin, Sonarr, Radarr, SABnzbd, etc.) use the same four environment variables. Define them as required fields in `#config` with sensible defaults, then emit them uniformly in `components.cue`.

**In module.cue:**

```cue
puid:     int | *1000
pgid:     int | *1000
timezone: string | *"Europe/Stockholm"
umask?:   string  // optional; LinuxServer default is "022"
```

**In components.cue:**

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

Note that `puid` and `pgid` are integers in CUE but must be emitted as strings in the env value — use string interpolation `"\(#config.puid)"`.

`UMASK` is optional. Only emit it when the user has explicitly set it; the LinuxServer.io default (`022`) is safe.

---

## 9. Init Container Config-Seeding Pattern

Applications that write runtime state into their config file (Sonarr, Radarr, Prowlarr, Bazarr) cannot have that file mounted directly from a ConfigMap — the mount would be read-only and break the application on startup.

The solution is a two-step init container seed:

1. CUE renders the desired config content into a ConfigMap at build time.
2. An init container (busybox) copies the seed file into the PVC only if it does not already exist.

**The init container command:**

```sh
[ -f /config/config.xml ] || cp /seed/config.xml /config/config.xml
```

This is idempotent: on first boot it seeds the config; on subsequent boots it does nothing, preserving all runtime modifications made by the application.

**In components.cue:**

```cue
// wolf/components.cue — init container accessing volumes by reference
initContainers: [{
    name:  "config-init"
    image: #config.initImage

    volumeMounts: {
        "wolf-config-toml": volumes["wolf-config-toml"] & {
            mountPath: "/etc/wolf-init/cfg"
            readOnly:  true
        }
        "wolf-config": volumes["wolf-config"] & {
            mountPath: "/etc/wolf"
        }
    }
}]
```

Key rules:

- The seed ConfigMap is mounted **read-only** in the init container. The main container does not mount the ConfigMap at all — it owns the PVC exclusively.
- Reference volumes as `volumes["name"] & { mountPath: "..." }` so the volume source type is included and passes the `matchN` constraint.
- The init container uses `traits_workload.#InitContainers` in the component's embedding list.

---

## 10. Sidecar Container Pattern

Optional sidecars (Exportarr, WolfManager, DinD) are built as CUE `let` bindings that produce a list, then concatenated into `sidecarContainers` with `list.Concat`.

```cue
// wolf/components.cue
import "list"

// Always-present sidecar — always a one-element list
let _dindSidecar = [{
    name:  "dind"
    image: #config.dind.image
    // ...
}]

// Conditional sidecar — zero or one element depending on config
let _managerSidecar = [if #config.manager != _|_ if #config.manager.enabled {
    {
        name:  "wolfmanager"
        image: #config.manager.image
        // ...
    }
}]

sidecarContainers: list.Concat([_dindSidecar, _managerSidecar])
```

This pattern keeps each sidecar's definition self-contained and makes the conditional logic explicit. `list.Concat` handles the case where a conditional sidecar produces an empty list — the result is simply the remaining sidecars.

For a simpler single optional sidecar (like Exportarr in the arr modules), the pattern is:

```cue
// Defined in #config as optional
exportarr?: #exportarrSidecar

// In components.cue — emit sidecar only when config is set
sidecarContainers: [
    if #config.exportarr != _|_ {
        {
            name:  "exportarr"
            image: #config.exportarr.image
            // ...
        }
    },
]
```

The component embedding must include `traits_workload.#SidecarContainers` to make the `sidecarContainers` field available.

---

## 11. debugValues Block

Every module must include a `debugValues` block in `module.cue` with concrete values for every field in `#config`. This allows `cue vet -c` to validate the full schema surface and catches constraint errors that only appear with concrete values.

```cue
// jellyfin/module.cue
debugValues: {
    image: {
        repository: "linuxserver/jellyfin"
        tag:        "latest"
        digest:     ""
    }
    port:        8096
    puid:        3005
    pgid:        3005
    timezone:    "Europe/Stockholm"
    serviceType: "ClusterIP"
    resources: {
        requests: { cpu: "500m", memory: "1Gi" }
        limits:   { cpu: "4000m", memory: "4Gi" }
        gpu: { resource: "gpu.intel.com/i915", count: 1 }
    }
    logging: {
        defaultLevel: "Information"
        overrides: { "Microsoft": "Warning", "System": "Warning" }
    }
    storage: {
        config: { mountPath: "/config", type: "pvc", size: "10Gi", storageClass: "local-path" }
        media: {
            movies:  { mountPath: "/media/movies", type: "pvc", size: "1Gi" }
            tvshows: { mountPath: "/media/tvshows", type: "pvc", size: "1Gi" }
            nas:     { mountPath: "/media/nas", type: "nfs", server: "192.168.1.1", path: "/mnt/data/media" }
        }
    }
}
```

Rules for `debugValues`:

- Every optional field (`?`) should be provided with a realistic value so `cue vet -c` exercises those branches.
- Every enum value should use the default to keep the example minimal.
- Use realistic but obviously-fake values for secrets (`value: "debug-secret-key-32chars"`).
- Use obviously-fake UUIDs for fields like `uuid` (`"00000000-0000-0000-0000-000000000001"`).

---

## 12. Component Trait Composition

Each component in `#components` is built by embedding catalog resource and trait definitions. Choose the set that matches the component's capabilities.

**Standard stateful single-container component:**

```cue
// jellyfin/components.cue
jellyfin: {
    resources_workload.#Container
    resources_storage.#Volumes
    resources_config.#ConfigMaps
    traits_workload.#Scaling
    traits_workload.#RestartPolicy
    traits_network.#Expose
    traits_security.#SecurityContext

    metadata: labels: "core.opmodel.dev/workload-type": "stateful"
}
```

**Complex component with init containers, sidecars, and host network:**

```cue
// wolf/components.cue
wolf: {
    resources_workload.#Container
    resources_storage.#Volumes
    resources_config.#ConfigMaps
    traits_workload.#InitContainers
    traits_workload.#SidecarContainers
    traits_workload.#Scaling
    traits_workload.#RestartPolicy
    traits_workload.#UpdateStrategy
    traits_workload.#GracefulShutdown
    traits_network.#HostNetwork
    traits_network.#Expose

    metadata: labels: "core.opmodel.dev/workload-type": "stateful"
}
```

**Workload type label:** Always set `"core.opmodel.dev/workload-type"` on `metadata.labels`. Use `"stateful"` for applications with persistent storage and `scaling: count: 1`.

**Scaling:** Stateful single-instance applications always set `scaling: count: 1` explicitly. Do not leave it to default — making the intent explicit prevents accidental scale-out that would corrupt a SQLite database.

**Update strategy:** Add `traits_workload.#UpdateStrategy` and set `updateStrategy: type: "Recreate"` for any application that cannot run two instances simultaneously (GPU workloads, applications with exclusive file locks).

**Graceful shutdown:** Add `traits_workload.#GracefulShutdown` and set `terminationGracePeriodSeconds` when the application needs time to finish in-flight work (streams, downloads, database flushes).

### Job and CronJob blueprints

For one-shot tasks (Configarr) use `blueprints_workload.#TaskWorkload` from the catalog instead of `resources_workload.#Container`. For scheduled tasks (Kometa) use `blueprints_workload.#ScheduledTaskWorkload` with `spec.scheduleCron`.

These blueprints compose the necessary traits internally — do not add `traits_workload.#Scaling` or `traits_network.#Expose` when using them.

---

## Quick Reference

| Pattern | Where | Key construct |
|---------|-------|---------------|
| Container image | `module.cue` | `schemas.#Image & { repository: ..., tag: ..., digest: ... }` |
| Resource limits | `module.cue` | `resources?: schemas.#ResourceRequirementsSchema` |
| Secret reference | `module.cue` | `schemas.#Secret & { $secretName: ..., $dataKey: ..., $description: ... }` |
| Volume schema | `module.cue` | `#storageVolume: { mountPath, type, size?, storageClass?, server?, path? }` |
| Volume flattening | `components.cue` | `_allVolumes: { ... if optional !=_|_ { ... } }` |
| Volume rendering | `components.cue` | `for name, v in _allVolumes { if v.type == "pvc" { ... } }` |
| JSON config | `components.cue` | `"\(json.Marshal({ ... }))"` |
| TOML config | `components.cue` | `"\(toml.Marshal(#Schema & { ... }))"` |
| XML/INI config | `components.cue` | `"""...\(#config.field)..."""` |
| Optional guard | `components.cue` | `if #config.field != _|_ { ... }` |
| Private type | `module.cue` | `_#portSchema: uint & >0 & <=65535` |
| LSIO env vars | `components.cue` | `PUID`, `PGID`, `TZ`, optional `UMASK` |
| Init seed | `components.cue` | busybox `[ -f /config/file ] \|\| cp /seed/file /config/file` |
| Sidecar list | `components.cue` | `let _s = [if ... { {...} }]` + `list.Concat([...])` |
| Debug values | `module.cue` | `debugValues: { ... }` — concrete values for `cue vet -c` |
| Stateful label | `components.cue` | `metadata: labels: "core.opmodel.dev/workload-type": "stateful"` |
