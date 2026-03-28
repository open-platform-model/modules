# Bazarr Module Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

**Tier:** 2
**Version:** v1.5.6  
**OPM Module Path:** `opmodel.dev/modules/bazarr`

---

## Overview

Bazarr is a subtitle manager companion to Sonarr and Radarr. It automatically searches
configured subtitle providers (OpenSubtitles, Subscene, Addic7ed, etc.) and downloads
subtitles for movies and TV shows already managed by Radarr and Sonarr. Bazarr watches
for new media added by those tools and fetches subtitles according to language preferences
and scoring rules.

Bazarr is a stateful, always-on HTTP service. It reads the Sonarr/Radarr APIs to discover
media, so both API keys and service URLs are required configuration. It also exposes its own
API key which Exportarr uses to scrape Prometheus metrics.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  bazarr Pod                                             │
│                                                         │
│  ┌──────────────┐   init   ┌───────────────────────┐   │
│  │ config-seed  │ ──────▶  │  /config/config/      │   │
│  │ (busybox)    │          │    config.yaml (seed)  │   │
│  └──────────────┘          └───────────────────────┘   │
│                                                         │
│  ┌──────────────────────┐  ┌────────────────────────┐  │
│  │  bazarr              │  │  exportarr (optional)  │  │
│  │  :6767               │  │  :9707                 │  │
│  │  /config  (PVC 5Gi)  │  │  scrapes :6767/api     │  │
│  │  /tv      (shared)   │  └────────────────────────┘  │
│  │  /movies  (shared)   │                               │
│  └──────────────────────┘                               │
└─────────────────────────────────────────────────────────┘

ConfigMap: bazarr-config  →  init container copies to /config/config/config.yaml
                              (only if file not already present)
Secret:    bazarr-secrets →  Exportarr API key ref
```

Key integration points:
- **Sonarr** — reads TV library via HTTP API; `sonarr.sonarr.svc.cluster.local:8989`
- **Radarr** — reads movie library via HTTP API; `radarr.radarr.svc.cluster.local:7878`
- **Exportarr** — optional sidecar scraping Bazarr's `/api/...` endpoint on port 6767

---

## Container Image

| Field      | Value                              |
|------------|------------------------------------|
| Registry   | `lscr.io`                          |
| Repository | `lscr.io/linuxserver/bazarr`       |
| Tag        | `latest`                           |
| Digest     | `""` (not pinned at scaffold time) |
| Base       | LinuxServer.io (Ubuntu + s6-overlay)|
| Version    | v1.5.6                             |

LinuxServer.io images require PUID/PGID/TZ environment variables to set the process
user identity. UMASK is optional (defaults to `022` in the image).

---

## OPM Module Design

- **Workload type:** `stateful` — single replica, `restartPolicy: Always`
- **Traits used:** `#Container`, `#Volumes`, `#ConfigMaps`, `#Scaling`, `#RestartPolicy`,
  `#Expose`, `#SecurityContext`
- **Init container:** busybox seeds `/config/config/config.yaml` from ConfigMap on first run
- **Optional sidecar:** Exportarr for Prometheus metrics (conditional on `#config.exportarr`)
- **Health check:** HTTP GET `/` on port 6767

Note the **nested config directory**: Bazarr's config file lives at
`/config/config/config.yaml`, not `/config/config.yaml`. The init container must
target the inner directory.

---

## #config Schema

