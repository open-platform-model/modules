# Exportarr Sidecar Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../../DESIGN_PATTERNS.md).

## Overview

Exportarr is a Prometheus metrics exporter for the arr application suite (Sonarr, Radarr, Prowlarr, Bazarr). It scrapes each app's HTTP API and exposes metrics at `/metrics` on a configurable port. Metrics include queue depth, wanted/missing counts, disk space, and health check statuses.

**Exportarr is NOT a standalone OPM module.** It runs as a sidecar container inside each arr module's pod — co-located with the application it scrapes. This design avoids cross-pod network calls, reuses the app's API key secret, and keeps metrics collection close to the source.

Upstream version: v2.3.0  
Image: `ghcr.io/onedr0p/exportarr:v2.3.0`  
Configuration: environment variables only — no config files.

## Architecture

Exportarr runs as a second container in the same Kubernetes pod as the arr application it monitors. Because both containers share the pod's network namespace, Exportarr reaches the app via `http://localhost:<app_port>` — no service DNS required.

```
┌──────────────────────────────────────────────────────────────┐
│  Pod: sonarr                                                 │
│                                                              │
│  container: sonarr          container: exportarr             │
│  ┌─────────────────┐        ┌──────────────────────────┐    │
│  │ port 8989 (HTTP)│◄───────│ URL=http://localhost:8989 │    │
│  │ /api/v3/...     │  API   │ PORT=9707                 │    │
│  └─────────────────┘        │ APIKEY=<secret>           │    │
│                             │ port 9707 (/metrics)      │    │
│                             └──────────────────────────┘    │
│                                       ▲                      │
│                                       │ scrape               │
│                                  Prometheus                  │
└──────────────────────────────────────────────────────────────┘
```

**Why sidecar instead of standalone deployment:**

1. **Localhost access:** Scraping via localhost eliminates network latency, DNS resolution, and the need for a separate Service for metrics.
2. **Shared lifecycle:** The exporter starts and stops with the application. No orphaned exporters pointing at dead services.
3. **Secret co-location:** The API key secret is already mounted in the pod for the arr app — Exportarr reads it from the same env var injection point.
4. **No extra Service objects:** Prometheus can scrape the pod IP directly on port 9707.

## Container Image

| Field      | Value                               |
|------------|-------------------------------------|
| Repository | `ghcr.io/onedr0p/exportarr`         |
| Tag        | `v2.3.0`                            |
| Digest     | `""` (resolved at deploy time)      |
| Entrypoint | `/exportarr <app>` (e.g. `sonarr`)  |

The Exportarr binary takes the application name as a subcommand: `exportarr sonarr`, `exportarr radarr`, etc. This must be set as the container command in each arr module's sidecar spec.

## OPM Module Design

There is **no `modules/exportarr/` directory.** The `#exportarrSidecar` CUE definition is copied into each arr module that supports it. This is intentional — CUE module boundaries prevent sharing definitions across modules without publishing an intermediate shared module, and the definition is small enough to copy.

**Modules that embed `#exportarrSidecar`:**
- `modules/sonarr/` — command: `exportarr sonarr`
- `modules/radarr/` — command: `exportarr radarr`
- `modules/prowlarr/` — command: `exportarr prowlarr` (future)
- `modules/bazarr/` — command: `exportarr bazarr` (future)

Each module defines `#exportarrSidecar` locally in its `module.cue` and adds `exportarr?: #exportarrSidecar` to its `#config`. The sidecar container is rendered in `components.cue` only when `#config.exportarr != _|_`.

## #exportarrSidecar Schema

This is the canonical definition. Copy it verbatim into each arr `module.cue`:

```cue
// #exportarrSidecar configures the optional Exportarr Prometheus metrics sidecar.
// When set in #config.exportarr, a second container is added to the pod.
// Exportarr scrapes the arr app's API via localhost and exposes metrics on #config.exportarr.port.
#exportarrSidecar: {
    // Exportarr container image.
    image: schemas.#Image & {
        repository: string | *"ghcr.io/onedr0p/exportarr"
        tag:        string | *"v2.3.0"
        digest:     string | *""
    }

    // Port on which Exportarr exposes the Prometheus /metrics endpoint.
    port: int | *9707

    // Required: API key for authenticating against the arr app's HTTP API.
    // Must reference an existing Kubernetes Secret.
    apiKey: schemas.#Secret & {
        $secretName: string
        $dataKey:    string
    }

    // Expose additional app-specific metrics (series health, episode counts, etc.).
    enableAdditionalMetrics: bool | *false

    // Include items stuck in an unknown queue state in queue metrics.
    enableUnknownQueueItems: bool | *false

    // Exportarr log verbosity.
    logLevel: "debug" | "info" | "warn" | "error" | *"info"

    // Optional resource constraints for the sidecar container.
    // When absent, no limits are applied.
    resources?: schemas.#ResourceRequirementsSchema
}
```

## Environment Variables

All Exportarr configuration is via environment variables — no config file is required.

| Variable                      | Default       | Description                                              |
|-------------------------------|---------------|----------------------------------------------------------|
| `PORT`                        | `9707`        | Prometheus metrics HTTP port                             |
| `URL`                         | (required)    | Base URL of the arr app: `http://localhost:<app_port>`   |
| `APIKEY`                      | (required)    | API key for the arr app — injected from Secret           |
| `ENABLE_ADDITIONAL_METRICS`   | `false`       | Emit extended series/movie/queue metrics                 |
| `ENABLE_UNKNOWN_QUEUE_ITEMS`  | `false`       | Count items in unknown queue state                       |
| `LOG_LEVEL`                   | `info`        | Log verbosity: debug, info, warn, error                  |

