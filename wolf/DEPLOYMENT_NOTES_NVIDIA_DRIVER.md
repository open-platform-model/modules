# NVIDIA Driver Volume — Missing 32-bit Libraries and DISPLAY Issue

Documented during investigation of Steam grey screen on `lnn1-mrspel` (2026-04-08).
Prerequisite reading: DEPLOYMENT_NOTES.md Issue 16 (nvidia-driver-setup Job).

---

## Context

Wolf streams GPU-accelerated desktops to Moonlight clients. Each app (Steam, Firefox, etc.) runs in a Docker container inside DinD. These containers need NVIDIA userspace libraries to render graphics via OpenGL/Vulkan.

The NVIDIA driver volume is prepared by a K8s Job (`init/nvidia-driver-setup-job.yaml`) that copies 64-bit libraries from the Talos glibc extension at `/usr/local/glibc/usr/lib/` to a hostPath at `/var/lib/wolf-nvidia-driver/`. This volume is then bind-mounted at `/usr/nvidia` in the Wolf K8s pod and propagated into DinD child containers.

## Problem 1 — Steam bootstrap crashes: missing 32-bit NVIDIA libraries

**Symptom**

Steam launches inside its DinD container but the screen stays grey (only the Sway top bar is visible). The Steam process exits immediately after startup with:

```
glx: failed to create dri3 screen
failed to load driver: nouveau
basic_string::_M_create
```

**Root cause**

Steam's bootstrap client (`/home/retro/.steam/ubuntu12_32/steam`) is a **32-bit (i386) binary**. It links against 32-bit GLX/EGL libraries to render its updater and Big Picture UI. The nvidia-driver volume only contains **64-bit (x86_64)** libraries because the Talos glibc extension only ships x86_64 builds.

Without 32-bit `libGLX_nvidia.so.0`, `libEGL_nvidia.so.0`, `libcuda.so.1`, etc., the 32-bit Steam client cannot initialize OpenGL. Mesa's fallback tries the `nouveau` driver (which doesn't work without kernel module support), then gives up. Steam crashes during GL context creation.

**What works vs what doesn't**

| Component | Architecture | Status |
|---|---|---|
| Wolf NVENC encoding (cudaupload, nvh264enc) | 64-bit | Working |
| Wolf virtual compositor (waylanddisplaysrc) | 64-bit | Working |
| Sway compositor inside app containers | 64-bit | Working (uses EGL via 64-bit libEGL_nvidia) |
| Steam bootstrap/updater UI | 32-bit | Broken — no 32-bit NVIDIA libs |
| Steam game rendering (via Proton/Wine) | 32-bit + 64-bit | Broken — same cause |
| Gamescope (if used) | 64-bit | Unknown — not tested |

**Impact**

Any 32-bit application that needs OpenGL/Vulkan will fail. This primarily affects Steam (whose client is 32-bit) and Wine/Proton games (which use 32-bit Windows APIs mapped to 32-bit Linux GL/Vulkan).

## Problem 2 — DISPLAY environment variable not set for Steam

**Symptom**

Even when NVIDIA 64-bit EGL works (Sway starts, Waybar renders), Steam fails with:

```
src/steamexe/updateui_xwin.cpp (341) : Could not open connection to X
```

**Root cause**

Steam's bootstrap is an X11 application — it needs `DISPLAY=:0` to connect to XWayland. Sway starts XWayland (the socket at `/tmp/.X11-unix/X0` exists), but the `DISPLAY` env var is not propagated to the Steam process launched via `exec` in the Sway config.

Manually running Steam with `DISPLAY=:0` allows it to connect to XWayland and start (though it then crashes due to Problem 1).

**Fix**

Add `"DISPLAY=:0"` to the Steam app's `env` list in `releases/mr_spel/wolf/release.cue`:

```cue
env: [
    "PROTON_LOG=1",
    "RUN_SWAY=true",
    "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/renderD129",
    "GAMESCOPE_FLAGS=--expose-wayland -e",
    "DISPLAY=:0",  // XWayland display for Steam's 32-bit X11 bootstrap
]
```

This is a partial fix — Steam will connect to XWayland but still needs 32-bit NVIDIA libs to render.

## Options for fixing 32-bit NVIDIA libraries

### Option A — Build 32-bit libs from the GOW nvidia-driver Docker image

The standard Games on Whales approach. Build a Docker image that extracts both 32-bit and 64-bit NVIDIA libraries from an NVIDIA `.run` installer, then populate a Docker volume from it.

