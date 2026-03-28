# Wolf Module — Deployment Notes

Issues, root causes, and fixes encountered during first deployment to `lnn1-mrspel`
(Talos v1.12.5 / K8s v1.33.0, AMD Radeon 780M iGPU, NVIDIA RTX 3060 discrete).

---

## Issue 1 — PodSecurity "baseline" blocks hostPath volumes

**Symptom**

```
pods "wolf-wolf-0" is forbidden: violates PodSecurity "baseline:latest":
  hostPath volumes (volumes "dev", "udev")
```

**Root cause**  
When OPM creates the `gaming` namespace, Kubernetes defaults to enforcing the
`baseline` PodSecurity profile. Wolf mounts `/dev` and `/run/udev` as hostPath
volumes, which `baseline` prohibits.

**Fix**  
Create the namespace manually with the `privileged` PSA labels _before_ deploying:

```bash
kubectl create namespace gaming
kubectl label namespace gaming \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged
```

**Status** ✓ Resolved

---

## Issue 2 — `hostNetwork` not supported by StatefulSet transformer

**Symptom**  
Wolf needs `hostNetwork: true` so Moonlight can reach it on standard ports
(47984–48200). These ports are outside the Kubernetes NodePort range (30000–32767)
so NodePort or LoadBalancer alone cannot work without port remapping.

**Root cause**  
`#HostNetworkTrait` existed in the catalog and was wired into the DaemonSet
transformer but was absent from the StatefulSet transformer.

**Fix** — `catalog/v1alpha1/providers/kubernetes/transformers/statefulset_transformer.cue`

- Added `network_traits "opmodel.dev/opm/v1alpha1/traits/network@v1"` import
- Added `"opmodel.dev/traits/network/host-network@v1": network_traits.#HostNetworkTrait` to `optionalTraits`
- Added `if #component.spec.hostNetwork != _|_ { hostNetwork: #component.spec.hostNetwork }` to the pod template spec

**Status** ✓ Resolved — catalog published as v1.2.20

---

## Issue 3 — Scheduler host-port conflict blocks pod scheduling

**Symptom**

```
0/1 nodes are available: 1 node(s) didn't have free ports for the requested pod ports.
```

Pod stays `Pending` indefinitely after deletion+recreation.

**Root cause**  
When `hostNetwork: true` is set on a pod, Kubernetes' scheduler tracks all declared
`containerPort` entries as reserved host ports. A stale port reservation from a
previously deleted pod lingered in the scheduler cache, blocking the new pod.

**Fix** — `examples/modules/wolf/components.cue`  
Removed the `ports: { ... }` block from the wolf main container spec. With
`hostNetwork: true`, Wolf binds to the host network directly — declaring container
ports is redundant and triggers the host-port conflict check. The Service port
mapping is driven entirely by the `expose:` spec, which is unaffected.

**Status** ✓ Resolved

---

## Issue 4 — PVCs fail to provision (local-path UserVolume not provisioned)

**Symptom**

```
MountVolume.SetUp failed for volume "wolf-config": mkdir /var/mnt/wolf: read-only file system
failed to provision volume: create process timeout after 120 seconds
```

**Root cause**  
Two sub-issues:

1. The Talos `UserVolumeConfig` for `local-path-provisioner` had not been applied
   to the running node — the `local-path-provisioner` UserVolume partition does not
   appear in `talosctl get volumestatus`. The `EPHEMERAL` partition (`/dev/sdb4`,
   498 GB) uses all remaining disk space, leaving no room for the user volume.

2. `/var/mnt/` is read-only in Talos (squashfs overlay). Only paths under `/var/lib/`
   are writable on the EPHEMERAL partition.

**Fix (temporary — experimentation)**  
Switch wolf storage to `hostPath` on the writable EPHEMERAL filesystem, and DinD
storage to `emptyDir` (Docker layers rebuilt on pod restart):

```cue
storage: config: {
  type:         "hostPath"
  path:         "/var/lib/wolf"
  hostPathType: "DirectoryOrCreate"
}

dind: storage: {
  type: "emptyDir"
}
```

**Permanent fix (TODO)**  
Apply the Talos machine config changes to provision the `local-path-provisioner`
UserVolume on `nvme0n1`, then switch back to:

```cue
storage: config: { type: "pvc", size: "50Gi", storageClass: "local-path" }
dind: storage: { type: "pvc", size: "100Gi", storageClass: "local-path" }
```

