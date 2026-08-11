# Jellyfin — Stateful Media Server

**Complexity:** Intermediate  
**Workload Types:** `stateful` (StatefulSet)

A real-world single-component stateful application demonstrating persistent storage, health checks, dynamic volume provisioning, and conditional configuration.

> **v2 — rebased onto the OPM core catalog** (now `opmodel.dev/catalogs/opm@v2`,
> module path `opmodel.dev/modules/jellyfin@v3` on the v2 line). The component now composes the
> catalog's `#StatefulWorkload` blueprint plus the `#Expose`, `#SecurityContext`,
> `#ConfigMaps`, and (optional) `#HttpRoute` traits. The previous K8up backup
> feature was dropped — the core catalog has no backup resource. Config storage,
> media mounts, the Service, optional GPU passthrough, optional HTTPRoute, and
> optional Serilog logging remain. Some teaching snippets further down predate
> the rewrite; `module.cue` + `components.cue` are the source of truth.

> **v2.5.0 — hardware transcoding, one card at a time.** A new
> `hardwareAcceleration` block takes a single `vendor: "intel" | "nvidia"` and
> derives everything that vendor needs: the extended-resource claim, the
> `RuntimeClass` (NVIDIA only), `NVIDIA_DRIVER_CAPABILITIES` (NVIDIA only) and
> the DRI render GIDs. `vendor` is a scalar, so "both cards at once" is not
> expressible — extended resources are not shareable, so a second claim would
> strand every other GPU consumer on the node.
>
> Why a discriminator rather than four independent knobs: NVIDIA needs the claim
> **and** a RuntimeClass **and** a capability env var, and getting any of the
> three wrong fails *silently* — healthy pod, card visible to `nvidia-smi`,
> every encode quietly on the CPU.
>
> Catalog bump `alpha.6` → `alpha.7`, for the `RuntimeClass` trait. That trait is
> the only difference between those two catalog versions, so an instance setting
> no `hardwareAcceleration` renders byte-identically to v2.4.0 (verified). The
> pre-v2.5.0 `resources.gpu` path still works and still gets the render GIDs.
>
> ⚠ **This is half the change.** The module gets the device, the runtime and the
> permissions into the container; it cannot make Jellyfin *use* them.
> `HardwareAccelerationType` lives in `/config/encoding.xml` — UI state on the
> config PVC (Dashboard → Playback), the same class as `TranscodingTempPath`.
> Verify from a transcode log naming an `*_qsv` / `*_nvenc` encoder, never from
> the dashboard toggle: a device attached with the UI left at `none` is a CPU
> transcode that looks exactly like success.

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
| `media[name].readOnly` | bool | - | `false` | Mount read-only. Set it on a library shared with another Jellyfin — a metadata refresh writes `.nfo`/`.jpg`/poster files back into the media tree, so two servers on one dataset overwrite each other's sidecars. For `type: nfs` this marks the volume **source** read-only as well as the mount; for `type: pvc` only the mount, because `#PersistentClaimSchema` carries no `readOnly` |
| `hardwareAcceleration.vendor` | string | `"intel" \| "nvidia"` | _(optional)_ | Attach ONE GPU for hardware transcoding. Everything below derives from it. Omit the whole block for CPU-only |
| `hardwareAcceleration.count` | uint | `>0` | `1` | Devices to claim. 1 unless a node carries several of the same card |
| `hardwareAcceleration.resource` | string? | - | `gpu.intel.com/i915` / `nvidia.com/gpu` | Extended resource the plugin advertises. Override only for a different plugin name — the Intel one follows the **kernel driver**, so Xe2/Battlemage and newer advertise `gpu.intel.com/xe`, not `i915` |
| `hardwareAcceleration.runtimeClass` | string | - | `"nvidia"` | **NVIDIA only**, ignored for Intel. Must already exist in the cluster. Required on Talos, where the `nvidia` containerd handler is deliberately not the node default — without it `/dev/nvidia*` never appears and every NVENC encode fails on a healthy-looking pod |
| `hardwareAcceleration.driverCapabilities` | string | - | `"compute,video,utility"` | **NVIDIA only.** `video` is what NVENC needs and what the runtime does *not* grant by default; `compute` is what CUDA HDR tone-mapping needs. `NVIDIA_VISIBLE_DEVICES` is never emitted — the device plugin owns it |
| `hardwareAcceleration.renderGroups` | [...uint] | - | `[44, 109]` | Supplemental GIDs for opening `/dev/dri/renderD*` |
| `podScheduling` | object? | - | _(optional)_ | `nodeSelector` / `tolerations` / `priorityClassName`. **Not** needed for GPU placement — a GPU claim is an extended-resource request, which already constrains the pod to nodes advertising it. This is for taints on dedicated GPU nodes |
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
    path: opmodel.dev/modules/jellyfin@v3
    version: v3.0.0
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

