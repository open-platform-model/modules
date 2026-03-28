# Seerr OPM Module — Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

## Overview

Seerr (rebranded from Jellyseerr in February 2026, v3.0+) is a media request management
application for self-hosted media servers. Users submit requests for movies and TV shows through
its web UI; Seerr routes approved requests to Sonarr (TV) and Radarr (movies) for automated
acquisition. It stores user accounts, requests, and configuration in a SQLite database under
`/app/config`. In the arr-stack, Seerr is the public-facing request interface that abstracts
the complexity of Sonarr/Radarr from end users.

## Architecture

| Aspect | Detail |
|--------|--------|
| Workload type | Stateful (single replica, PVC-backed) |
| Container count | 2 (init: `config-seed`, main: `seerr`) |
| Image family | Custom (seerr-team), NOT LinuxServer — no PUID/PGID |
| Runtime | Node.js process |
| Config format | JSON file at `/app/config/settings.json` + SQLite DB |
| Config strategy | CUE-rendered JSON → ConfigMap → init container seeds on first start |
| Health check | HTTP GET `/api/v1/status` on port 5055 |

### Init container: `config-seed`

Uses `alpine` (or `busybox`) to check whether `/app/config/settings.json` already exists. If
it does not, it copies the rendered seed file from the mounted ConfigMap. This preserves the
SQLite database and runtime-managed settings (admin account, paired integrations) across restarts.

```
[ -f /app/config/settings.json ] || cp /seed/settings.json /app/config/settings.json
```

The ConfigMap is mounted read-only at `/seed`; the config PVC is mounted read-write at `/app/config`.

### Main container: `seerr`

Node.js application. No PUID/PGID — runs as the default user defined in the image. Exposes the
web UI and API on port 5055. All persistent state lives in the config PVC: `settings.json`,
`db/db.sqlite3`, logs, and image cache.

**First-run note:** The initial admin account requires a one-time UI wizard. `settings.json`
can pre-configure server settings and integrations (~80% declarative), but admin account creation
is not automatable through the config file alone.

## Container Image

| Field | Value |
|-------|-------|
| Registry | `ghcr.io` |
| Repository | `ghcr.io/seerr-team/seerr` |
| Default tag | `v3.1.0` |
| Digest | `""` (pull by tag) |
| Architecture | multi-arch (amd64, arm64) |

Tag strategy: pin to a semver tag. The `latest` tag is not recommended for Seerr since breaking
changes between major versions require database migrations.

## OPM Module Design

| Field | Value |
|-------|--------|
| Module path | `opmodel.dev/modules/seerr` |
| CUE package | `seerr` |
| `cue.mod` module | `opmodel.dev/modules/seerr@v1` |
| Default namespace | `seerr` |
| Version | `0.1.0` |

## `#config` Schema

```cue
package seerr

import (
    m       "opmodel.dev/core/v1alpha1/module@v1"
    schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

m.#Module

// #storageVolume is the shared schema for all volume entries.
#storageVolume: {
    mountPath:     string
    type:          "pvc" | "emptyDir" | "nfs"
    size?:         string
    storageClass?: string
    server?:       string
    path?:         string
}

// #seerrSonarrInstance describes a Sonarr integration endpoint.
#seerrSonarrInstance: {
    name:      string
    hostname:  string
    port:      int | *8989
    apiKey:    schemas.#Secret & {
        $secretName:  "seerr-sonarr"
        $dataKey:     "api-key"
        $description: "Sonarr API key"
    }
    useSsl:    bool | *false
    baseUrl?:  string   // URL base path if Sonarr is behind a reverse proxy sub-path
    isDefault: bool | *false
    is4k:      bool | *false
}

// #seerrRadarrInstance describes a Radarr integration endpoint.
#seerrRadarrInstance: {
    name:      string
    hostname:  string
    port:      int | *7878
    apiKey:    schemas.#Secret & {
        $secretName:  "seerr-radarr"
        $dataKey:     "api-key"
        $description: "Radarr API key"
    }
    useSsl:    bool | *false
    baseUrl?:  string
    isDefault: bool | *false
    is4k:      bool | *false
}

// #seerrSettingsConfig holds optional settings.json pre-seed values.
// When set, a ConfigMap is rendered and seeded on first start.
#seerrSettingsConfig: {
    // Public URL where Seerr is reachable (used in notification links).
    applicationUrl?: string

    // Display name shown in the UI header.
    applicationTitle?: string | *"Seerr"

    // Sonarr integration instances.
    sonarr?: [...#seerrSonarrInstance]

    // Radarr integration instances.
    radarr?: [...#seerrRadarrInstance]
}

#config: {
    // Container image
    image: schemas.#Image & {
        repository: string | *"ghcr.io/seerr-team/seerr"
        tag:        string | *"v3.1.0"
        digest:     string | *""
    }

    // Web UI and API port
    port: int & >0 & <=65535 | *5055

    // Container timezone
    timezone: string | *"Europe/Stockholm"

    // Application log level
    logLevel: "debug" | "info" | "warn" | "error" | *"info"

    // All storage volumes.
    storage: {
        // All application data: settings, SQLite DB, cache, logs.
        config: #storageVolume & {
            mountPath: *"/app/config" | string
            type:      *"pvc" | "emptyDir" | "nfs"
            size:      string | *"5Gi"
        }
    }

    // Kubernetes Service type
    serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

    // Resource requests and limits (optional)
    resources?: schemas.#ResourceRequirementsSchema

    // Optional: pre-seed settings.json on first start.
    // When absent, Seerr starts with built-in defaults (full UI wizard required).
    seerrConfig?: #seerrSettingsConfig

    // Image used by the config-seed init container.
    seedImage: schemas.#Image & {
        repository: string | *"alpine"
        tag:        string | *"3.21"
        digest:     string | *""
    }
}
```