**Status** ⚠ Temporary workaround applied — UserVolume provisioning is a TODO

---

## Issue 5 — DinD crashes + Wolf GPU error (missing privileged)

**Symptom**  
DinD container:

```
mount: permission denied (are you root?)
Could not mount /sys/kernel/security.
```

Wolf container:

```
Error during drmGetDevice for /dev/dri/renderD128, Invalid argument
```

**Root cause**  
Both containers need `securityContext.privileged: true`:

- DinD requires it for Docker-in-Docker (network namespaces, cgroups, mounts)
- Wolf requires it to open DRI GPU render nodes and create virtual input devices

The OPM `#SecurityContextSchema` did not model `privileged`, and
`container_helpers.cue` did not map any container-level security context fields.

**Fix — Schema** (`catalog/v1alpha1/schemas/security.cue`)  

- Added `privileged?: bool` to `#SecurityContextSchema`
- Made `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation` optional
  (they were required, which made the schema unusable for privileged workloads)

**Fix — Transformer** (`catalog/v1alpha1/providers/kubernetes/transformers/container_helpers.cue`)  
Added full container-level security context mapping in `#ToK8sContainer`:
`privileged`, `runAsNonRoot`, `runAsUser`, `runAsGroup`, `readOnlyRootFilesystem`,
`allowPrivilegeEscalation`, `capabilities`.

**Fix — Schema** (`catalog/v1alpha1/schemas/workload.cue`)  
Added `securityContext?: #SecurityContextSchema` to `#ContainerSchema` so
containers (main, sidecar, init) can specify their own security context.

**Fix — Module** (`examples/modules/wolf/components.cue`)  

```cue
// wolf container
securityContext: { privileged: true }

// dind sidecar
securityContext: { privileged: true }
```

**Status** ✓ Resolved — catalog published as v1.2.20

---

## Issue 6 — GPU: NVIDIA vs AMD render node selection

**Context**  
The node has two GPUs:

- NVIDIA RTX 3060 — no `/dev/dri/` render node because `nvidia_drm.modeset` is
  not enabled in the kernel args. NVIDIA exposes `/dev/nvidia0` etc. but no DRI node.
- AMD Radeon 780M (iGPU) — fully initialized by `amdgpu`, exposes `/dev/dri/renderD128`

**Finding**  
`/dev/dri/renderD128` is the AMD GPU, not NVIDIA. The release was already using
`gpu.type: "intelamd"` and `renderNode: "/dev/dri/renderD128"` — correct.

Wolf's VAAPI hardware encoding works on the AMD 780M:

```
INFO | Using h264 encoder: va
INFO | Using h265 encoder: va
INFO | Using av1 encoder: va
INFO | Using zero copy pipeline on AMD (/dev/dri/renderD128)
```

**Status** ✓ No change needed — AMD path was already correct

---

## Issue 7 — Node reboots (NVIDIA PCIe ASPM)

**Symptom**  
Node enters `NotReady` / `Unschedulable` state during deployment, requiring
`kubectl wait` + `kubectl uncordon` to recover.

**Root cause**  
The NVIDIA RTX 3060 enters a low-power PCIe link state it cannot reliably wake
from, causing spontaneous reboots. The Talos config includes `pcie_aspm=off`
kernel arg to mitigate this, but reboots still occurred during the session.

**Workaround**  
After each reboot:

```bash
kubectl wait node lnn1-mrspel-control-plane-1 --for=condition=Ready --timeout=180s
kubectl uncordon lnn1-mrspel-control-plane-1   # if still cordoned
```

**Permanent fix (TODO)**  
Investigate whether `pcie_aspm=off` is being applied correctly. Alternative:
disable the NVIDIA GPU entirely at the OS level (`modprobe.blacklist=nvidia`) if
the AMD iGPU is sufficient for Wolf. Alternatively, enable `nvidia_drm.modeset=1`
and use the NVIDIA GPU instead (requires driver volume setup).

**Status** ⚠ Mitigation in place — root cause not fully resolved

---

## Issue 8 — PulseAudio socket path mismatch

**Symptom**

```
ERROR | [GSTREAMER] Pipeline error: Failed to connect: Connection refused
WARN  | pulsesrc.c: error: Failed to connect: Connection refused
```

