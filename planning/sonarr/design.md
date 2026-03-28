# Sonarr Module Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

## Overview

Sonarr is an automated TV series downloader built on the Servarr (.NET/C#) platform. It monitors RSS feeds from Usenet indexers and torrent trackers, automatically grabs new episodes matching configured series, and imports them into a media library after download. It integrates with download clients (SABnzbd, qBittorrent, etc.) via their APIs.

OPM module: `opmodel.dev/modules/sonarr@v1`  
Upstream version: v4.0.17.2952  
Deployment model: single stateful container, LinuxServer.io image, config seeded via init container.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Kubernetes Pod: sonarr                             │
│                                                     │
│  init: config-seed                                  │
│    busybox — copies /seed/config.xml → /config      │
│    only if /config/config.xml does not yet exist    │
│                                                     │
│  container: sonarr                                  │
│    lscr.io/linuxserver/sonarr:latest                │
│    port 8989                                        │
│    /config  ←── PVC (config state + DB)             │
│    /tv      ←── PVC or NFS (media library)          │
│    /downloads ←── PVC or NFS (shared with grabber)  │
│                                                     │
│  [optional] container: exportarr                    │
│    ghcr.io/onedr0p/exportarr:v2.3.0                 │
│    port 9707 — Prometheus /metrics                  │
└─────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **Config seeding, not mounting:** Sonarr writes runtime state (API key, certificates, database) into `/config`. Directly mounting a ConfigMap at `/config/config.xml` would make the file read-only, breaking Sonarr on startup. Instead, an init container copies the seed file only if the target does not yet exist — idempotent and non-destructive.
- **Single replica:** Sonarr uses an embedded SQLite database. Horizontal scaling is not supported.
- **Shared storage:** `/downloads` is typically the same NFS or PVC mount shared with the download client (SABnzbd, qBittorrent). Sonarr needs read/write access to move completed downloads into `/tv`.
- **Optional Exportarr sidecar:** When `#config.exportarr` is set, a second container runs Exportarr in the same pod, scraping Sonarr's API on localhost and exposing Prometheus metrics.

## Container Image

| Field      | Value                              |
|------------|------------------------------------|
| Repository | `lscr.io/linuxserver/sonarr`       |
| Tag        | `latest`                           |
| Digest     | `""` (resolved at deploy time)     |
| Base OS    | Ubuntu (LinuxServer.io s6-overlay) |
| Upstream   | v4.0.17.2952                       |

LinuxServer.io specifics:
- PUID/PGID map the container process to a host UID/GID — required for correct file ownership on mounted volumes.
- `TZ` sets the container timezone for correct scheduling.
- `UMASK` controls file creation mask (default `002`).

## OPM Module Design

File layout:

```
modules/sonarr/
  cue.mod/
    module.cue          — CUE module identity and dep pins
  module.cue            — metadata, #storageVolume, #servarrConfig,
                          #exportarrSidecar import, #config, debugValues
  components.cue        — #components: init container + main container
                          + optional exportarr sidecar + volumes + configMaps
  README.md
  DEPLOYMENT_NOTES.md
```

`#servarrConfig` is defined locally in `module.cue`. It captures the fields that are identical across all Servarr apps (Sonarr, Radarr, Prowlarr, Bazarr). When implementing Radarr, copy this definition verbatim — do not try to share it across CUE module boundaries.

`#exportarrSidecar` is also defined locally in `module.cue` (copied from the Exportarr design). Each arr module carries its own copy of this definition.

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
// These are seeded into /config/config.xml via init container.
// All fields are optional — Sonarr auto-generates safe defaults for anything absent.
#servarrConfig: {
    // Pre-seeded API key. If absent, Sonarr generates one on first boot.
    // Use a schemas.#Secret ref so the key is pulled from a Kubernetes Secret.
    apiKey?: schemas.#Secret & {
        $secretName: string
        $dataKey:    string
    }
    // Authentication method for the web UI.
    authMethod?: "Forms" | "Basic" | "External" | *"External"
    // Whether auth is required for local-network requests.
    authRequired?: "Enabled" | "DisabledForLocalAddresses" | *"DisabledForLocalAddresses"
    // Release channel. "main" is the stable branch.
    branch?: string | *"main"
    // Log verbosity.
    logLevel?: "trace" | "debug" | "info" | "warn" | "error" | *"info"
    // URL prefix when Sonarr runs behind a reverse proxy (e.g. "/sonarr").
    urlBase?: string
    // Display name shown in the browser tab and notifications.
    instanceName?: string
}

