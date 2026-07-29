# Jellyfin — Stateful Media Server

**Complexity:** Intermediate  
**Workload Types:** `stateful` (StatefulSet)

A real-world single-component stateful application demonstrating persistent storage, health checks, dynamic volume provisioning, and conditional configuration.

> **v2 — rebased onto the OPM core catalog** (`opmodel.dev/catalogs/opm@v1`,
> module path `opmodel.dev/modules/jellyfin@v2`). The component now composes the
> catalog's `#StatefulWorkload` blueprint plus the `#Expose`, `#SecurityContext`,
> `#ConfigMaps`, and (optional) `#HttpRoute` traits. The previous K8up backup
> feature was dropped — the core catalog has no backup resource. Config storage,
> media mounts, the Service, optional GPU passthrough, optional HTTPRoute, and
> optional Serilog logging remain. Some teaching snippets further down predate
> the rewrite; `module.cue` + `components.cue` are the source of truth.

> **v2.2.0 — catalog bump `opm@v1.0.0-alpha.1` → `alpha.6`, core `alpha.1` →
> `alpha.3`**, plus the optional `podScheduling` and `podMetadata` blocks.
>
> **One behaviour change, and it is a bug fix you may be on the wrong side of.**
> Through `alpha.1` the Service transformer built its port as
> `exposedPort | *targetPort`, which reads as "exposedPort, defaulting to
> targetPort" and means the opposite — in CUE a default arm wins over a concrete
> one, so **`port` was silently discarded** and the Service always published
> `targetPort`. Verified by render: with `port: 8920`, `alpha.1` emits
> `port: 8096` and `alpha.6` emits `port: 8920`. A release that set `port` to
> anything other than 8096 was not getting it and will now start. A release that
> left `port` at 8096 renders **byte-identical** across the bump (confirmed by
> diffing both renders — only `metadata.version` and its derived UUIDs move).
>
> Nothing else in the six intervening catalog versions touches this module: the
> C9 StatefulSet `serviceName` fix applies only when `expose.name` is set (it is
> not), and the new HPA transformer matches the component but emits nothing
> because `scaling.auto` is unset. Rendered object names — including PVC
> `<instance>-<component>-config` — are unchanged, so existing restore tooling
> keyed to `jellyfin-jellyfin-config` keeps working.

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
| `podScheduling` | object? | - | _(optional)_ | `nodeSelector` / `tolerations` / `priorityClassName`. Needed to steer the pod at a node that actually has the GPU `resources.gpu` asks for |
| `podMetadata` | object? | - | _(optional)_ | `labels` / `annotations` on the **pod template only** — never the selector |

## Rendered Kubernetes Resources

| Resource | Name | Type | Notes |
|----------|------|------|-------|
| StatefulSet | `jellyfin` | `apps/v1` | 1 replica, ordered deployment |
| Service | `jellyfin` | `v1` | ClusterIP (port 8096) |
| PersistentVolumeClaim | `config` | `v1` | 20Gi for /config |
| PersistentVolumeClaim | `movies` | `v1` | 500Gi for /data/movies |
| PersistentVolumeClaim | `tv` | `v1` | 1Ti for /data/tv |

**Total:** 5 Kubernetes resources

## Usage (ModuleRelease)

The module is consumed by the opm-operator via a `ModuleRelease` CR that names
the published module by path + version and supplies a `values` block matching
`#config`:

```yaml
apiVersion: releases.opmodel.dev/v1alpha1
kind: ModuleRelease
metadata:
  name: jellyfin
  namespace: jellyfin
spec:
  module:
    path: opmodel.dev/modules/jellyfin@v2
    version: v2.0.0
  serviceAccountName: opm-applier
  prune: true
  values:
    timezone: Europe/London
    publishedServerUrl: https://jellyfin.example.com
    serviceType: LoadBalancer
    storage:
      config:
        type: pvc
        size: 50Gi
        storageClass: standard
      media:
        movies: { mountPath: /media/movies, type: pvc, size: 2Ti, storageClass: standard }
        tv:     { mountPath: /media/tv,     type: pvc, size: 3Ti, storageClass: standard }
```

Optional features available through `values`: `resources` (incl. `resources.gpu`
for Intel/render-group passthrough), `logging` (renders a Serilog ConfigMap
mounted at `/config/logging.json`), and `httpRoute` (renders a Gateway API
HTTPRoute).

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