**Root cause**  
The GOW PulseAudio image creates its socket at `$XDG_RUNTIME_DIR/pulse-socket`
(a direct file), **not** at the `libpulse` default of `$XDG_RUNTIME_DIR/pulse/native`.
Wolf's GStreamer `pulsesrc` plugin uses the `libpulse` default path, which does not
exist — the `pulse/` directory contains only a `pid` file, no `native` socket.

Note: Wolf's `PULSE_ROUTER` (used for sink/source management) DID connect
successfully — it must be using a different connection mechanism or retrying
with `PULSE_SERVER` correctly. The GStreamer plugin does not.

**Fix** — `examples/modules/wolf/components.cue`  

```cue
PULSE_SERVER: {
  name:  "PULSE_SERVER"
  value: "/run/wolf-sockets/pulse-socket"
}
```

**Status** ✓ Resolved — see also Issue 9 for the socket sharing fix required

---

## Issue 9 — XDG sockets not shared between wolf and DinD child containers

**Symptom**  
Wolf's GStreamer audio pipeline fails with "Connection refused" to PulseAudio even
after the `PULSE_SERVER` fix. Wolf-UI crashes with "Can't connect to a Wayland
display." despite Wolf reporting "Wayland display ready".

### Investigation (session 1) — overlayfs hypothesis

Initial `stat` showed different devices for the `xdg-sockets` emptyDir as seen
from the wolf container vs DinD:

```
wolf container:  /tmp/wolf-sockets → Device: 8,20       (XFS K8s emptyDir)
dind container:  /tmp/wolf-sockets → Device: 20001ah     (overlayfs)
```

**Hypothesis:** DinD's overlayfs was intercepting writes by child containers.

Attempted fix: switched DinD `--storage-driver overlay2` (disabling Docker 29's
default `containerd-snapshotter` / `io.containerd.snapshotter.v1.overlayfs` mode).

Result: **did not fix the problem.** The PA container's mount was still backed by
tmpfs. The storage driver is unrelated to the root cause.

### Investigation (session 2) — DinD `/tmp` is tmpfs (root cause found)

Inspecting DinD's `/proc/self/mountinfo` revealed:

```
1307 1960 0:452 / /tmp rw,relatime shared:211 - tmpfs none rw,seclabel
1972 1960 8:20 /lib/kubelet/pods/.../xdg-sockets /tmp/wolf-sockets rw,relatime shared:150 - xfs /dev/sdb4
```

**DinD has `/tmp` itself mounted as a tmpfs (device `0:452`).** The K8s emptyDir
is then mounted _on top_ of this tmpfs at `/tmp/wolf-sockets`. When Docker inside
DinD creates child containers (PulseAudio, Wolf-UI) with
`-v /tmp/wolf-sockets:/tmp/pulse`, the kernel bind-mount resolution sees `/tmp` as
the tmpfs device and uses it as the bind source. The more-specific mount at
`/tmp/wolf-sockets` (the real emptyDir) is not used.

Write test confirmed: a file written to `/tmp/wolf-sockets` from a DinD child
container appeared in DinD's tmpfs overlay — **not** in the wolf K8s container's
emptyDir view.

Verification via PA container mountinfo:

```
# BEFORE fix (source = tmpfs, device 0:538):
1464 1399 0:538 /wolf-sockets /tmp/pulse rw,relatime - tmpfs none rw,seclabel

# AFTER fix (source = real K8s emptyDir, device 8:20):
1464 1399 8:20 /lib/kubelet/pods/.../xdg-sockets /tmp/pulse rw,relatime - xfs /dev/sdb4
```

**Root cause:** Any K8s volume mounted under `/tmp` in DinD will be shadowed by
DinD's `/tmp` tmpfs when Docker creates child container bind mounts. The overlayfs
and `emptyDir` are red herrings — the `/tmp` tmpfs is the real issue.

**Fix** — `examples/modules/wolf/components.cue`

Move `XDG_RUNTIME_DIR` and the `xdg-sockets` volume mount out of `/tmp` and into
`/run`, which is NOT mounted as tmpfs in DinD:

```cue
// Was: "/tmp/wolf-sockets"
XDG_RUNTIME_DIR: { name: "XDG_RUNTIME_DIR", value: "/run/wolf-sockets" }
PULSE_SERVER:    { name: "PULSE_SERVER",    value: "/run/wolf-sockets/pulse-socket" }

// xdg-sockets volume mount in both wolf container and dind sidecar:
"xdg-sockets": volumes["xdg-sockets"] & { mountPath: "/run/wolf-sockets" }
```