Optional features available through `values`: `hardwareAcceleration` (attaches
one GPU — see below), `resources` (requests/limits), `logging` (renders a
Serilog ConfigMap mounted at `/config/logging.json`), and `httpRoute` (renders a
Gateway API HTTPRoute).

### Hardware transcoding

Switching card is a one-word edit:

```yaml
values:
  hardwareAcceleration:
    vendor: intel      # gpu.intel.com/i915 + render GIDs, default runtime
    # vendor: nvidia   # nvidia.com/gpu + runtimeClassName: nvidia
    #                  # + NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
```

Cluster-side prerequisites the module does **not** create: the matching device
plugin (`intel-device-plugins` / `nvidia-device-plugin`), the driver on the node
(on Talos, the `i915`+`mei` or `nonfree-kmod-nvidia-*`+`nvidia-container-toolkit-*`
system extensions), and — for NVIDIA — a cluster `RuntimeClass` named by
`runtimeClass`.

Then set `HardwareAccelerationType` to `qsv` or `nvenc` in Dashboard → Playback.
For QSV, check the device path there matches the render node the plugin actually
injected: only the allocated device is passed in, and its number follows the
host's DRM enumeration order, not the vendor.

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

Startup, liveness and readiness probes all GET `healthPath` on port 8096. Every
probe runs on a 10s period with a 5s timeout, so each `failureThreshold` step is
worth roughly 10 seconds of grace:

| Probe | `failureThreshold` default | Budget | Tunable with |
| --- | --- | --- | --- |
| startup | 30 | ~300s | `startupFailureThreshold` |
| liveness | 18 | ~180s | `livenessFailureThreshold` |
| readiness | 12 | ~120s | `readinessFailureThreshold` |

Plus `terminationGracePeriodSeconds` (default 120) for the SIGTERM → SIGKILL window.

**Why the budgets are this generous.** Jellyfin's built-in *Optimize database*
scheduled task VACUUMs `jellyfin.db` every 6 hours, and VACUUM holds SQLite's
exclusive lock for its whole run. `/health` is ASP.NET Core health-check
middleware with a DbContext check attached, so it blocks for the duration. A
232 MB database on iSCSI measured 40–45s per vacuum against the module's
previous hardcoded 30s liveness budget — kubelet restarted the container ~26s
into every vacuum, four times a day, exiting a clean `0` each time because
Jellyfin handles SIGTERM gracefully.

Vacuum time scales with database size, so raise these on a larger library or
slower storage. Readiness is deliberately generous too: the workload is
single-replica, so dropping the only endpoint mid-vacuum cuts active clients
without routing them anywhere better.

```cue
values: {
    // Defaults shown; all four are optional.
    healthPath:                    "/health"
    startupFailureThreshold:       30
    livenessFailureThreshold:      18
    readinessFailureThreshold:     12
    terminationGracePeriodSeconds: 120
}
```

Set `healthPath: "/System/Ping"` to take the database out of the health signal
entirely — it answers anonymously without touching SQLite.

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