```bash
# Inside DinD (or on a machine with Docker):
NV_VERSION=$(cat /sys/module/nvidia/version)
curl -O "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_VERSION}/NVIDIA-Linux-x86_64-${NV_VERSION}.run"

# The .run installer contains both x86_64 and 32-bit compat libs.
# Extract and copy to a volume:
chmod +x NVIDIA-Linux-x86_64-${NV_VERSION}.run
./NVIDIA-Linux-x86_64-${NV_VERSION}.run --extract-only
mkdir -p /dst/lib /dst/lib32
cp -a NVIDIA-Linux-x86_64-${NV_VERSION}/*.so* /dst/lib/
cp -a NVIDIA-Linux-x86_64-${NV_VERSION}/32/*.so* /dst/lib32/
```

**Pros:** Complete solution; includes all NVIDIA libs for both architectures.
**Cons:** Requires downloading ~300 MB NVIDIA installer; must match the exact kernel module version (580.126.16); manual step outside of Talos.

### Option B — Extend the nvidia-driver-setup Job to extract 32-bit libs from the NVIDIA installer

Modify `init/nvidia-driver-setup-job.yaml` to download the NVIDIA `.run` installer matching the kernel module version, extract it, and copy both 64-bit and 32-bit libraries to the driver volume.

```yaml
# In the Job's container command, add:
NV_VERSION=$(cat /sys/module/nvidia/version)
wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_VERSION}/NVIDIA-Linux-x86_64-${NV_VERSION}.run"
chmod +x NVIDIA-Linux-x86_64-${NV_VERSION}.run
./NVIDIA-Linux-x86_64-${NV_VERSION}.run --extract-only -x /tmp/nv
cp -a /tmp/nv/32/*.so* /dst/lib32/
```

Then configure ldconfig to include `/usr/nvidia/lib32` in the 32-bit search path.

**Pros:** Automated via the existing K8s Job; re-runnable after upgrades.
**Cons:** Downloads ~300 MB on each run; needs a container image with wget and chmod (not busybox); fragile if NVIDIA changes the download URL structure.

### Option C — Use the GOW nvidia-driver Docker image via DinD

Run the GOW nvidia-driver build process inside DinD to create a properly populated Docker volume. This is the approach GOW documents.

```bash
# Run inside DinD:
NV_VERSION=$(cat /sys/module/nvidia/version)
docker build -t gow/nvidia-driver:latest \
  -f - --build-arg NV_VERSION=$NV_VERSION . <<'EOF'
FROM ubuntu:22.04
ARG NV_VERSION
RUN apt-get update && apt-get install -y wget \
    && wget -q "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NV_VERSION}/NVIDIA-Linux-x86_64-${NV_VERSION}.run" \
    && chmod +x NVIDIA-Linux-x86_64-${NV_VERSION}.run \
    && ./NVIDIA-Linux-x86_64-${NV_VERSION}.run --no-kernel-module --silent \
    && rm NVIDIA-Linux-x86_64-${NV_VERSION}.run
EOF

docker volume create nvidia-driver-vol
docker run --rm -v nvidia-driver-vol:/usr/nvidia gow/nvidia-driver:latest \
  sh -c 'cp -a /usr/lib/x86_64-linux-gnu/libnv* /usr/nvidia/lib/ && cp -a /usr/lib/i386-linux-gnu/libnv* /usr/nvidia/lib32/'
```

**Pros:** Uses the standard GOW approach; Docker volume is directly usable by Wolf.
**Cons:** Changes the driver volume from a K8s hostPath to a DinD Docker volume; requires reverting the `NVIDIA_DRIVER_VOLUME_NAME` change (back to `nvidia-driver-vol`); undoes the bind-mount fix from 2026-04-07.

### Option D — Hybrid: keep hostPath for 64-bit, add DinD Docker volume for 32-bit

Keep the current K8s hostPath driver volume (64-bit, built by the Job) for Wolf's NVENC encoding. Additionally, build a DinD Docker volume with 32-bit libs for app containers.

Set `NVIDIA_DRIVER_VOLUME_NAME` to the bind-mount path (`/usr/nvidia` — current) for 64-bit. Add `LD_LIBRARY_PATH` to include a 32-bit lib path.

**Pros:** Doesn't change what already works.
**Cons:** Two separate driver volumes to maintain; complex.