**Additional DinD volume mounts added in the same change:**

```cue
// wolf-api — DinD needs /run/wolf/wolf.sock to bind into Wolf-UI
"wolf-api": volumes["wolf-api"] & { mountPath: "/run/wolf" }

// udev — app containers inside DinD need the host udev database
udev: volumes.udev & { mountPath: "/run/udev" }
```

**Verified:** After redeployment, `pulse-socket` appears in the wolf K8s container's
`/run/wolf-sockets/` and PA container mountinfo shows `8:20 XFS` (the real emptyDir).
Wolf-UI now receives the Wayland socket via the same mechanism.

**Status** ✓ Resolved

---

## Issue 10 — `wayland-1` directory artifact blocks Wayland socket creation

**Symptom**  
Wolf-UI: `ERROR: Can't connect to a Wayland display.`

**Root cause** (related to Issue 9, now resolved)  
When DinD created the Wolf-UI container with
`-v /tmp/wolf-sockets/wayland-1:/tmp/wolf-sockets/wayland-1`, Docker created an
empty **directory** at the source path if it did not exist at container creation time.
This directory artifact persisted after the container exited. In subsequent sessions,
Wolf's Wayland compositor could not create a socket **file** named `wayland-1`
because a directory already occupied that path.

**Fix**  
Resolved as a side effect of the Issue 9 fix (moving to `/run/wolf-sockets`). With
the path now correctly shared, the Wayland socket file created by the wolf container
is visible to Wolf-UI via the real bind mount.

**Status** ✓ Resolved (side effect of Issue 9 fix)

---

## Issue 11 — `/dev/uinput` not present (virtual input devices unavailable)

**Symptom**

```
ERROR | Failed to create mouse: No such file or directory
ERROR | Failed to create keyboard: No such file or directory
Path '/dev/uinput' is not present.
Path '/dev/input/event*' is not present.
```

**Root cause**  
The `uinput` kernel module is not included in the base Talos kernel image for
v1.12.5 — it is not a loadable `.ko` file and not compiled in. Simply adding
`{name: "uinput"}` to `kernelModules` in `config.cue` results in:

```
error loading module "uinput": module not found
```

`uhid` is also unavailable (no Talos extension exists for it as of v1.12.5).

**Fix — Talos extension** (`config/envs/lnn1-mrspel/config.cue`)

Added `siderolabs/uinput` to the schematic extensions list. This extension provides
`uinput.ko` built against the specific Talos kernel:

```cue
extensions: [
    "siderolabs/amd-ucode",
    "siderolabs/amdgpu",
    "siderolabs/nvidia-container-toolkit-lts",
    "siderolabs/nvidia-open-gpu-kernel-modules-lts",
    "siderolabs/zfs",
    "siderolabs/uinput",   // ← added
]

kernelModules: [
    // ...existing nvidia/zfs entries...
    {name: "uinput"},      // ← load the module at boot
]
```

Applied via:

```bash
task baremetal:genconfig ENV=lnn1-mrspel   # computes new schematic ID with uinput
task baremetal:upgrade ENV=lnn1-mrspel     # upgrades node image + reboots
```

After reboot, `/dev/uinput` exists and the `uinput` module is live:

```
$ talosctl read /proc/modules | grep uinput
uinput 28672 0 - Live 0x0000000000000000
```

The "Failed to create mouse/keyboard" errors no longer appear in Wolf logs.

**Note on `uhid`**  
There is no `siderolabs/uhid` extension for Talos v1.12.5. DualSense HID emulation
via `/dev/uhid` is not currently available. Virtual gamepads can still be created
via `uinput`.

**Status** ✓ Resolved (uinput) / ✗ Not available (uhid)

---

## Issue 12 — OPM schema: `securityContext` missing from container and `privileged` not modelled

**Context** (umbrella for the schema changes made during this deployment)

Several OPM schema gaps were discovered and fixed:

| Gap | File | Fix |
|---|---|---|
| `#SecurityContextSchema` missing `privileged` field | `schemas/security.cue` | Added `privileged?: bool` |
| `#SecurityContextSchema` fields were required (no `?`) making it unusable for privileged workloads | `schemas/security.cue` | Made all fields optional |
| `#ContainerSchema` had no `securityContext` field | `schemas/workload.cue` | Added `securityContext?: #SecurityContextSchema` |
| `#ToK8sContainer` mapped no container-level security context | `container_helpers.cue` | Added full mapping: `privileged`, `runAsNonRoot/User/Group`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`, `capabilities` |
| `#HostNetworkTrait` not wired into StatefulSet transformer | `statefulset_transformer.cue` | Added trait and `hostNetwork` pod spec field |
| `#GpuResourceSchema` / `gpu?` field missing from `#ResourceRequirementsSchema` | `schemas/workload.cue`, `container_helpers.cue` | Added GPU extended resource support |

