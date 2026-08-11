# nvidia-gpu-exporter

NVIDIA GPU metrics as a DaemonSet. Wraps
[utkuozdemir/nvidia_gpu_exporter](https://github.com/utkuozdemir/nvidia_gpu_exporter) (MIT),
pinned to **1.13.1**, reading the driver through **NVML** by default.

Built for answering *"is hardware transcoding actually happening, on how many streams, and is
the card throttling"* — not for datacenter fleet telemetry. See
[Why not DCGM](#why-not-dcgm).

```yaml
apiVersion: opmodel.dev/v1alpha1
kind: ModuleInstance
metadata:
  name: nvidia-gpu          # renders objects named `nvidia-gpu-exporter`
  namespace: monitoring
spec:
  module:
    path: opmodel.dev/modules/nvidia_gpu_exporter@v2
    version: v2.0.0
  values: {}                # every default is the verified one
  prune: true
```

## What it exports

Measured on a Quadro P2200 (Pascal, GP106, driver 580.173.02), not taken from the README.
**83 metric names** on the `nvml` backend. The ones that carry the work:

| Metric | Idle | 1080p30 NVENC (real-time) | Flat out |
|---|---|---|---|
| `nvidia_smi_utilization_encoder_ratio` | 0 | 0.17–0.30 | **0.62–0.73** |
| `nvidia_smi_utilization_decoder_ratio` | 0 | 0 | 0 |
| `nvidia_smi_utilization_gpu_ratio` | 0 | 0.02 | 0.09–0.11 |
| `nvidia_smi_encoder_stats_session_count` | 0 | **1** | 1 |
| `nvidia_smi_power_draw_watts` | 4.87–6.5 | 22.0–22.6 | 29 |
| `nvidia_smi_temperature_gpu` | 36 | 49–50 | 47–48 |
| `nvidia_smi_memory_used_bytes` | 2 MiB | 232 MiB | 232 MiB |
| `nvidia_smi_clocks_current_sm_clock_hz` | 139 MHz | 1037 MHz | 1746 MHz |

Plus fan speed, all four current/max clocks, eight `clocks_event_reasons_*` throttle flags,
PCIe link gen/width, memory total/free/reserved, power limits, and `nvidia_smi_gpu_info`
carrying name, driver version, VBIOS and compute capability as labels.

Health: `nvidia_smi_command_exit_code`, `nvidia_smi_failed_scrapes_total`.

The exporter also **watches NVML XID error events** at startup
(`msg="watching for GPU XID error events" gpus=1`); the counter materialises when one occurs.

### ⚠ Utilisation metrics are ratios (0–1), not percentages

`nvidia_smi_utilization_encoder_ratio` reads `0.17` for 17 %. Any panel sharing an axis with a
percentage-native exporter must scale by 100. Dropping that produces a chart that reads
`0.17 %` during a transcode and looks like idle rather than like a bug.

### ⚠ Encoder utilisation is a duty cycle, not a capacity measure

nvidia-smi and DCGM disagreed at the same instant under identical load (17 % vs 30 %) because
they average over different sampling windows. Good "is it working" signal; poor capacity
signal. **Do not attach a threshold or an alert to it.**

### ⚠ `encoder_stats_average_fps` / `_latency` are unconfirmed on Pascal

Both read `0` in every sample taken during evaluation, but never with a confirmed concurrent
session at that exact instant. They are exported; whether they populate on driver 580.173.02
is unverified. Confirm before building a panel on them.

## How it reaches the GPU

**Not through a device-plugin allocation.** Extended resources are exclusive — the plugin
hands a card to exactly one holder — and that holder should be the workload doing the
transcoding, not the observer watching it. A `nvidia.com/gpu` request here would sit Pending
forever once the real consumer holds the card.

Instead the pod joins the **`nvidia` RuntimeClass** and sets `NVIDIA_VISIBLE_DEVICES=all`,
which makes the container runtime inject the driver and device nodes with no scheduler
allocation involved.

> Verified: with a separate pod holding the node's only `nvidia.com/gpu` **and** an encode
> running, this exporter kept reading the card (22.08 W, 50 °C).

Two consequences worth internalising:

- **`runtimeClass` is required, and getting it wrong fails silently.** Without it the
  container gets the default runtime, nothing is injected, and the exporter starts cleanly
  reporting nothing. Not a crash — an empty dashboard.
- **`NVIDIA_VISIBLE_DEVICES` reads back as `void` inside the container.** The runtime consumes
  the variable, converts it to device injection, and rewrites it so the legacy hook cannot
  inject twice. A container with full access reports `void`. Debug with `nvidia-smi -L`, never
  by echoing the variable.

This mechanism is also a soft bypass of device-plugin accounting: any pod that can set the
RuntimeClass and that env var gets the GPU without an allocation. That is inherent to how the
NVIDIA container stack works, not something this module introduces — but it means
`nvidia.com/gpu: 1` is an accounting convention rather than an enforcement boundary.

## Security posture

**Fully unprivileged, and unlike the Intel exporter that is not a compromise.** Reading NVML
through the injected device nodes needs no capability at all. Verified together on Talos:

```yaml
runAsNonRoot: true
runAsUser: 65534
runAsGroup: 65534
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities: {drop: ["ALL"]}
```

The exporter still reported live power and temperature under all of the above. **This module
satisfies the `restricted` Pod Security Standard** and does not need a `privileged` namespace
— the sibling `intel_gpu_exporter` does, because the i915 PMU needs `PERFMON`/`SYS_ADMIN`.

## Backends

`--collect.backend`, exposed as `backend`:

| | resident | metric names | note |
|---|---|---|---|
| `nvml` *(default)* | 22.7 MiB | 83 | reads libnvidia-ml; no fork per scrape. Upstream marks it **experimental** |
| `exec` | 7.5 MiB | 87 | forks `nvidia-smi` every scrape |
| `demo` | — | — | synthetic data, no GPU needed |

`nvml` is the default because it removes a process fork per scrape forever. `exec` is the
one-field fallback if NVML misbehaves — **switching backends does not require changing the
image**, both binaries carry both; the `-nvml` tag differs only in which it defaults to.

> `demo` must never reach a real cluster. It serves plausible fabricated numbers, which is
> worse than serving none.

## Why not DCGM

NVIDIA's own `dcgm-exporter` is the obvious institutional choice, and it does work — it
correctly reported `DCGM_FI_DEV_ENC_UTIL 70` and `POWER_USAGE 29.5 W` under load on the same
card. Three measured facts moved the decision:

| | this module | dcgm-exporter 4.6.0-4.8.3 |
|---|---|---|
| Resident memory | **22.7 MiB** | **399 MiB** |
| Image (amd64, compressed) | 33 MiB | 56 MiB |
| Added capabilities | none | `SYS_ADMIN` |
| NVENC session count | **yes** | no |
| Fan / throttle reasons / PCIe link | yes | no |
| Default fields materialising on Pascal | — | **15 of 26** |

The eleven DCGM fields that never appear on Pascal include `DCGM_FI_DEV_XID_ERRORS` — the one
field that would have justified DCGM on reliability grounds — and every `DCGM_FI_PROF_*`.
`DCGM_FI_DEV_MEMORY_TEMP` is reported as a confident `0` on a card with no memory-temperature
sensor, which is exactly the kind of value that ends up on a dashboard looking real.

DCGM becomes the right answer on datacenter silicon. It is not the right answer for one Quadro
encoding video on a node whose memory limits already sit at 95 %.

## Pinning

> ⚠ **`1.13.1` is newer than `1.3.2`.** Semver, not decimals. `1.3.2` is an old tag that reads
> newer at a glance and is what a careless pin lands on. The digest is pinned alongside the
> tag: the digest binds, the tag makes the version legible.

## Naming

Instance `nvidia-gpu` + component `exporter` → objects named **`nvidia-gpu-exporter`**. Naming
the instance `nvidia-gpu-exporter` would render `nvidia-gpu-exporter-exporter`.

The Service name is load-bearing when a scrape job matches on `service_name;port_name`. The
port is always named `metrics`. Set `serviceName` only if the default does not already produce
what the scrape job expects — a second place to keep in sync is a cost, not a feature.

## ⚠ nodeSelector is an architecture filter, not a GPU filter

The default `kubernetes.io/arch: amd64` is exact on a single-GPU-node cluster and wrong
everywhere else: the DaemonSet will land on GPU-less nodes, where the runtime has no driver to
inject and the pod fails to start. There is no node label to select on unless something
publishes one — the plain device plugin does not label nodes, and NFD is a separate install.
Where NFD is deployed, narrow it:

```yaml
nodeSelector:
  feature.node.kubernetes.io/pci-10de.present: "true"
```

## Scraping

There is no annotation-driven discovery in this module — it exposes a plain ClusterIP Service
with a port named `metrics`, and the scrape job is the consumer's business. For
Prometheus/VictoriaMetrics endpoint discovery:

```yaml
- job_name: nvidia-gpu-exporter
  kubernetes_sd_configs:
    - role: endpoints
      namespaces: {names: ["monitoring"]}
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
      action: keep
      regex: nvidia-gpu-exporter;metrics
    - source_labels: [__meta_kubernetes_pod_node_name]
      target_label: node
```
