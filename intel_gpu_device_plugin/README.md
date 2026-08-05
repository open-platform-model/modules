# intel-gpu-device-plugin

Exposes Intel GPUs to Kubernetes as schedulable `gpu.intel.com/i915` (or
`gpu.intel.com/xe`) resources.

| | |
|---|---|
| Upstream | [intel/intel-device-plugins-for-kubernetes](https://github.com/intel/intel-device-plugins-for-kubernetes) |
| Pinned release | `0.36.0` |
| Registry path | `opmodel.dev/modules/intel_gpu_device_plugin@v1` |
| Catalog | `opmodel.dev/catalogs/opm@v1` ≥ `v1.0.0-alpha.7` |

## Architecture

One component, `plugin`: a DaemonSet that enumerates Intel GPUs from
`/sys/class/drm` and `/dev/dri`, then registers each with the node's kubelet
over a device-plugin gRPC socket.

It needs **no Kubernetes API access**, so the module emits no ServiceAccount,
Role or RoleBinding. The container is unprivileged — read-only root filesystem,
all capabilities dropped. GPU access comes from the `/dev/dri` host mount, not
from privilege.

| Volume | Host path | Mode |
|---|---|---|
| `dev-dri` | `/dev/dri` | read-only |
| `sysfs-drm` | `/sys/class/drm` | read-only |
| `dp-socket` | `/var/lib/kubelet/device-plugins` | writable — the socket lands here |
| `cdi-path` | `/var/run/cdi` | writable, `DirectoryOrCreate` |

## Node prerequisite

The node must already have a working Intel GPU driver — this module only
advertises what the kernel exposes. Without one the plugin starts cleanly and
advertises zero devices, which presents as a scheduling problem rather than a
missing driver.

On Talos that means the `siderolabs/i915` system extension, **plus
`siderolabs/mei` for Arc discrete GPUs** — the Management Engine is a
prerequisite for them, and it is easy to miss because the plugin does not
complain about it.

Use `i915` for Arc Alchemist (DG2, e.g. A310/A380) and older integrated parts;
`xe` is the default only for Xe2/Battlemage and newer. The kernel driver decides
which resource name is advertised, and workloads must request the matching one.

## Quick start

```bash
opm module build . --platform <platform.cue>
```

Workloads then request a GPU with:

```yaml
resources:
  limits:
    gpu.intel.com/i915: 1
```

## Configuration

| Field | Default | Notes |
|---|---|---|
| `image.repository` | `intel/intel-gpu-plugin` | |
| `image.tag` | `0.36.0` | |
| `sharedDevNum` | `1` | containers per GPU — see the warning below |
| `enableMonitoring` | `false` | `-enable-monitoring` |
| `allocationPolicy` | `"none"` | `balanced` / `packed` when a node has several GPUs |
| `resources` | 40m/45Mi → 100m/90Mi | matches upstream |
| `allowIds` / `denyIds` | `""` | filter GPUs by PCI device ID, e.g. `0x49c5,0x49c6` |
| `healthManagement` | `false` | needs the levelzero sidecar; the temp limits do nothing without it |
| `bypath` | `"single"` | `none` / `all` for DRM by-path symlink exposure |
| `logLevel` | `2` | 0–4 |
| `tempLimit` / `gpuTempLimit` / `memoryTempLimit` | `0` | Celsius, `0` disables; require `healthManagement` |
| `nodeSelector` | `{"kubernetes.io/arch": "amd64"}` | add `intel.feature.node.kubernetes.io/gpu: "true"` with NFD |

⚠ **`sharedDevNum > 1` is plain overcommit.** The plugin hands out more
references to the same device; there is no isolation, quota or fair-share
between the containers that land on it. It suits transcoding and inference,
which rarely saturate a GPU, and does not suit anything needing predictable
throughput.

## Ported from the v0 module

This replaces `intel_gpu_device_plugin@v0` (last published `v0.0.14` against
upstream 0.35.0), which lives on the `v0_legacy` branch. The registry path is
shared but the majors are disjoint, satisfying the cross-train separation rule.

Changes made in the port:

- Rebuilt on the v1 catalog — `bp.#DaemonWorkload` instead of a bare
  `#Container` plus a hand-set `workload-type: daemon` label, and `res.`/`tr.`
  in place of the `opm/v1alpha1/...` packages.
- **`nodeSelector` now actually applies.** The v0 module accepted it in
  `#config` but never wired it into the component, so its DaemonSet ran on every
  node regardless of what was configured.
- `readOnly` is set explicitly on every volume and mount; the v1 schema has no
  default for it and the render fails without.
- Upstream tag moved 0.35.0 → 0.36.0.

Unchanged: the whole `#config` surface, the CLI-argument assembly, and the
volume layout.

⚠ Upstream also sets `seLinuxOptions` (`container_device_plugin_t`) and
`seccompProfile` (`RuntimeDefault`). Neither is modelled by
`res.#SecurityContextSchema`, so neither is emitted — apply them via a
cluster-level mutating webhook if your policy requires them. This is a hardening
gap, not a functional one.