// #exportarrSidecar configures the optional Exportarr metrics sidecar.
// When set in #config, a second container is added to the pod.
#exportarrSidecar: {
    image: schemas.#Image & {
        repository: string | *"ghcr.io/onedr0p/exportarr"
        tag:        string | *"v2.3.0"
        digest:     string | *""
    }
    // Prometheus metrics port inside the pod.
    port: int | *9707
    // Required: API key to authenticate against Sonarr's API.
    apiKey: schemas.#Secret & {
        $secretName: string
        $dataKey:    string
    }
    // Expose extended series/episode metrics.
    enableAdditionalMetrics: bool | *false
    // Include items in an unknown queue state.
    enableUnknownQueueItems: bool | *false
    logLevel: "debug" | "info" | "warn" | "error" | *"info"
    // Optional resource constraints for the sidecar container.
    resources?: schemas.#ResourceRequirementsSchema
}

#config: {
    // Container image for the Sonarr server.
    image: schemas.#Image & {
        repository: string | *"lscr.io/linuxserver/sonarr"
        tag:        string | *"latest"
        digest:     string | *""
    }

    // Web UI port. Sonarr default is 8989.
    port: int & >0 & <=65535 | *8989

    // LinuxServer.io process identity — must match the UID/GID that owns mounted volumes.
    puid: int | *1000
    pgid: int | *1000

    // Container timezone. Affects scheduling and log timestamps.
    timezone: string | *"Europe/Stockholm"

    // Optional file creation mask (e.g. "002" for group-writable files).
    umask?: string

    // Storage volumes. All use #storageVolume for uniform type-switch rendering.
    storage: {
        // Sonarr application data, SQLite DB, logs. Must be a PVC for persistence.
        config: #storageVolume & {
            mountPath: *"/config" | string
            type:      *"pvc" | "emptyDir" | "nfs"
            size:      string | *"5Gi"
        }
        // TV media library. PVC or NFS depending on infrastructure.
        tv: #storageVolume & {
            mountPath: *"/tv" | string
        }
        // Completed downloads landing zone — shared with the download client.
        downloads: #storageVolume & {
            mountPath: *"/downloads" | string
        }
    }

    // Kubernetes Service type for the web UI.
    serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

    // Optional resource requests and limits for the Sonarr container.
    resources?: schemas.#ResourceRequirementsSchema

    // Optional Servarr XML config fields seeded into /config/config.xml.
    servarrConfig?: #servarrConfig & {
        instanceName: string | *"Sonarr"
    }

    // Optional Exportarr metrics sidecar. When set, a second container is injected.
    exportarr?: #exportarrSidecar
}
```

## Storage Layout

| Name        | Mount Path   | Type         | Default Size | Description                                              |
|-------------|--------------|--------------|--------------|----------------------------------------------------------|
| `config`    | `/config`    | pvc          | 5Gi          | App data: SQLite DB, logs, recycling bin, SSL certs      |
| `tv`        | `/tv`        | pvc or nfs   | —            | TV media library root. Sonarr moves imports here.        |
| `downloads` | `/downloads` | pvc or nfs   | —            | Completed downloads. Shared read/write with download client. |

**Notes:**
- `config` must be a PVC — Sonarr writes its database here at runtime.
- `tv` and `downloads` are frequently NFS mounts pointing to a NAS. Set `type: "nfs"` with `server` and `path` fields.
- If `tv` and `downloads` are on the same filesystem, Sonarr can use hardlinks for instant moves (zero-copy import). Ensure both mounts resolve to the same underlying volume.

## Network Configuration

| Port | Protocol | Purpose                          | Exposed via       |
|------|----------|----------------------------------|-------------------|
| 8989 | TCP/HTTP | Sonarr web UI and API            | Service `#config.serviceType` |
| 9707 | TCP/HTTP | Exportarr Prometheus `/metrics`  | Optional — only when `#config.exportarr` is set |

- Default service type is `ClusterIP`. Use `LoadBalancer` or a Gateway/Ingress for external access.
- The Exportarr metrics port is only exposed when the sidecar is enabled. It is typically consumed by a Prometheus `ServiceMonitor` or scrape config, not exposed externally.

## Environment Variables

Variables injected into the Sonarr container via `env:`:

| Variable | Source         | Description                                    |
|----------|----------------|------------------------------------------------|
| `PUID`   | `#config.puid` | UID the container process runs as              |
| `PGID`   | `#config.pgid` | GID the container process runs as              |
| `TZ`     | `#config.timezone` | Timezone string (e.g. `Europe/Stockholm`)  |
| `UMASK`  | `#config.umask` (optional) | File creation mask (e.g. `002`)   |

