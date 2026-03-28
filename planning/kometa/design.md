# Kometa Module Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

**Tier:** 3
**Version:** v2.3.0  
**OPM Module Path:** `opmodel.dev/modules/kometa`

---

## Overview

Kometa (formerly Plex Meta Manager) is an automated metadata manager for Plex, Jellyfin,
and Emby. It applies collection artwork, metadata overlays (HD badges, rating banners,
resolution labels), and collection groupings using a declarative YAML configuration.
Kometa reads from TMDb, IMDb, Trakt, MDBList, and other sources to enrich library metadata.

Unlike the arr stack, Kometa is **not a persistent service** — it runs on a schedule
(CronJob) and exits after completing its metadata pass. There is no HTTP port, no web UI,
and no always-on process. This makes it a natural fit for the `#ScheduledTaskWorkload`
blueprint.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  kometa CronJob  (schedule: "0 2 * * *")                     │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  kometa Job Pod (ephemeral, created per schedule tick) │  │
│  │                                                        │  │
│  │  ┌──────────────────────────────────────────────────┐  │  │
│  │  │  kometa container                                │  │  │
│  │  │  image: kometateam/kometa:latest                 │  │  │
│  │  │                                                  │  │  │
│  │  │  /config          (PVC 2Gi — persistent cache)   │  │  │
│  │  │  /config/config.yml  ◀── ConfigMap mount         │  │  │
│  │  │                                                  │  │  │
│  │  │  env:                                            │  │  │
│  │  │    TZ, KOMETA_CONFIG, KOMETA_RUN                 │  │  │
│  │  │    KOMETA_PLEX_TOKEN ◀── Secret ref              │  │  │
│  │  │    KOMETA_TMDB_APIKEY ◀── Secret ref (optional)  │  │  │
│  │  └──────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘

ConfigMap: kometa-config  →  mounted at /config/config.yml (read-only subPath)
Secret:    kometa-secrets →  KOMETA_PLEX_TOKEN, KOMETA_TMDB_APIKEY
```

Key design constraints:
- **No HTTP exposure** — no `#Expose` or service; CronJob pattern only
- **Config is fully declarative** — entire `config.yml` rendered from CUE; no seeding
  needed because Kometa re-reads config fresh on each run
- **Secrets via env vars** — Kometa supports `KOMETA_PLEX_TOKEN` and `KOMETA_TMDB_APIKEY`
  environment variables, avoiding the need to embed secrets in the config YAML

---

## Container Image

| Field      | Value                            |
|------------|----------------------------------|
| Registry   | `docker.io`                      |
| Repository | `kometateam/kometa`              |
| Tag        | `latest`                         |
| Digest     | `""` (not pinned at scaffold time)|
| Base       | Python (not LinuxServer.io)      |
| Version    | v2.3.0                           |

**Not a LinuxServer.io image.** There is no PUID/PGID/TZ injection via env for user
identity — the container runs as its built-in user. TZ is set via the `TZ` environment
variable for timezone-aware scheduling. No UMASK needed.

---

## OPM Module Design

- **Workload type:** `scheduled-task` — CronJob, `restartPolicy: OnFailure`
- **Blueprint used:** `blueprints_workload.#ScheduledTaskWorkload`
- **Resources used:** `resources_config.#ConfigMaps`, `resources_storage.#Volumes`
- **No HTTP port** — no `#Expose`, no `#SecurityContext` (unless non-root required)
- **Config delivery:** ConfigMap mounted as a file at `/config/config.yml` via `subPath`
- **Secret delivery:** Via Kubernetes Secret environment variables (not embedded in config)
- **PVC:** `config` volume persists Kometa's image cache and logs between runs

---

## #config Schema