```cue
package bazarr

import (
    schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// #storageVolume — shared schema for all volume definitions
#storageVolume: {
    mountPath:     string
    type:          "pvc" | "emptyDir" | "nfs"
    size?:         string  // required when type == "pvc"
    storageClass?: string  // optional; only used when type == "pvc"
    server?:       string  // required when type == "nfs"
    path?:         string  // required when type == "nfs"
}

// #exportarrSidecar — optional Prometheus metrics sidecar
#exportarrSidecar: {
    image: schemas.#Image & {
        repository: string | *"ghcr.io/onedr0p/exportarr"
        tag:        string | *"latest"
        digest:     string | *""
    }
    // Port exportarr listens on for Prometheus scrape
    port: int | *9707
    // Bazarr API key — injected from a Kubernetes Secret
    apiKey: schemas.#Secret & {
        $secretName: string | *"bazarr-secrets"
        $dataKey:    string | *"api-key"
    }
}

// #bazarrIntegration — connection details for one arr app
#bazarrIntegration: {
    // Full HTTP URL to the arr service, e.g. "http://sonarr.sonarr.svc.cluster.local:8989"
    url:      string
    // API key secret reference
    apiKey:   schemas.#Secret & {
        $secretName: string
        $dataKey:    string
    }
    // URL base path if arr is behind a reverse proxy subpath (usually empty)
    baseUrl?: string | *""
}

// #bazarrConfig — optional declarative seed for Bazarr's config.yaml
#bazarrConfig: {
    // Sonarr integration; omit to skip Sonarr configuration
    sonarr?: #bazarrIntegration
    // Radarr integration; omit to skip Radarr configuration
    radarr?: #bazarrIntegration
    // Bazarr application log level
    logLevel?: "DEBUG" | "INFO" | "WARNING" | "ERROR" | *"INFO"
}

// #config — top-level module configuration schema
#config: {
    // Container image; defaults to latest LinuxServer.io Bazarr
    image: schemas.#Image & {
        repository: string | *"lscr.io/linuxserver/bazarr"
        tag:        string | *"latest"
        digest:     string | *""
    }

    // Web UI port exposed by the container and service
    port: int & >0 & <=65535 | *6767

    // LinuxServer.io user/group identity for file ownership
    puid: int | *1000
    pgid: int | *1000

    // Container timezone (IANA format)
    timezone: string | *"Europe/Stockholm"

    // Optional file creation mask; LinuxServer default is "022"
    umask?: string

    // Storage volumes
    storage: {
        // Application state — database, logs, config — defaults to 5Gi PVC
        config: #storageVolume & {
            mountPath: *"/config" | string
            type:      *"pvc" | "emptyDir" | "nfs"
            size:      string | *"5Gi"
        }
        // TV library mount — must match Sonarr's media volume path
        tv: #storageVolume & {
            mountPath: *"/tv" | string
        }
        // Movie library mount — must match Radarr's media volume path
        movies: #storageVolume & {
            mountPath: *"/movies" | string
        }
    }

    // Kubernetes Service type for the web UI
    serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"

    // Container resource requests and limits; omit for no constraints
    resources?: schemas.#ResourceRequirementsSchema

    // Optional Exportarr sidecar for Prometheus metrics
    exportarr?: #exportarrSidecar

    // Optional declarative seed config rendered into config.yaml.
    // When present, a ConfigMap is created and seeded via init container.
    // Bazarr may override values at runtime through its UI — seed is one-time.
    bazarrConfig?: #bazarrConfig
}
```

---

## Storage Layout

| Name     | Mount Path | Type        | Default Size | Description                                              |
|----------|------------|-------------|--------------|----------------------------------------------------------|
| `config` | `/config`  | pvc         | 5Gi          | Application database, logs, config directory             |
| `tv`     | `/tv`      | pvc or nfs  | —            | TV library (shared with Sonarr; typically NFS or same PVC) |
| `movies` | `/movies`  | pvc or nfs  | —            | Movie library (shared with Radarr; typically NFS or same PVC) |

> `tv` and `movies` must use the same backing storage as Sonarr and Radarr respectively
> so Bazarr can read the actual media files for path matching. In most homelab setups
> these are NFS mounts pointing at the same NAS share.

---

## Network Configuration

| Port | Protocol | Name      | Purpose                             |
|------|----------|-----------|-------------------------------------|
| 6767 | TCP      | `http`    | Web UI and REST API                 |
| 9707 | TCP      | `metrics` | Exportarr Prometheus scrape (optional) |

Service type defaults to `ClusterIP`. Ingress or `LoadBalancer` are configured at the
release level. Exportarr port is only present when `#config.exportarr` is defined.

---

## Environment Variables

| Variable | Source              | Required | Description                            |
|----------|---------------------|----------|----------------------------------------|
| `PUID`   | `#config.puid`      | Yes      | Process UID for file ownership         |
| `PGID`   | `#config.pgid`      | Yes      | Process GID for file ownership         |
| `TZ`     | `#config.timezone`  | Yes      | Container timezone                     |
| `UMASK`  | `#config.umask`     | No       | File creation mask (default: `022`)    |

Exportarr sidecar environment variables (when `exportarr` is set):

| Variable | Source                              | Description                        |
|----------|-------------------------------------|------------------------------------|
| `PORT`   | `#config.exportarr.port`            | Exportarr listen port              |
| `URL`    | `"http://localhost:\(#config.port)"`| Target Bazarr URL                  |
| `APIKEY` | Secret ref from `exportarr.apiKey`  | Bazarr API key for scraping        |

---

## Declarative Configuration Strategy