Variables injected into the Exportarr sidecar (when enabled):

| Variable                      | Source                                        | Description                        |
|-------------------------------|-----------------------------------------------|------------------------------------|
| `PORT`                        | `#config.exportarr.port`                      | Metrics HTTP port                  |
| `URL`                         | Derived: `http://localhost:\(#config.port)`   | Sonarr API base URL                |
| `APIKEY`                      | `#config.exportarr.apiKey` (secret ref)       | Sonarr API key                     |
| `ENABLE_ADDITIONAL_METRICS`   | `#config.exportarr.enableAdditionalMetrics`   | Extra series/episode metrics       |
| `ENABLE_UNKNOWN_QUEUE_ITEMS`  | `#config.exportarr.enableUnknownQueueItems`   | Unknown queue item metrics         |
| `LOG_LEVEL`                   | `#config.exportarr.logLevel`                  | Exportarr log verbosity            |

## Declarative Configuration Strategy

Sonarr stores all its settings in `/config/config.xml`. This file is written and updated at runtime — Sonarr adds API keys, certificate paths, and other dynamic state to it.

**Strategy: seed on first boot, preserve on subsequent boots.**

1. CUE renders the desired `config.xml` content as a template string and stores it in a ConfigMap named `sonarr-config-seed`.
2. An init container (busybox) runs before Sonarr starts and checks: `[ -f /config/config.xml ]`. If the file does not exist, it copies from the seed ConfigMap. If it already exists, it does nothing — preserving all runtime modifications.
3. The main Sonarr container starts with a fully-initialized `config.xml`, avoiding the "first-boot wizard" flow.

**What is NOT seeded:** API key (auto-generated unless explicitly provided via `servarrConfig.apiKey` secret), SSL certificates, database. These are always runtime-generated.

**What IS seeded:** port, bind address, auth method, auth required, branch, log level, URL base, instance name.

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

Where `_servarr` is a computed local struct resolving optional `servarrConfig` fields to their defaults.

## ConfigMap Design

**ConfigMap name:** `sonarr-config-seed`  
**Immutable:** `false` (allows updating seed values without recreating; init container re-runs on pod restart)

```cue
configMaps: {
    "sonarr-config-seed": {
        immutable: false
        data: {
            "config.xml": _configXml
        }
    }
}
```

This ConfigMap is mounted read-only at `/seed` in the init container only. The main Sonarr container does not mount it — Sonarr owns `/config` exclusively after first boot.

**Volume for the ConfigMap:**

```cue
volumes: {
    "sonarr-config-seed": {
        name:      "sonarr-config-seed"
        configMap: spec.configMaps["sonarr-config-seed"]
    }
}
```

## Secrets

| Secret Name       | Data Key  | Description                                           | Required |
|-------------------|-----------|-------------------------------------------------------|----------|
| `sonarr-secrets`  | `api-key` | Sonarr API key — pre-seeded if `servarrConfig.apiKey` is set | Optional |

CUE schema reference (in `#servarrConfig`):

```cue
apiKey?: schemas.#Secret & {
    $secretName: "sonarr-secrets"
    $dataKey:    "api-key"
    $description: "Sonarr API key for API authentication and Exportarr scraping"
}
```

When `apiKey` is set, the init container's rendered `config.xml` includes the `<ApiKey>` element. The value is injected from the Kubernetes Secret at pod start via an `env:` valueFrom secretKeyRef, then written into the config by a more complex seed script (or omitted and left for Sonarr to generate).

**Recommendation for dev:** Leave `servarrConfig.apiKey` unset. Sonarr generates a key on first boot. Then retrieve it from the running instance and store it in a Secret for Exportarr to use.

## Dev Release Values

Example `values:` block for `releases/kind_opm_dev/sonarr/release.cue`:

```cue
values: {
    image: {
        repository: "lscr.io/linuxserver/sonarr"
        tag:        "latest"
        digest:     ""
    }
    port:     8989
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
        tv: {
            mountPath: "/tv"
            type:      "pvc"
            size:      "1Gi"
            storageClass: "local-path"
        }
        downloads: {
            mountPath: "/downloads"
            type:      "pvc"
            size:      "1Gi"
            storageClass: "local-path"
        }
    }

    servarrConfig: {
        authMethod:   "External"
        authRequired: "DisabledForLocalAddresses"
        branch:       "main"
        logLevel:     "info"
        instanceName: "Sonarr"
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
            $secretName: "sonarr-secrets"
            $dataKey:    "api-key"
        }
        enableAdditionalMetrics: false
        enableUnknownQueueItems: false
        logLevel: "info"
    }
```
