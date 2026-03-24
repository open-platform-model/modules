# Jellyfin — Stateful Media Server

**Complexity:** Intermediate  
**Workload Types:** `stateful` (StatefulSet)

A real-world single-component stateful application demonstrating persistent storage, health checks, dynamic volume provisioning, and conditional configuration.

## What This Example Demonstrates

### Core Concepts

- **Stateful workload** (`workload-type: "stateful"`) — Ordered deployment, stable network identity
- **`#Volumes` resource** — Persistent volumes (PVC) and emptyDir volumes
- **`#Scaling` trait** — Replica count (fixed at 1 for stateful single-instance apps)
- **`#HealthCheck` trait** — Liveness and readiness probes with HTTP checks
- **`#RestartPolicy` trait** — Container restart behavior
- **`#Expose` trait** — Service exposure

### OPM Patterns

- **Optional config fields** (`publishedServerUrl?:`) — CUE optional syntax
- **Pattern constraints** (`media: [Name=string]: {...}`) — Dynamic map-based configuration
- **Conditional CUE logic** (`if #config.publishedServerUrl != _|_`) — Conditional environment variables
- **Conditional volume types** (`if lib.type == "pvc"` / `"emptyDir"`) — Dynamic volume type selection
- **Resource requests and limits** — CPU and memory constraints
- **Volume mounts** — Multiple dynamic volume mounts from config

## Architecture

```text
┌─────────────────────────────────────────┐
│  Jellyfin StatefulSet (1 replica)       │
│                                          │
│  Container: lscr.io/linuxserver/jellyfin │
│  Port: 8096                              │
│  Health: /health (HTTP)                  │
│                                          │
│  Volumes:                                │
│  - /config      → PVC (20Gi)             │
│  - /data/movies → PVC (500Gi)            │
│  - /data/tv     → PVC (1Ti)              │
└─────────────────────────────────────────┘
           │
           ▼
    Service (ClusterIP)
      Port: 8096
```

## Configuration Schema

| Field | Type | Constraint | Default | Description |
|-------|------|------------|---------|-------------|
| `image` | string | - | `"lscr.io/linuxserver/jellyfin:latest"` | Container image |
| `port` | int | 1-65535 | `8096` | Exposed service port |
| `puid` | int | - | `1000` | LinuxServer.io user ID |
| `pgid` | int | - | `1000` | LinuxServer.io group ID |
| `timezone` | string | - | `"America/New_York"` | Container timezone |
| `publishedServerUrl` | string? | - | _(optional)_ | Public server URL for client auto-discovery |
| `configStorageSize` | string | - | `"20Gi"` | PVC size for /config directory |
| `media[name].mountPath` | string | - | - | Mount path for media library |
| `media[name].type` | string | `"pvc" \| "emptyDir"` | `"emptyDir"` | Volume type |
| `media[name].size` | string | - | - | PVC size (required if type=pvc) |

## Rendered Kubernetes Resources

| Resource | Name | Type | Notes |
|----------|------|------|-------|
| StatefulSet | `jellyfin` | `apps/v1` | 1 replica, ordered deployment |
| Service | `jellyfin` | `v1` | ClusterIP (port 8096) |
| PersistentVolumeClaim | `config` | `v1` | 20Gi for /config |
| PersistentVolumeClaim | `movies` | `v1` | 500Gi for /data/movies |
| PersistentVolumeClaim | `tv` | `v1` | 1Ti for /data/tv |

**Total:** 5 Kubernetes resources

## Usage

### Build (render to YAML)

```bash
# Render to stdout
opm mod build ./examples/jellyfin

# Render to split files
opm mod build --split ./examples/jellyfin
```

### Customize Values

Create a custom values file for your environment:

```cue
// values_prod.cue
package main

values: {
    image:              "lscr.io/linuxserver/jellyfin:10.8.13"  // Pin version
    timezone:           "Europe/London"
    publishedServerUrl: "https://jellyfin.example.com"
    configStorageSize:  "50Gi"  // Larger config storage

    media: {
        movies: {
            mountPath: "/data/movies"
            type:      "pvc"
            size:      "2Ti"  // 2TB for movies
        }
        tv: {
            mountPath: "/data/tv"
            type:      "pvc"
            size:      "3Ti"  // 3TB for TV shows
        }
        music: {
            mountPath: "/data/music"
            type:      "pvc"
            size:      "500Gi"
        }
    }
}
```