### Option E — Skip the 32-bit problem entirely with Gamescope

Gamescope is a 64-bit nested Wayland compositor that can wrap Steam. If Steam runs under Gamescope, the rendering is done by Gamescope (64-bit, using Vulkan) and Steam's own GL context is either not used or uses Gamescope's GL forwarding.

The GOW Steam image already includes Gamescope and the release.cue sets `GAMESCOPE_FLAGS=--expose-wayland -e`. But the current Sway config launches Steam directly (`exec /usr/games/steam -bigpicture`) rather than through Gamescope.

If the GOW launch scripts can be configured to run Steam through Gamescope, the 32-bit NVIDIA library problem may be avoided entirely.

**Pros:** No 32-bit libs needed; Gamescope handles rendering with 64-bit Vulkan.
**Cons:** Gamescope on NVIDIA in a container may have its own issues (DRM/KMS access, Vulkan initialization); needs testing; may not fully eliminate the 32-bit requirement (Steam's own UI code still uses 32-bit GL internally).

## Applied — Option B + DISPLAY env + sysctl + shm (2026-04-24)

`modules/wolf/init/nvidia-driver-setup-job.yaml` extended (image `alpine:3.19`,
`curl` + `zstd` + `xz` + `binutils`):

1. Detects kernel driver version from
   `/src/lib/libnvidia-glcore.so.<VERSION>` (matches kernel module exactly).
2. Builds an ordered candidate URL list:
   - `https://us.download.nvidia.com/tesla/${VER}/…` — **Talos LTS drivers
     live here**, not in the consumer `XFree86/Linux-x86_64/` archive. This
     was the key finding: `580.126.16`/`.20` return 404 from the consumer
     path but resolve from `tesla/`.
   - `https://us.download.nvidia.com/XFree86/Linux-x86_64/${VER}/…` —
     consumer fallback.
   - Same-minor neighbors from the XFree86 index, descending patch order —
     last-resort fallback. Neighbor versions usually fail NVIDIA's
     userspace↔kernel-module version check (Steam's NVML probe returns an
     error), so the tesla/ path is the reliable one for LTS nodes.
3. Extracts the `.run` into a 2 GiB `emptyDir`-backed `/tmp` (extract-only,
   zstd-compressed on newer installers).
4. Copies `/tmp/nv/extracted/32/*.so*` into `/dst/lib32/` with `cp -a`; then
   re-creates SONAME symlinks via `objdump -p` (the installer ships only
   versioned real files in `32/` — SONAME symlinks like `libGLX_nvidia.so.0
   → libGLX_nvidia.so.580.126.16` are normally created at install time).
5. Pins `/dst/.nvidia_version` (kernel module) AND `/dst/.nvidia_lib32_version`
   (upstream .run actually used). Guard only skips the download when both
   equal the current `NV_VERSION`, so a prior neighbor-version install
   auto-invalidates.
6. Purges stale `*.so*` from `/dst/lib32/` before each copy to prevent
   orphaned files from a previous version polluting ldconfig's SONAME
   resolution.

`releases/mr_spel/wolf/release.cue` Steam app changes:
- `env`: add `"DISPLAY=:0"` for the 32-bit X11 bootstrap.
- `base_create_json`: add `"ShmSize": 2147483648` (2 GiB) and remove
  `"IpcMode": "host"` so `ShmSize` takes effect (with host IPC mode the
  container shares DinD's 64 MB `/dev/shm` and `ShmSize` is ignored). This
  fixes the `Transport Error 0x3000` from steamwebhelper.

Talos machine config: add `machine.sysctls."user.max_user_namespaces": "15000"`
(see `infra/talos/patches/user-namespaces.yaml` in the larnet repo). Talos
ships with `0` which blocks Steam's pressure-vessel sandbox. Without this
the 32-bit libs never get exercised — Steam fails earlier with the
`basic_string::_M_create` error, which looks like a GL init crash but is
actually the sandbox's namespace probe bubbling up through libstdc++.

Library resolution relies on GOW's pre-existing
`/etc/ld.so.conf.d/nvidia.conf` (lists both `/usr/nvidia/lib` and
`/usr/nvidia/lib32`) and the `ldconfig` call in `30-nvidia.sh` — no
`LD_LIBRARY_PATH` override needed.

Option E (Gamescope) was not pursued; revisit if NVIDIA driver download
maintenance becomes a problem.

## Applied — Pod-level initContainer + Windows DLLs (2026-04-25)

The standalone `nvidia-driver-setup-job.yaml` is **superseded** by an
initContainer (`nvidia-driver-init`) inside the Wolf StatefulSet. It is
gated on `gpu.nvidia.driverInit.enabled` (default `true`). The Job stays
in-tree marked DEPRECATED for cluster-admin debug runs.

**What's the same as the Job:**

- 64-bit lib copy from the Talos glibc extension at
  `/usr/local/glibc/usr/lib` with `/rootfs/` symlink dereferencing.
- 32-bit lib download from `https://us.download.nvidia.com` with the
  ordered candidate list (tesla → XFree86 → same-minor fallbacks).
- Vulkan/EGL ICD JSON files written.
- Version pin files `.nvidia_version` + `.nvidia_lib32_version` for the
  fast-path skip on re-runs.

**What's new vs the Job:**

1. **Runs on every Wolf pod start**, not as a manual cluster-admin step.
   Eliminates the failure mode where a fresh node or driver upgrade
   leaves Wolf in a degraded state until someone applies the Job.
2. **Extracts Windows-side NGX DLLs** (`nvngx.dll`, `_nvngx.dll`,
   `nvngx_dlss.dll`, `nvngx_dlssg.dll`, `nvngx_dlssd.dll`) from the
   upstream `.run` into `/dst/wine/nvngx/` (visible at
   `/usr/nvidia/wine/nvngx/` inside Wolf containers). These are needed
   by NVIDIA's Streamline framework for DLSS / FrameGen under Proton.
   Without them, RE Engine titles (e.g. Pragmata, AppID 3357650) crash
   on startup with `EXCEPTION_ACCESS_VIOLATION (0xc0000005)` in their
   anti-tamper init code after Streamline fails to bootstrap NGX and
   unloads `sl.dlss*.dll`. See
   `modules/wolf/init/nvidia-driver-setup-job.yaml` (which does NOT
   extract these DLLs — that's why Pragmata required the
   `FrameGeneration=Off` workaround in `config.ini`).
3. **Third version-pin file `.nvidia_dlls_version`** so toggling
   `includeWindowsDLLs: false → true` mid-cycle correctly re-runs the
   download / extraction.
4. **`upstreamUrlBase` is parameterized** (default
   `https://us.download.nvidia.com`) for air-gapped clusters with a
   local mirror.

**Schema**

```cue
gpu.nvidia.driverInit?: {
    enabled:            bool   | *true
    image:              schemas.#Image | *{repository: "alpine", tag: "3.19"}
    glibcExtensionPath: string | *"/usr/local/glibc/usr"
    upstreamUrlBase:    string | *"https://us.download.nvidia.com"
    includeWindowsDLLs: bool   | *true
}
```

**Pod startup penalty**

First boot on a fresh node: ~30s–2 min for the ~300 MB `.run` download.
Subsequent restarts hit the version-pin fast path (sub-second).

**Verification after rollout**

```bash
# initContainer exited 0 cleanly
kubectl --context admin@lnn1-mrspel -n gaming logs wolf-wolf-0 -c nvidia-driver-init --tail=80

# Windows DLLs are present
kubectl --context admin@lnn1-mrspel -n gaming exec wolf-wolf-0 -c wolf -- \
    ls -la /usr/nvidia/wine/nvngx/ /usr/nvidia/.nvidia_dlls_version

# Pragmata DLSS smoke test:
#   1. Remove FrameGeneration=Off override from /home/retro/.steam/steam/steamapps/common/PRAGMATA/config.ini
#   2. Launch Pragmata via Moonlight, set in-game Frame Generation = FSR or DLSS
#   3. Game should render past the Streamline AV crash that previously
#      killed it ~12s after launch.
```

If the initContainer hangs in `Init:0/2`: check egress to
`download.nvidia.com` from the Wolf node, or override `upstreamUrlBase`.

## Related

- DEPLOYMENT_NOTES.md Issue 16 — original 64-bit Job
- DEPLOYMENT_NOTES.md Issue 17 — 32-bit extension + DISPLAY fix
- `modules/wolf/init/nvidia-driver-setup-job.yaml` — DEPRECATED Job (kept for admin debug)
- `modules/wolf/components.cue` — `nvidia-driver-init` initContainer + script
- `modules/wolf/module.cue` — `gpu.nvidia.driverInit` schema
- `releases/mr_spel/wolf/release.cue` — Steam app env configuration
