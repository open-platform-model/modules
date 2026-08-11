# nvidia-device-plugin

Exposes NVIDIA GPUs to Kubernetes as schedulable `nvidia.com/gpu` resources.

| | |
|---|---|
| Upstream | [NVIDIA/k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin) |
| Pinned release | `v0.19.3` |
| Registry path | `opmodel.dev/modules/nvidia_device_plugin@v2` |
| Catalog | `opmodel.dev/catalogs/opm@v2` ≥ `v2.0.0-alpha.2` |

## Architecture

One component, `plugin`: a DaemonSet that speaks the device-plugin gRPC protocol
to each node's kubelet over a socket in `/var/lib/kubelet/device-plugins`.

It needs **no Kubernetes API access**, so the module emits no ServiceAccount,
Role or RoleBinding, and no token is mounted. The container is unprivileged —
`allowPrivilegeEscalation: false`, all capabilities dropped.

## The two prerequisites

Both are on the **node**, not in this module. If either is missing the plugin
starts cleanly and advertises zero GPUs, which looks like a scheduling problem
rather than a missing driver.

### 1. A RuntimeClass named `nvidia`

The plugin only sees a GPU when its pod runs under the NVIDIA container
runtime. This module sets `runtimeClassName` (upstream's
`--set=runtimeClassName=nvidia`) but does **not** create the RuntimeClass:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
```

`handler` must name a runtime the node's containerd knows. On Talos the
`nvidia-container-toolkit` system extension registers exactly that handler, and
Sidero deliberately does not make it the node-wide default — hence per-pod
selection.

Set `runtimeClass: ""` only where the NVIDIA runtime is already the containerd
default; the field is then omitted entirely rather than emitted empty.

### 2. A working driver on the node

On Talos, system extensions at a **matching driver version**, plus the kernel
modules in machine config:

```yaml
machine:
  kernel:
    modules:
      - name: nvidia
      - name: nvidia_uvm
      - name: nvidia_drm
      - name: nvidia_modeset
```

⚠ **Pascal and older must use the `-lts` branch.** 580 is the last driver line
supporting Maxwell/Pascal/Volta, and the open-GPU kernel modules require Turing
or newer (they depend on the GSP). For a Quadro P2200 or GTX 10-series that
means `siderolabs/nonfree-kmod-nvidia-lts` + `siderolabs/nvidia-container-toolkit-lts`
— the `-production` branch will not drive the card.

## Quick start

```bash
opm module build . --platform <platform.cue>
```

Workloads then request a GPU with:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

GPU pods must **also** set `runtimeClassName: nvidia` themselves — the plugin's
own runtime class does not extend to consumers.

## Configuration

| Field | Default | Notes |
|---|---|---|
| `image.repository` | `nvcr.io/nvidia/k8s-device-plugin` | |
| `image.tag` | `v0.19.3` | |
| `runtimeClass` | `"nvidia"` | `""` omits the field entirely |
| `migStrategy` | `"none"` | `single` / `mixed` for MIG partitioning |
| `deviceListStrategy` | `"envvar"` | or `volume-mounts`, `cdi-annotations`, `cdi-cri` |
| `failOnInitError` | `true` | fail loudly rather than advertise a broken GPU |
| `passDeviceSpecs` | `false` | pass device major/minor instead of paths |
| `resources` | *(unset)* | upstream ships none |
| `nodeSelector` | `{}` | set `nvidia.com/gpu.present: "true"` with NFD/GFD |
| `priorityClassName` | `system-node-critical` | so it is not evicted before its dependants |

The DaemonSet always tolerates `nvidia.com/gpu=:NoSchedule`, so it can land on
dedicated GPU nodes — without that, a tainted node would never receive the
plugin that makes its GPUs schedulable.
