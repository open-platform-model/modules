# Radarr Module Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

## Overview

Radarr is an automated movie downloader built on the Servarr (.NET/C#) platform — the same codebase as Sonarr with movies instead of TV series. It monitors RSS feeds from Usenet indexers and torrent trackers, automatically grabs new movie releases matching a watchlist, and imports them into a media library after download. It integrates with download clients (SABnzbd, qBittorrent, etc.) via their APIs.

OPM module: `opmodel.dev/modules/radarr@v1`  
Upstream version: v6.0.4.10291  
Deployment model: single stateful container, LinuxServer.io image, config seeded via init container.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Kubernetes Pod: radarr                             │
│                                                     │
│  init: config-seed                                  │
│    busybox — copies /seed/config.xml → /config      │
│    only if /config/config.xml does not yet exist    │
│                                                     │
│  container: radarr                                  │
│    lscr.io/linuxserver/radarr:latest                │
│    port 7878                                        │
│    /config    ←── PVC (config state + DB)           │
│    /movies    ←── PVC or NFS (media library)        │
│    /downloads ←── PVC or NFS (shared with grabber)  │
│                                                     │
│  [optional] container: exportarr                    │
│    ghcr.io/onedr0p/exportarr:v2.3.0                 │
│    port 9707 — Prometheus /metrics                  │
└─────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **Config seeding, not mounting:** Radarr writes runtime state (API key, certificates, database) into `/config`. Directly mounting a ConfigMap at `/config/config.xml` would make the file read-only, breaking Radarr on startup. Instead, an init container copies the seed file only if the target does not yet exist — idempotent and non-destructive.
- **Single replica:** Radarr uses an embedded SQLite database. Horizontal scaling is not supported.
- **Shared storage:** `/downloads` is typically the same NFS or PVC mount shared with the download client (SABnzbd, qBittorrent). Radarr needs read/write access to move completed downloads into `/movies`.
- **Optional Exportarr sidecar:** When `#config.exportarr` is set, a second container runs Exportarr in the same pod, scraping Radarr's API on localhost and exposing Prometheus metrics.
- **Identical Servarr architecture:** Radarr and Sonarr share the same config.xml structure, the same LinuxServer.io env vars, and the same init-container seeding pattern. The only differences are the default port (7878), the media volume name (`movies` vs `tv`), and the instance name default ("Radarr").

## Container Image

| Field      | Value                              |
|------------|------------------------------------|
| Repository | `lscr.io/linuxserver/radarr`       |
| Tag        | `latest`                           |
| Digest     | `""` (resolved at deploy time)     |
| Base OS    | Ubuntu (LinuxServer.io s6-overlay) |
| Upstream   | v6.0.4.10291                       |

LinuxServer.io specifics:
- PUID/PGID map the container process to a host UID/GID — required for correct file ownership on mounted volumes.
- `TZ` sets the container timezone for correct scheduling.
- `UMASK` controls file creation mask (default `002`).

## OPM Module Design

File layout:

```
modules/radarr/
  cue.mod/
    module.cue          — CUE module identity and dep pins
  module.cue            — metadata, #storageVolume, #servarrConfig,
                          #exportarrSidecar, #config, debugValues
  components.cue        — #components: init container + main container
                          + optional exportarr sidecar + volumes + configMaps
  README.md
  DEPLOYMENT_NOTES.md
```

`#servarrConfig` is defined locally in `module.cue`. It is identical to the Sonarr definition — copy it verbatim. Do not attempt to share it across CUE module boundaries.

`#exportarrSidecar` is also defined locally in `module.cue` (copied from the Exportarr design). Each arr module carries its own copy.

## #config Schema

```cue
// #storageVolume is the uniform schema for all volume entries.
#storageVolume: {
    mountPath:     string
    type:          "pvc" | "emptyDir" | "nfs"
    size?:         string // required when type == "pvc"
    storageClass?: string // optional override for pvc
    server?:       string // required when type == "nfs"
    path?:         string // required when type == "nfs"
}

// #servarrConfig captures Servarr-common config.xml fields.
// Identical to the Sonarr definition — copy verbatim.
#servarrConfig: {
    // Pre-seeded API key. If absent, Radarr generates one on first boot.
    apiKey?: schemas.#Secret & {
        $secretName: string
        $dataKey:    string
    }
    authMethod?:   "Forms" | "Basic" | "External" | *"External"
    authRequired?: "Enabled" | "DisabledForLocalAddresses" | *"DisabledForLocalAddresses"
    branch?:       string | *"main"
    logLevel?:     "trace" | "debug" | "info" | "warn" | "error" | *"info"
    urlBase?:      string
    instanceName?: string
}

// #exportarrSidecar configures the optional Exportarr metrics sidecar.
#exportarrSidecar: {
    image: schemas.#Image & {
        repository: string | *"ghcr.io/onedr0p/exportarr"
        tag:        string | *"v2.3.0"
        digest:     string | *""
    }
    port:                    int | *9707
    apiKey: schemas.#Secret & {
        $secretName: string
        $dataKey:    string
    }
    enableAdditionalMetrics: bool | *false
    enableUnknownQueueItems: bool | *false
    logLevel:                "debug" | "info" | "warn" | "error" | *"info"
    resources?: schemas.#ResourceRequirementsSchema
}

#config: {
    // Container image for the Radarr server.
    image: schemas.#Image & {
        repository: string | *"lscr.io/linuxserver/radarr"
        tag:        string | *"latest"
        digest:     string | *""
    }

    // Web UI port. Radarr default is 7878.
    port: int & >0 & <=65535 | *7878

    // LinuxServer.io process identity — must match the UID/GID that owns mounted volumes.
    puid: int | *1000
    pgid: int | *1000

    // Container timezone. Affects scheduling and log timestamps.
    timezone: string | *"Europe/Stockholm"

    // Optional file creation mask (e.g. "002" for group-writable files).
    umask?: string

    // Storage volumes. All use #storageVolume for uniform type-switch rendering.
    storage: {
        // Radarr application data, SQLite DB, logs. Must be a PVC for persistence.
        config: #storageVolume & {
            mountPath: *"/config" | string
            type:      *"pvc" | "emptyDir" | "nfs"
            size:      string | *"5Gi"
        }
        // Movie media library. PVC or NFS depending on infrastructure.
        movies: #storageVolume & {
            mountPath: *"/movies" | string
        }
        // Completed downloads landing zone — shared with the download client.
        downloads: #storageVolume & {
            mountPath: *"/downloads" | string
        }
    }

    // Kubernetes Service type for the web UI.
    serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

    // Optional resource requests and limits for the Radarr container.
    resources?: schemas.#ResourceRequirementsSchema

    // Optional Servarr XML config fields seeded into /config/config.xml.
    servarrConfig?: #servarrConfig & {
        instanceName: string | *"Radarr"
    }

    // Optional Exportarr metrics sidecar. When set, a second container is injected.
    exportarr?: #exportarrSidecar
}
```

## Storage Layout

| Name        | Mount Path   | Type         | Default Size | Description                                              |
|-------------|--------------|--------------|--------------|----------------------------------------------------------|
| `config`    | `/config`    | pvc          | 5Gi          | App data: SQLite DB, logs, recycling bin, SSL certs      |
| `movies`    | `/movies`    | pvc or nfs   | —            | Movie media library root. Radarr moves imports here.     |
| `downloads` | `/downloads` | pvc or nfs   | —            | Completed downloads. Shared read/write with download client. |

**Notes:**
- `config` must be a PVC — Radarr writes its database here at runtime.
- `movies` and `downloads` are frequently NFS mounts pointing to a NAS. Set `type: "nfs"` with `server` and `path` fields.
- If `movies` and `downloads` are on the same filesystem, Radarr can use hardlinks for instant moves (zero-copy import). Ensure both mounts resolve to the same underlying volume.

## Network Configuration

| Port | Protocol | Purpose                          | Exposed via       |
|------|----------|----------------------------------|-------------------|
| 7878 | TCP/HTTP | Radarr web UI and API            | Service `#config.serviceType` |
| 9707 | TCP/HTTP | Exportarr Prometheus `/metrics`  | Optional — only when `#config.exportarr` is set |

- Default service type is `ClusterIP`. Use `LoadBalancer` or a Gateway/Ingress for external access.
- The Exportarr metrics port is only exposed when the sidecar is enabled.

## Environment Variables

Variables injected into the Radarr container via `env:`:

| Variable | Source              | Description                                    |
|----------|---------------------|------------------------------------------------|
| `PUID`   | `#config.puid`      | UID the container process runs as              |
| `PGID`   | `#config.pgid`      | GID the container process runs as              |
| `TZ`     | `#config.timezone`  | Timezone string (e.g. `Europe/Stockholm`)      |
| `UMASK`  | `#config.umask` (optional) | File creation mask (e.g. `002`)         |

Variables injected into the Exportarr sidecar (when enabled):

| Variable                      | Source                                        | Description                        |
|-------------------------------|-----------------------------------------------|------------------------------------|
| `PORT`                        | `#config.exportarr.port`                      | Metrics HTTP port                  |
| `URL`                         | Derived: `http://localhost:\(#config.port)`   | Radarr API base URL                |
| `APIKEY`                      | `#config.exportarr.apiKey` (secret ref)       | Radarr API key                     |
| `ENABLE_ADDITIONAL_METRICS`   | `#config.exportarr.enableAdditionalMetrics`   | Extra movie/queue metrics          |
| `ENABLE_UNKNOWN_QUEUE_ITEMS`  | `#config.exportarr.enableUnknownQueueItems`   | Unknown queue item metrics         |
| `LOG_LEVEL`                   | `#config.exportarr.logLevel`                  | Exportarr log verbosity            |

## Declarative Configuration Strategy

Radarr stores all its settings in `/config/config.xml`. This file is written and updated at runtime — Radarr adds API keys, certificate paths, and other dynamic state to it.

**Strategy: seed on first boot, preserve on subsequent boots.**

1. CUE renders the desired `config.xml` content as a template string and stores it in a ConfigMap named `radarr-config-seed`.
2. An init container (busybox) runs before Radarr starts and checks: `[ -f /config/config.xml ]`. If the file does not exist, it copies from the seed ConfigMap. If it already exists, it does nothing — preserving all runtime modifications.
3. The main Radarr container starts with a fully-initialized `config.xml`, avoiding the first-boot wizard flow.

The config.xml template string in CUE:

```cue
_configXml: """
    <?xml version="1.0" encoding="utf-8"?>
    <Config>
      <BindAddress>*</BindAddress>
      <Port>\(#config.port)</Port>
      <SslPort>9898</SslPort>
      <EnableSsl>False</EnableSsl>
      <AuthenticationMethod>\(_servarr.authMethod)</AuthenticationMethod>
      <AuthenticationRequired>\(_servarr.authRequired)</AuthenticationRequired>
      <Branch>\(_servarr.branch)</Branch>
      <LogLevel>\(_servarr.logLevel)</LogLevel>
      <UrlBase>\(_servarr.urlBase)</UrlBase>
      <InstanceName>\(_servarr.instanceName)</InstanceName>
      <UpdateMechanism>Docker</UpdateMechanism>
    </Config>
    """
```

Where `_servarr` is a computed local struct resolving optional `servarrConfig` fields to their defaults:

```cue
_servarr: {
    authMethod:   (#config.servarrConfig & {}).authMethod   | *"External"
    authRequired: (#config.servarrConfig & {}).authRequired | *"DisabledForLocalAddresses"
    branch:       (#config.servarrConfig & {}).branch       | *"main"
    logLevel:     (#config.servarrConfig & {}).logLevel     | *"info"
    urlBase:      (#config.servarrConfig & {}).urlBase      | *""
    instanceName: (#config.servarrConfig & {}).instanceName | *"Radarr"
}
```

## ConfigMap Design

**ConfigMap name:** `radarr-config-seed`  
**Immutable:** `false`

```cue
configMaps: {
    "radarr-config-seed": {
        immutable: false
        data: {
            "config.xml": _configXml
        }
    }
}
```

This ConfigMap is mounted read-only at `/seed` in the init container only. The main Radarr container does not mount it — Radarr owns `/config` exclusively after first boot.

**Volume for the ConfigMap:**

```cue
volumes: {
    "radarr-config-seed": {
        name:      "radarr-config-seed"
        configMap: spec.configMaps["radarr-config-seed"]
    }
}
```

## Secrets

| Secret Name      | Data Key  | Description                                            | Required |
|------------------|-----------|--------------------------------------------------------|----------|
| `radarr-secrets` | `api-key` | Radarr API key — pre-seeded if `servarrConfig.apiKey` is set | Optional |

CUE schema reference:

```cue
apiKey?: schemas.#Secret & {
    $secretName:  "radarr-secrets"
    $dataKey:     "api-key"
    $description: "Radarr API key for API authentication and Exportarr scraping"
}
```

**Recommendation for dev:** Leave `servarrConfig.apiKey` unset. Radarr generates a key on first boot. Retrieve it from the running instance and store it in a Secret for Exportarr to use.

## Dev Release Values

Example `values:` block for `releases/kind_opm_dev/radarr/release.cue`:

```cue
values: {
    image: {
        repository: "lscr.io/linuxserver/radarr"
        tag:        "latest"
        digest:     ""
    }
    port:     7878
    puid:     3005
    pgid:     3005
    timezone: "Europe/Stockholm"
    umask:    "002"

    serviceType: "ClusterIP"

    storage: {
        config: {
            mountPath:    "/config"
            type:         "pvc"
            size:         "5Gi"
            storageClass: "local-path"
        }
        movies: {
            mountPath:    "/movies"
            type:         "pvc"
            size:         "1Gi"
            storageClass: "local-path"
        }
        downloads: {
            mountPath:    "/downloads"
            type:         "pvc"
            size:         "1Gi"
            storageClass: "local-path"
        }
    }

    servarrConfig: {
        authMethod:   "External"
        authRequired: "DisabledForLocalAddresses"
        branch:       "main"
        logLevel:     "info"
        instanceName: "Radarr"
    }

    resources: {
        requests: {
            cpu:    "100m"
            memory: "256Mi"
        }
        limits: {
            cpu:    "2000m"
            memory: "1Gi"
        }
    }
}
```

For dev with Exportarr enabled, add:

```cue
    exportarr: {
        image: {
            repository: "ghcr.io/onedr0p/exportarr"
            tag:        "v2.3.0"
            digest:     ""
        }
        port: 9707
        apiKey: {
            $secretName: "radarr-secrets"
            $dataKey:    "api-key"
        }
        enableAdditionalMetrics: false
        enableUnknownQueueItems: false
        logLevel: "info"
    }
```
