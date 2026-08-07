# Intel GPU Exporter

**Complexity:** Simple
**Workload Types:** `daemon` (DaemonSet)

Runs [clambin/intel-gpu-exporter](https://github.com/clambin/intel-gpu-exporter) on every
Intel GPU node: it shells out to `intel_gpu_top -J` and republishes the engine statistics
as Prometheus metrics. Answers the question a device plugin cannot — *is the GPU actually
being used, and by which engine?*

> ⚠ **Not a port of `intel_gpu_exporter@v0`.** That module wraps Intel **XPU Manager**,
> which reads Data Center GPUs (Flex, Max) and Arc **Pro** through Level Zero and the
> Intel Graphics Compute Runtime — it does not support consumer Arc (Alchemist/DG2)
> parts. Same module name, different upstream, deliberately. The v0 module stays on the
> `v0_legacy` branch.

## What you actually get

Measured on a discrete **Arc A310** (DG2, i915 driver) with exporter 0.6.1 — not copied
from the upstream README, which promises more than this hardware delivers:

| Metric | Status |
|---|---|
| `gpumon_engine_usage{engine, attrib}` | ☑ **the deliverable.** `engine` = `Video`, `VideoEnhance`, `Render/3D`, `Blitter`, `Compute`; `attrib` = `busy`, `sema`, `wait` |
| `gpumon_power{type}` | ⚠ emitted, but a constant **0** — this card's `intel_gpu_top` JSON has no `power` key |
| `gpumon_frequency`, `gpumon_rc6`, `gpumon_clients_count`, `gpumon_imc_*` | ✗ documented upstream, **not produced at all** here |

For a transcoding host, `gpumon_engine_usage{engine="Video",attrib="busy"}` is the number
worth alerting and dashboarding on, with `VideoEnhance` beside it for scaling and
tone-mapping.

**Get power, temperature, fan and voltage from node-exporter instead**, which already
publishes them for the same card and where they are real:

```promql
rate(node_hwmon_energy_joule_total{chip=~".*"}[5m])   # watts, joined via
node_hwmon_chip_names{chip_name="i915"}               # → the chip label
node_hwmon_power_max_watt                             # the card's own cap
```

## ⚠ Pin the image; `latest` is a trap

The published images lag the repository, and `latest` lags furthest. At the time of
writing it resolved to **0.3.1**, which:

- has **no `-device` flag** — it cannot be pointed at a specific GPU;
- listens on **`:9090`** via a bare `-addr`, not `:9100` via `-prom.addr`;
- labels engines `Video/0`, `Video/1` rather than `Video`, so every query written
  against the documented names silently matches nothing.

The newest published tag is **0.6.1** (the repo is tagged v0.7.1). This module pins 0.6.1
by tag *and* index digest, and its argument list is written for that release.

## Configuration

| Field | Type | Default | Description |
|---|---|---|---|
| `image` | object | `ghcr.io/clambin/intel-gpu-exporter:0.6.1` + digest | see the pinning note above |
| `device` | string? | _(unset)_ | intel_gpu_top's `-d`, e.g. `drm:/dev/dri/card0` or `pci:slot=0000:00:08.0`. Optional on a single-i915 host; **set it wherever more than one GPU exists** — a discrete card's PMU registers as `i915_<pci-slot>`, not a bare `i915` |
| `interval` | string | `5s` | sampling interval; the scrape interval should not be shorter |
| `port` | int | `9100` | metrics listener (`-prom.addr`) |
| `metricsPath` | string | `/metrics` | `-prom.path` |
| `logLevel` | enum | `info` | `-log.level` |
| `driPath` | string | `/dev/dri` | host DRI directory, mounted **read-only** |
| `capabilities` | [...string] | `["PERFMON","SYS_ADMIN"]` | added so `perf_event_open` on the i915 PMU is permitted |
| `serviceName` | string? | _(unset)_ | exact Service name, for scrape jobs that match on `service_name;port_name`. The port is always named `metrics` |
| `resources` | object | 10m/32Mi → 200m/128Mi | re-check before shortening `interval` |
| `nodeSelector` | object | `{"kubernetes.io/arch":"amd64"}` | narrow it on a mixed cluster; without one the DaemonSet also lands on GPU-less nodes and reports nothing |

## Two things that are easy to get wrong

**It must not claim `gpu.intel.com/i915`.** Extended resources are exclusive — the device
plugin hands a card to exactly one holder (`sharedDevNum` defaults to 1), and that holder
should be the workload doing the transcoding, not the observer watching it. This module
reaches the GPU through a read-only `/dev/dri` hostPath and the PMU, which needs no
allocation, so it can watch a card another pod owns.

**It needs a `privileged` Pod Security Standard namespace.** Added capabilities are
forbidden under `baseline`. Note this is *not* `privileged: true` on the container —
upstream's example asks for that, and `PERFMON` + `SYS_ADMIN` was verified sufficient.

## Usage (ModuleInstance)

```yaml
apiVersion: opmodel.dev/v1alpha1
kind: ModuleInstance
metadata:
  name: intel-gpu
  namespace: monitoring
spec:
  module:
    path: opmodel.dev/modules/intel_gpu_exporter@v1
    version: v1.0.0
  values:
    device: drm:/dev/dri/card0
    serviceName: intel-gpu-exporter
  prune: true
```

Renders a DaemonSet plus a ClusterIP Service on port 9100 with its port named `metrics`.

## Files

```
intel_gpu_exporter/
├── cue.mod/module.cue    # CUE dependencies
├── module.cue            # metadata + #config schema
├── components.cue        # DaemonSet + Service
└── README.md
```