Apply with custom values:

```bash
opm mod apply -f values_prod.cue ./examples/jellyfin
```

## Files

```
jellyfin/
├── cue.mod/module.cue    # CUE dependencies
├── module.cue            # Module metadata and config schema
├── components.cue        # Jellyfin component definition
└── values.cue            # Default configuration values
```

## Key Code Snippets

### Conditional Environment Variable

Only set `JELLYFIN_PublishedServerUrl` if the user provides a value:

```cue
// components.cue (jellyfin component)
spec: {
    container: {
        env: {
            // Always set PUID, PGID, TZ
            PUID: { name: "PUID", value: "\(#config.puid)" }
            PGID: { name: "PGID", value: "\(#config.pgid)" }
            TZ:   { name: "TZ",   value: #config.timezone }

            // Conditionally set published URL
            if #config.publishedServerUrl != _|_ {
                JELLYFIN_PublishedServerUrl: {
                    name:  "JELLYFIN_PublishedServerUrl"
                    value: #config.publishedServerUrl
                }
            }
        }
    }
}
```

If `publishedServerUrl` is undefined (`_|_` in CUE), the env var is omitted entirely.

### Dynamic Volume Configuration

Generate volume definitions from the `media` config map:

```cue
spec: {
    volumes: {
        // Static config volume (always PVC)
        config: {
            name: "config"
            persistentClaim: size: #config.configStorageSize
        }

        // Dynamic media volumes from config
        if #config.media != _|_ {
            for name, lib in #config.media {
                (name): {
                    "name": name
                    if lib.type == "pvc" {
                        persistentClaim: size: lib.size
                    }
                    if lib.type == "emptyDir" {
                        emptyDir: {}
                    }
                }
            }
        }
    }

    container: {
        volumeMounts: {
            config: { name: "config", mountPath: "/config" }

            // Dynamic media mounts
            if #config.media != _|_ {
                for vName, lib in #config.media {
                    (vName): {
                        name:      vName
                        mountPath: lib.mountPath
                    }
                }
            }
        }
    }
}
```

### Health Checks

HTTP-based liveness and readiness probes:

```cue
spec: {
    healthCheck: {
        livenessProbe: {
            httpGet: {
                path: "/health"
                port: 8096
            }
            initialDelaySeconds: 30
            periodSeconds:       10
            timeoutSeconds:      5
            failureThreshold:    3
        }
        readinessProbe: {
            httpGet: {
                path: "/health"
                port: 8096
            }
            initialDelaySeconds: 10
            periodSeconds:       10
            timeoutSeconds:      3
            failureThreshold:    3
        }
    }
}
```

Kubernetes will:

- Wait 30s before starting liveness checks
- Wait 10s before starting readiness checks
- Check every 10 seconds
- Mark pod as unhealthy/not ready after 3 consecutive failures

## Stateful Workload Behavior

StatefulSets provide:

- **Ordered deployment:** Pods start sequentially (`jellyfin-0` before `jellyfin-1`)
- **Stable network identity:** Pod name and hostname never change
- **Persistent volumes:** PVCs are retained even if the pod is deleted
- **Ordered termination:** Pods terminate in reverse order during scale-down

For Jellyfin (single replica), this means:

- Configuration in `/config` persists across pod restarts
- Media library metadata is never lost
- Database files are safe

## Next Steps

- **Add batch processing:** See [multi-tier-module/](../multi-tier-module/) for Job and CronJob examples
- **Add init containers:** See [multi-tier-module/](../multi-tier-module/) for pre-start setup tasks
- **Add update strategies:** See [multi-tier-module/](../multi-tier-module/) for rolling update configuration

## Related Examples

- [blog/](../blog/) — Simple multi-component stateless app
- [multi-tier-module/](../multi-tier-module/) — All workload types with advanced traits