```cue
package kometa

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

// #kometaPath — a single path entry for metadata_path or overlay_path
// Exactly one of pmm, file, url, or git should be set.
#kometaPath: {
    pmm?:  string  // PMM preset name, e.g. "basic", "imdb", "ribbon"
    file?: string  // Local file path inside the container
    url?:  string  // Remote URL to a YAML definition
    git?:  string  // Git path (Kometa's git resolver format)
}

// #kometaLibrary — configuration for a single Plex library
#kometaLibrary: {
    // Metadata collection definitions (PMM presets or custom files)
    metadataPaths?: [...#kometaPath]
    // Overlay definitions (badge, rating, resolution overlays, etc.)
    overlayPaths?: [...#kometaPath]
    // Mass operations applied to all items in the library
    operations?: {
        // Update critic rating from a source (e.g. "mdb_tomatoesaudience")
        massCriticRatingUpdate?: string
        // Update audience rating from a source
        massAudienceRatingUpdate?: string
        // Update content rating from a source
        massContentRatingUpdate?: string
        // Update episode critic rating for TV libraries
        massEpisodeCriticRatingUpdate?: string
    }
    // Override scheduled run time for this library (e.g. "03:00")
    scheduleTimes?: string
}

// #config — top-level module configuration schema
#config: {
    // Container image; defaults to latest Kometa
    image: schemas.#Image & {
        repository: string | *"kometateam/kometa"
        tag:        string | *"latest"
        digest:     string | *""
    }

    // Container timezone (IANA format) — used by cron scheduling and Kometa's scheduler
    timezone: string | *"Europe/Stockholm"

    // CronJob schedule in cron expression format
    // Default: 2am daily
    schedule: string | *"0 2 * * *"

    // Storage volumes
    storage: {
        // Persistent cache, logs, and overlay images — defaults to 2Gi PVC
        config: #storageVolume & {
            mountPath: *"/config" | string
            type:      *"pvc" | "emptyDir" | "nfs"
            size:      string | *"2Gi"
        }
    }

    // Container resource requests and limits; omit for no constraints
    resources?: schemas.#ResourceRequirementsSchema

    // Plex server URL — e.g. "http://plex.plex.svc.cluster.local:32400"
    plexUrl: string

    // Plex authentication token — injected via KOMETA_PLEX_TOKEN env var from Secret
    plexToken: schemas.#Secret & {
        $secretName: string | *"kometa-secrets"
        $dataKey:    string | *"plex-token"
        $description: "Plex authentication token for Kometa"
    }

    // TMDb API key — injected via KOMETA_TMDB_APIKEY env var from Secret (optional)
    // Required for TMDb-sourced metadata and ratings
    tmdbApiKey?: schemas.#Secret & {
        $secretName: string | *"kometa-secrets"
        $dataKey:    string | *"tmdb-api-key"
        $description: "TMDb API key for metadata enrichment"
    }

    // Tautulli connection for play count stats (optional)
    tautulli?: {
        // Full HTTP URL to Tautulli, e.g. "http://tautulli.tautulli.svc.cluster.local:8181"
        url: string
        // Tautulli API key — embedded in config.yml (no env var support in Kometa)
        // This value will appear in the ConfigMap; use a placeholder and patch via init
        // container if secret injection is required (see Declarative Config Strategy)
        apiKey: schemas.#Secret & {
            $secretName: string
            $dataKey:    string
        }
    }

    // Library definitions keyed by Plex library name (must match exactly)
    // e.g. "Movies", "TV Shows", "4K Movies"
    libraries?: [LibraryName=string]: #kometaLibrary
}
```

---

## Storage Layout

| Name     | Mount Path | Type | Default Size | Description                                              |
|----------|------------|------|--------------|----------------------------------------------------------|
| `config` | `/config`  | pvc  | 2Gi          | Kometa cache files (overlay images, posters), run logs   |

The ConfigMap (`kometa-config`) is mounted inside the `config` volume path as a single
file via `subPath: config.yml`, so `/config/config.yml` is the rendered config while
the rest of `/config` remains the persistent PVC. This avoids overwriting Kometa's cache
and log files with a ConfigMap-managed directory.

---

## Network Configuration

Kometa has **no inbound network exposure**. It is a batch job that makes outbound HTTP
calls to:

- Plex server (configurable URL)
- TMDb API (api.themoviedb.org)
- Other metadata sources (IMDb, Trakt, MDBList, etc.)

No Service, Ingress, or port definitions are needed in this module.

---

## Environment Variables

| Variable              | Source                        | Required | Description                                  |
|-----------------------|-------------------------------|----------|----------------------------------------------|
| `TZ`                  | `#config.timezone`            | Yes      | Container timezone for scheduling             |
| `KOMETA_CONFIG`       | `"/config/config.yml"`        | Yes      | Path to config file (always this path)        |
| `KOMETA_RUN`          | `"true"` (hardcoded)          | Yes      | Forces Kometa to run immediately on start     |
| `KOMETA_PLEX_TOKEN`   | Secret ref: `plexToken`       | Yes      | Plex auth token — Kometa reads this env var   |
| `KOMETA_TMDB_APIKEY`  | Secret ref: `tmdbApiKey`      | No       | TMDb API key — Kometa reads this env var      |

> `KOMETA_RUN=true` is essential for CronJob usage. Without it, Kometa enters its
> internal scheduler loop and never exits, causing the Job to hang. The CronJob's
> schedule drives timing; Kometa should run-and-exit on each invocation.

---

## Declarative Configuration Strategy

Kometa's entire configuration is rendered declaratively from `#config` using
`encoding/yaml` in CUE. This is the **preferred approach** because:

- Kometa reads `config.yml` fresh on every run (no persistent config mutation)
- The full library structure is naturally expressed in CUE
- No seeding or init container is needed for config delivery

### Secret Injection Strategy

Kometa partially supports environment variable overrides:
- `KOMETA_PLEX_TOKEN` — replaces the `plex.token` YAML field ✅
- `KOMETA_TMDB_APIKEY` — replaces the `tmdb.apikey` YAML field ✅
- `tautulli.apikey` — **no env var override** — must be in the YAML ⚠️