## Storage Layout

Exportarr is stateless — no persistent volumes required. It reads from the arr API over HTTP and writes metrics to an in-memory registry.

## Network Configuration

| Port | Protocol | Purpose                             |
|------|----------|-------------------------------------|
| 9707 | TCP/HTTP | Prometheus `/metrics` endpoint      |

The port is configurable via `#config.exportarr.port`. It is exposed as a named port `metrics` on the pod spec so Prometheus `PodMonitor` or `ServiceMonitor` resources can discover it by name.

## Declarative Configuration Strategy

Exportarr is fully configured via environment variables. There are no config files to seed, no ConfigMaps to mount. All fields in `#exportarrSidecar` map directly to container `env:` entries in `components.cue`.

The `URL` env var is derived at render time from the parent module's `#config.port`:

```cue
URL: {
    name:  "URL"
    value: "http://localhost:\(#config.port)"
}
```

The `APIKEY` env var is injected from a Kubernetes Secret via `valueFrom.secretKeyRef`:

```cue
APIKEY: {
    name: "APIKEY"
    valueFrom: secretKeyRef: {
        name: #config.exportarr.apiKey.$secretName
        key:  #config.exportarr.apiKey.$dataKey
    }
}
```

## ConfigMap Design

None. Exportarr requires no ConfigMaps.

## Secrets

Exportarr requires the arr app's API key. This is the same secret used by the arr app itself — no additional Secret objects are needed.

| Used Secret     | Data Key  | Description                          |
|-----------------|-----------|--------------------------------------|
| (app-specific)  | `api-key` | e.g. `sonarr-secrets` / `api-key`    |

The secret reference is declared in `#config.exportarr.apiKey` and injected as `APIKEY` via `valueFrom.secretKeyRef`.

## Integration Guide

This section shows exactly how to embed `#exportarrSidecar` into an arr module's `components.cue`.

### Step 1: Add `#exportarrSidecar` to `module.cue`

Copy the definition verbatim (see `#exportarrSidecar Schema` above) into the module's `module.cue`, and add the optional field to `#config`:

```cue
#config: {
    // ... existing fields ...

    // Optional Exportarr metrics sidecar.
    // When set, a second container is injected into the pod.
    exportarr?: #exportarrSidecar
}
```

### Step 2: Add sidecar container in `components.cue`

Inside the main component's `spec:` block, after the primary `container:` definition, add:

```cue
spec: {
    // ... scaling, restartPolicy, container, expose, volumes, configMaps ...

    // Exportarr sidecar — only rendered when #config.exportarr is set
    if #config.exportarr != _|_ {
        sidecarContainers: [{
            name:    "exportarr"
            image:   #config.exportarr.image
            command: ["exportarr", "sonarr"]  // replace "sonarr" with the app name

            ports: metrics: {
                name:       "metrics"
                targetPort: #config.exportarr.port
            }

            env: {
                PORT: {
                    name:  "PORT"
                    value: "\(#config.exportarr.port)"
                }
                URL: {
                    name:  "URL"
                    value: "http://localhost:\(#config.port)"
                }
                APIKEY: {
                    name: "APIKEY"
                    valueFrom: secretKeyRef: {
                        name: #config.exportarr.apiKey.$secretName
                        key:  #config.exportarr.apiKey.$dataKey
                    }
                }
                ENABLE_ADDITIONAL_METRICS: {
                    name:  "ENABLE_ADDITIONAL_METRICS"
                    value: "\(#config.exportarr.enableAdditionalMetrics)"
                }
                ENABLE_UNKNOWN_QUEUE_ITEMS: {
                    name:  "ENABLE_UNKNOWN_QUEUE_ITEMS"
                    value: "\(#config.exportarr.enableUnknownQueueItems)"
                }
                LOG_LEVEL: {
                    name:  "LOG_LEVEL"
                    value: #config.exportarr.logLevel
                }
            }

            if #config.exportarr.resources != _|_ {
                resources: #config.exportarr.resources
            }
        }]
    }
}
```

### Step 3: Expose metrics port on the Service (optional)

If Prometheus uses a `ServiceMonitor`, the metrics port must be exposed via the Service. Add it to `expose:`:

```cue
expose: {
    ports: {
        http: container.ports.http & {
            exposedPort: #config.port
        }
        if #config.exportarr != _|_ {
            metrics: {
                name:        "metrics"
                targetPort:  #config.exportarr.port
                exposedPort: #config.exportarr.port
            }
        }
    }
    type: #config.serviceType
}
```

### Step 4: Validate

After integrating, run from `modules/`:

```bash
task fmt
task vet
task vet CONCRETE=true   # using debugValues that include exportarr
```

## Dev Release Values

When enabling Exportarr in a dev release, add the following to the `values:` block. Example for Sonarr (`releases/kind_opm_dev/sonarr/release.cue`):

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
    resources: {
        requests: {
            cpu:    "50m"
            memory: "64Mi"
        }
        limits: {
            cpu:    "200m"
            memory: "128Mi"
        }
    }
}
```

Adjust `$secretName` to match the secret for each arr app (`radarr-secrets`, etc.).