All changes published in catalog **v1.2.20**.

**Status** ✓ Resolved

---

## Issue 13 — DinD CreateContainerError: wrong hostPath for nvidia-container-runtime

**Symptom**

```
failed to generate container spec: failed to apply OCI options: failed to mkdir
"/usr/bin/nvidia-container-runtime": mkdir /usr/bin/nvidia-container-runtime: read-only file system
```

DinD container stuck in `CreateContainerError`.

**Root cause**
The `nvidia-container-runtime` volume hostPath was set to `/usr/bin/nvidia-container-runtime`.
On Talos, the `nvidia-container-toolkit-lts` extension installs the binary to
`/usr/local/bin/`, not `/usr/bin/`. Since the path didn't exist and `hostPathType: ""`
(no check), containerd tried to create the missing directory — but `/usr/bin/` is
read-only on Talos.

**Fix** — `modules/wolf/components.cue`
Changed `path: "/usr/bin/nvidia-container-runtime"` → `path: "/usr/local/bin/nvidia-container-runtime"`.

**Status** ✓ Resolved — module published as v0.0.19

---

## Issue 14 — Wolf SIGSEGV (exit code 11): cascading failure from DinD down

**Symptom**

```
Stack trace:
#3  pa_context_get_state at libpulse.so.0
#4  wolf::core::audio::queue_op at pulse.cpp:121
#5  PulseAudioRouterState::enable_pulse_subscribe at pulse_router.cpp:146
```

Wolf crashes with exit code 11 (SIGSEGV) immediately after printing all its INFO
startup messages.

**Root cause**
DinD wasn't running (blocked by Issue 13). Wolf tried to start PulseAudio via the
Docker API, failed (no socket), then called `pa_context_get_state` on a null/invalid
PulseAudio context → segfault. This is a Wolf bug (missing null check), but the
trigger is DinD not being available.

**Fix**
Fixing Issue 13 (DinD starts) resolves this automatically.

**Status** ✓ Resolved as side effect of Issue 13

---

## Issue 15 — nvidia-container-runtime as DinD default runtime fails for all containers

**Symptom**

```
[DOCKER] error 400 - {"message":"failed to create task for container: failed to create
shim task: OCI runtime create failed: unable to retrieve OCI runtime error ...:
/usr/local/bin/nvidia-container-runtime did not terminate successfully: exit status 1"}
```

DinD starts, Wolf starts, but when Wolf tries to launch the PulseAudio container via
DinD, it fails. Wolf then crashes with the same SIGSEGV (Issue 14) because PulseAudio
can't start.

**Root cause**
The DinD dockerd was configured with `--add-runtime nvidia=... --default-runtime nvidia`.
On Talos, the nvidia-container-runtime config file is at
`/usr/local/etc/nvidia-container-runtime/config.toml` (not `/etc/...`). Inside DinD,
`/usr/local/etc/` is not mounted, so the runtime can't find its config and exits with
status 1 for ALL containers — including PulseAudio which doesn't need GPU at all.

**Finding**
App containers (Steam, Firefox, etc.) get GPU device access via the GOW
`GOW_REQUIRED_DEVICES` bind-mount mechanism (DRI nodes, `/dev/input/*`) — they don't
need the nvidia-container-runtime for device access. The runtime was only needed for
CUDA library injection (NVENC), which has separate Talos-specific issues anyway.

**Fix** — `modules/wolf/components.cue`
Removed `--add-runtime` and `--default-runtime nvidia` from DinD args. DinD now uses
runc (the default) for all containers. The nvidia-container-runtime binary is still
bind-mounted into DinD via the `nvidia-container-runtime` volume for future use.

**Status** ✓ Resolved — module published as v0.0.20

---

## Issue 16 — NVIDIA driver volume: broken symlinks in Talos glibc extension

**Symptom**

```
[nvidia] Add gbm backend
cp: cannot stat '/usr/nvidia/lib/gbm/nvidia-drm_gbm.so': No such file or directory
```