**For `plexToken` and `tmdbApiKey`:** Reference Kubernetes Secrets via `secretKeyRef`
in environment variables. The `config.yml` ConfigMap contains placeholder values
(`"${KOMETA_PLEX_TOKEN}"` or simply omits the token field), and Kometa's env var
support handles injection at runtime.

**For `tautulli.apiKey`:** Two options:
1. **Accept in ConfigMap (simpler):** Include the literal API key value in the rendered
   `config.yml`. This means the key lives in a ConfigMap (not a Secret). Acceptable for
   non-critical Tautulli keys in trusted cluster environments.
2. **Init container patch (more secure):** An init container (`busybox`) mounts both the
   ConfigMap and the Secret, then uses `sed` to substitute the placeholder before writing
   the final config to an emptyDir volume:
   ```sh
   sed "s/__TAUTULLI_KEY__/$(cat /secrets/tautulli-key)/g" \
     /seed/config.yml > /config/config.yml
   ```
   The main container mounts the emptyDir instead of the ConfigMap directly.

**Recommended default:** Use env vars for Plex and TMDb tokens. Document the Tautulli
limitation. If Tautulli is configured, use Option 1 (ConfigMap inclusion) unless the
environment requires strict secret segregation.

### CUE Rendering Pattern

```cue
import "encoding/yaml"

configMaps: {
    "kometa-config": {
        immutable: false
        data: {
            "config.yml": yaml.Marshal({
                plex: {
                    url:   #config.plexUrl
                    // token omitted — injected via KOMETA_PLEX_TOKEN env var
                }

                if #config.tmdbApiKey != _|_ {
                    tmdb: {
                        // apikey omitted — injected via KOMETA_TMDB_APIKEY env var
                        region: ""
                    }
                }

                if #config.tautulli != _|_ {
                    tautulli: {
                        url: #config.tautulli.url
                        // apikey: populated from secret or placeholder
                    }
                }

                if #config.libraries != _|_ {
                    libraries: {
                        for libName, libConfig in #config.libraries {
                            (libName): {
                                if libConfig.metadataPaths != _|_ {
                                    metadata_path: [
                                        for p in libConfig.metadataPaths {
                                            if p.pmm != _|_ { pmm: p.pmm }
                                            if p.file != _|_ { file: p.file }
                                            if p.url != _|_ { url: p.url }
                                            if p.git != _|_ { git: p.git }
                                        }
                                    ]
                                }
                                if libConfig.overlayPaths != _|_ {
                                    overlay_path: [
                                        for p in libConfig.overlayPaths {
                                            if p.pmm != _|_ { pmm: p.pmm }
                                        }
                                    ]
                                }
                                if libConfig.operations != _|_ {
                                    operations: {
                                        if libConfig.operations.massCriticRatingUpdate != _|_ {
                                            mass_critic_rating_update: libConfig.operations.massCriticRatingUpdate
                                        }
                                        // ... other operations
                                    }
                                }
                            }
                        }
                    }
                }
            })
        }
    }
}
```

---

## ConfigMap Design

**Name:** `kometa-config`  
**Created:** Always (required for operation)  
**Immutable:** `false`

The ConfigMap holds a single key `config.yml` containing the complete rendered Kometa
configuration. It is mounted into the pod at `/config/config.yml` using `subPath` so it
overlays only the config file within the persistent `/config` PVC.

Mount spec:
```cue
volumeMounts: {
    config: {
        name:      "config"
        mountPath: "/config"
    }
    "kometa-config": {
        name:      "kometa-config"
        mountPath: "/config/config.yml"
        subPath:   "config.yml"
        readOnly:  true
    }
}
```

---

## Secrets

| Secret Name      | Data Key        | Delivery Method           | Description                              |
|------------------|-----------------|---------------------------|------------------------------------------|
| `kometa-secrets` | `plex-token`    | `KOMETA_PLEX_TOKEN` env   | Plex authentication token                |
| `kometa-secrets` | `tmdb-api-key`  | `KOMETA_TMDB_APIKEY` env  | TMDb API key for metadata enrichment     |

Create the secret before deploying:
```bash
kubectl create secret generic kometa-secrets \
  --namespace kometa \
  --from-literal=plex-token=<your-plex-token> \
  --from-literal=tmdb-api-key=<your-tmdb-api-key>
```

Obtain the Plex token from: Account → Preferences → (view XML) → `X-Plex-Token`.
Obtain the TMDb API key from: https://www.themoviedb.org/settings/api.

---

## Dev Release Values

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
    schedule: "0 2 * * *"  // Run daily at 2am
    storage: {
        config: {
            mountPath:    "/config"
            type:         "pvc"
            size:         "2Gi"
            storageClass: "local-path"
        }
    }
    resources: {
        requests: {
            cpu:    "200m"
            memory: "512Mi"
        }
        limits: {
            cpu:    "2000m"
            memory: "2Gi"
        }
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