Bazarr's config file lives at `/config/config/config.yaml` (note the **nested** `config/`
subdirectory under `/config`). The strategy:

1. **Render** `config.yaml` from `#config.bazarrConfig` using `encoding/yaml` in CUE →
   stored in ConfigMap `bazarr-config` under key `config.yaml`.
2. **Init container** (`busybox:latest`) mounts the ConfigMap at `/seed/` and the config
   PVC at `/config/`. On startup it runs:
   ```sh
   mkdir -p /config/config && \
   [ -f /config/config/config.yaml ] || cp /seed/config.yaml /config/config/config.yaml
   ```
   The guard (`[ -f ... ] ||`) makes the copy **idempotent** — Bazarr's runtime edits
   via the UI are never overwritten on restart.
3. **Main container** starts after the init container exits successfully.

When `#config.bazarrConfig` is absent (undefined), no ConfigMap is created and no init
container is injected — Bazarr starts fresh with its interactive setup wizard.

Sonarr and Radarr API keys are **not** embedded in the config.yaml seed. They must be set
through the Bazarr UI after first run, or via the `bazarrConfig.sonarr.apiKey` and
`bazarrConfig.radarr.apiKey` Secret references (which the init container script can
inject from mounted secret volumes as an enhancement).

---

## ConfigMap Design

**Name:** `bazarr-config`  
**Created when:** `#config.bazarrConfig != _|_`  
**Immutable:** `false` (Bazarr can extend/override at runtime)

```yaml
# Rendered content of config.yaml key
general:
  ip: 0.0.0.0
  port: 6767           # from #config.port
  base_url: ""         # from bazarrConfig (default empty)
  use_sonarr: true     # present when bazarrConfig.sonarr is set
  use_radarr: true     # present when bazarrConfig.radarr is set

sonarr:                # present when bazarrConfig.sonarr is set
  ip: <parsed from url>
  port: <parsed from url>
  base_url: ""
  apikey: ""           # placeholder — user sets via UI or secret injection

radarr:                # present when bazarrConfig.radarr is set
  ip: <parsed from url>
  port: <parsed from url>
  base_url: ""
  apikey: ""           # placeholder — user sets via UI or secret injection

log:
  level: INFO          # from bazarrConfig.logLevel
```

> CUE renders this via `encoding/yaml` marshal of a CUE struct. The `ip`/`port` fields
> in Bazarr's config are parsed separately from the URL — the CUE rendering will use
> the full service DNS name in the `ip` field (Bazarr accepts hostnames there).

---

## Secrets

| Secret Name       | Data Key   | Used By         | Description                            |
|-------------------|------------|-----------------|----------------------------------------|
| `bazarr-secrets`  | `api-key`  | Exportarr       | Bazarr API key for metrics scraping    |

The Bazarr API key is auto-generated by Bazarr on first boot and stored in its SQLite
database. To use Exportarr, the operator must:
1. Boot Bazarr, complete setup.
2. Copy the API key from Settings → General → API Key.
3. Create the `bazarr-secrets` Kubernetes Secret manually:
   ```bash
   kubectl create secret generic bazarr-secrets \
     --namespace bazarr \
     --from-literal=api-key=<your-bazarr-api-key>
   ```
4. The Exportarr sidecar will read it via `secretKeyRef`.

Sonarr/Radarr API keys (if used in the seed config) should each have their own secrets
referenced via `bazarrConfig.sonarr.apiKey` and `bazarrConfig.radarr.apiKey`.

---

## Dev Release Values

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
            server:    "192.168.1.100"
            path:      "/mnt/data/media/tv"
        }
        movies: {
            mountPath: "/movies"
            type:      "nfs"
            server:    "192.168.1.100"
            path:      "/mnt/data/media/movies"
        }
    }
    bazarrConfig: {
        sonarr: {
            url: "http://sonarr.sonarr.svc.cluster.local:8989"
            apiKey: {
                $secretName: "sonarr-secrets"
                $dataKey:    "api-key"
            }
        }
        radarr: {
            url: "http://radarr.radarr.svc.cluster.local:7878"
            apiKey: {
                $secretName: "radarr-secrets"
                $dataKey:    "api-key"
            }
        }
        logLevel: "INFO"
    }
    // Exportarr metrics sidecar — enable after first boot and API key is set
    // exportarr: {
    //     image: { repository: "ghcr.io/onedr0p/exportarr", tag: "latest", digest: "" }
    //     port:   9707
    //     apiKey: { $secretName: "bazarr-secrets", $dataKey: "api-key" }
    // }
}
```