Wolf's `30-nvidia.sh` init script fails when the nvidia-driver volume is mounted,
causing the container to exit with code 1.

**Root cause**
The Talos `nvidia-open-gpu-kernel-modules-lts` extension stores NVIDIA userspace
libraries at `/usr/local/glibc/usr/lib/`. When mounted at `/usr/nvidia` in the Wolf
container, the file `nvidia-drm_gbm.so` is a **symlink pointing to an absolute path
with `/rootfs/` prefix** (`/rootfs/usr/local/glibc/lib/libnvidia-allocator.so.1`).
This path is valid on the Talos host (which sees the system root at `/rootfs/`) but
does not exist inside the container.

Wolf's `30-nvidia.sh` calls `cp` on the GBM backend file, follows the symlink,
fails to stat the target, and exits non-zero.

**Additional context**
- `/usr/local/glibc/usr/lib/` contains ALL needed NVIDIA libs (libcuda.so.1,
  libnvidia-encode.so.1, etc.) but they have Talos-specific absolute symlinks
- hostPathType: "Directory" check also fails because the kubelet sees this path in a
  different mount namespace; `type: ""` bypasses the check
- The standard GOW nvidia-driver volume build (docker pull + docker volume create)
  works around this by creating real files (not symlinks)

**Fix** — `modules/wolf/init/nvidia-driver-setup-job.yaml`

Created a K8s Job that:
1. Mounts `/usr/local/glibc/usr` (Talos glibc extension) read-only at `/src`
2. Copies NVIDIA-specific libraries with `cp -L` (dereferences broken symlinks) to
   `/var/lib/wolf-nvidia-driver/lib/`
3. Creates the GBM backend symlink (`nvidia-drm_gbm.so` → `libnvidia-allocator.so.1`)
   since the Talos extension does not include `/lib/gbm/`
4. Generates Vulkan ICD, EGL vendor, and EGL external platform JSON configs
   (the Talos extension does not include these)

After running the Job and restarting Wolf, the `30-nvidia.sh` init script runs
`ldconfig` on `/usr/nvidia/lib/`, registers all 75 NVIDIA libraries, and sets up
GBM/EGL/Vulkan backends. Wolf detects NVENC hardware encoders:

```
INFO | Using h264 encoder: nvcodec
INFO | Using h265 encoder: nvcodec
INFO | Using av1 encoder: aom       ← RTX 3060 has no AV1 encode HW
INFO | Using zero copy pipeline on Nvidia (/dev/dri/renderD129)
```

Re-run the Job after any Talos NVIDIA extension upgrade (new driver version).

**Status** ✓ Resolved — driver 580.126.16, NVENC H.264/H.265 working

---

## Current state

| Capability | Status |
|---|---|
| Wolf starts and listens on all ports | [x] Working |
| NVIDIA RTX 3060 — DRI node renderD129 | [x] Working |
| DinD running, pulling app images | [x] Working |
| PulseAudio socket shared with wolf container | [x] Working |
| Wolf-UI Wayland socket shared with DinD containers | [x] Working |
| Virtual mouse / keyboard via uinput | [x] Working |
| Virtual gamepad via uhid (DualSense) | [ ] Not available — no Talos uhid extension |
| PVC storage (local-path) | [ ] Not provisioned (Issue 4) |
| NVIDIA NVENC hardware encoding (H.264 / H.265 via nvcodec) | [x] Working (Issue 16 resolved) — AV1 software-only (RTX 3060 limitation) |
| AMD Radeon 780M VAAPI encoding (H.264 / HEVC / AV1) | [ ] Disabled (switched to NVIDIA GPU path) |

---

## Open TODOs

1. **Test full streaming session** — connect Moonlight, launch Wolf UI or a game app;
   verify video and audio pipeline completes without error (NVENC + Wayland + audio).

3. **Provision Talos UserVolume for local-path (Issue 4)** — apply machine config
   to carve a partition on `nvme0n1`, then switch release storage to PVC.

4. **Investigate NVIDIA PCIe reboots (Issue 7)** — confirm `pcie_aspm=off` is
   active (`cat /sys/module/pcie_aspm/parameters/policy`), or consider blacklisting
   NVIDIA to eliminate it as a source of instability.

5. **`uhid` / DualSense support** — check if a future Talos version or community
   extension provides `uhid.ko`; alternatively investigate whether `uinput` alone
   is sufficient for gamepad emulation in Wolf's supported controller profiles.