## Storage Layout

| Volume name | Mount path | Type | Default size | Notes |
|-------------|-----------|------|--------------|-------|
| `config` | `/app/config` | PVC | `5Gi` | Settings, SQLite DB, logs, image cache |
| `seerr-config-seed` | `/seed` (init only) | ConfigMap | — | Read-only seed JSON, init container only |

All application data lives in a single PVC. The SQLite database at `/app/config/db/db.sqlite3`
must not be shared across replicas — single-replica only.

## Network Configuration

| Port | Protocol | Name | Purpose |
|------|----------|------|---------|
| `5055` | TCP | `http` | Web UI + REST API |

`serviceType` defaults to `ClusterIP`. Use `LoadBalancer` or pair with a Gateway/Ingress for
external access.

## Environment Variables

| Variable | Source | Default | Notes |
|----------|--------|---------|-------|
| `LOG_LEVEL` | `#config.logLevel` | `"info"` | App log verbosity |
| `TZ` | `#config.timezone` | `"Europe/Stockholm"` | Container timezone |
| `PORT` | `#config.port` | `5055` | Only emitted when non-default |
| `CONFIG_DIRECTORY` | literal | `/app/config` | Always set; ensures config path is explicit |

Note: Seerr does NOT use PUID/PGID. Do not set those variables.

## Declarative Configuration Strategy

Seerr stores settings in `/app/config/settings.json`. This file is runtime-managed: Seerr
writes it when the admin completes the setup wizard, modifies notification rules, or updates
integration configurations through the UI.

**Strategy: seed-once via init container**

1. CUE renders `settings.json` using `json.Marshal` (same pattern as the Jellyfin logging
   ConfigMap). The rendered JSON is stored in a ConfigMap `seerr-config-seed` keyed as
   `settings.json`.
2. An init container `config-seed` (Alpine/busybox) mounts the ConfigMap read-only at `/seed`
   and the config PVC read-write at `/app/config`.
3. The init container runs: `[ -f /app/config/settings.json ] || cp /seed/settings.json /app/config/settings.json`
4. On first start: the seed file is copied. The admin then completes the wizard through the UI
   for first-run admin account setup.
5. On subsequent starts: the existing file (with runtime mutations) is left untouched.
6. The init container is only present in `#components` when `#config.seerrConfig != _|_`.

**JSON rendering approach in components.cue:**

```cue
import "encoding/json"

// Rendered using json.Marshal, identical to the Jellyfin logging ConfigMap pattern.
if #config.seerrConfig != _|_ {
    configMaps: {
        "seerr-config-seed": {
            immutable: false
            data: {
                "settings.json": "\(json.Marshal({
                    applicationUrl:   #config.seerrConfig.applicationUrl
                    applicationTitle: #config.seerrConfig.applicationTitle
                    if #config.seerrConfig.sonarr != _|_ {
                        sonarr: #config.seerrConfig.sonarr
                    }
                    if #config.seerrConfig.radarr != _|_ {
                        radarr: #config.seerrConfig.radarr
                    }
                }))"
            }
        }
    }
}
```

**Secrets handling:** Sonarr/Radarr API keys in `#seerrSonarrInstance.apiKey` and
`#seerrRadarrInstance.apiKey` use `schemas.#Secret`. These are NOT embedded in the JSON seed
file directly — the seed file includes placeholder values. The real keys are injected at runtime
via environment variables if Seerr supports them, or configured post-wizard through the UI.
Check Seerr v3 docs for env-var-based secret injection before implementation.

## ConfigMap Design

| ConfigMap name | Key | Condition | Immutable | Notes |
|----------------|-----|-----------|-----------|-------|
| `seerr-config-seed` | `settings.json` | `#config.seerrConfig != _|_` | `false` | Mutable; seed-once pattern preserves runtime state |

## Secrets

| Secret reference | Field | Description |
|-----------------|-------|-------------|
| `schemas.#Secret { $secretName: "seerr-sonarr", $dataKey: "api-key" }` | `seerrConfig.sonarr[].apiKey` | Sonarr API key |
| `schemas.#Secret { $secretName: "seerr-radarr", $dataKey: "api-key" }` | `seerrConfig.radarr[].apiKey` | Radarr API key |

## Dev Release Values

```cue
// releases/kind_opm_dev/seerr/release.cue
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
    serviceType: "ClusterIP"

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
            name:      "Sonarr"
            hostname:  "sonarr.sonarr.svc.cluster.local"
            port:      8989
            apiKey:    {secretKeyRef: {name: "seerr-sonarr", key: "api-key"}}
            isDefault: true
        }]
        radarr: [{
            name:      "Radarr"
            hostname:  "radarr.radarr.svc.cluster.local"
            port:      7878
            apiKey:    {secretKeyRef: {name: "seerr-radarr", key: "api-key"}}
            isDefault: true
        }]
    }
}
```
