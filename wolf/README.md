# wolf

GPU game streaming server using [Wolf](https://games-on-whales.github.io/wolf/stable/) —
Moonlight-compatible, multi-user, Docker-in-Docker on Kubernetes.

## Overview

Wolf streams GPU-accelerated virtual desktops and games to [Moonlight](https://moonlight-stream.org/)
clients. Multiple users can connect simultaneously, each getting their own isolated session with
full virtual input (keyboard, mouse, gamepads) and audio.

```text
Moonlight clients
  │
  ▼
Wolf (LoadBalancer :47984 / :47989 / :48010 / :47999 / :48100 / :48200)
  │
  ├── User A: Steam session  → DinD container: ghcr.io/games-on-whales/steam:edge
  ├── User B: Firefox session → DinD container: ghcr.io/games-on-whales/firefox:edge
  └── User C: Wolf UI session → DinD container: ghcr.io/games-on-whales/wolf-ui:main
```

## Architecture

```text
Pod: wolf-0 (StatefulSet)
│
├── initContainer: config-seed
│     Writes /etc/wolf/cfg/config.toml on first start.
│     Wolf writes paired_clients back to this file — must be on the config PVC.
│
├── sidecar: dind  (docker:dind, privileged)
│     Docker-in-Docker daemon. Wolf calls the Docker API here to spawn
│     per-session app containers on demand.
│     Shares the config PVC so app container bind mounts resolve correctly.
│     Listens on: /run/dind/docker.sock  (shared emptyDir with wolf)
│
└── main: wolf  (ghcr.io/games-on-whales/wolf:stable)
      Moonlight streaming server. Talks to DinD. GPU-encodes video via GStreamer.
      Manages virtual input (uinput/uhid) and PulseAudio sessions per user.

Volumes:
  wolf-config   PVC/hostPath/NFS  /etc/wolf         wolf + dind
  docker-data   PVC/emptyDir      /var/lib/docker   dind
  docker-socket emptyDir          /run/dind          wolf + dind  ← docker.sock
  wolf-api      emptyDir          /run/wolf          wolf         ← wolf.sock
  xdg-sockets   emptyDir          /tmp/wolf-sockets  wolf + dind  ← PulseAudio/Wayland
  dev           hostPath /dev     /dev               wolf + dind
  udev          hostPath /run/udev /run/udev         wolf
  nvidia-driver hostPath (nvidia) /usr/nvidia        wolf
```

## Quick start

### 1. Prepare the host

#### udev rules (virtual input devices)

Wolf creates virtual gamepads, mice, and keyboards using `uinput` and `uhid`.
Install these udev rules on every node where Wolf may run:

```bash
cat > /etc/udev/rules.d/85-wolf-virtual-inputs.rules << 'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad",   MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad",         MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad",    MODE="0660", ENV{ID_SEAT}="seat9"
EOF
udevadm control --reload-rules && udevadm trigger
```

#### uhid kernel module

```bash
echo 'uhid' | tee /etc/modules-load.d/uhid.conf
# Then reboot or: modprobe uhid
```

### 2. NVIDIA GPU (skip for Intel/AMD)

Build the NVIDIA driver image and populate the driver hostPath once per host.
Re-run this whenever you update the NVIDIA drivers.

```bash
# Build the driver image (requires docker on the host)
curl https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile \
  | docker build -t gow/nvidia-driver:latest -f - \
      --build-arg NV_VERSION=$(cat /sys/module/nvidia/version) .

# Populate the driver volume (creates /var/lib/docker/volumes/nvidia-driver-vol/_data)
docker volume rm -f nvidia-driver-vol
docker create --rm \
  --mount source=nvidia-driver-vol,destination=/usr/nvidia \
  gow/nvidia-driver:latest sh

# Verify
ls /var/lib/docker/volumes/nvidia-driver-vol/_data/lib
```

Confirm nvidia-drm is loaded with modeset=1:

```bash
cat /sys/module/nvidia_drm/parameters/modeset
# Should print: Y
# If not, add nvidia-drm.modeset=1 to GRUB_CMDLINE_LINUX_DEFAULT and reboot
```

### 3. Cluster security requirements

Wolf requires elevated privileges:

| Requirement | Container | Why |
|---|---|---|
| `privileged: true` | dind | Docker-in-Docker requires full kernel access |
| `capabilities: [NET_RAW, MKNOD, NET_ADMIN, SYS_ADMIN, SYS_NICE]` | wolf | Virtual input devices, network namespaces, GPU scheduling |
| `deviceCgroupRules: ["c 13:* rmw"]` | wolf | Character device access for /dev/input/* |
| `hostNetwork: true` (recommended) | pod | Avoid NAT overhead on UDP streams |

These must be permitted by your cluster's PodSecurityAdmission policy. Apply via
the K8s provider `ModuleRelease` annotations or a privileged namespace.

### 4. Deploy

```cue
package main

import (
    m    "opmodel.dev/core/v1alpha1/modulerelease@v1"
    wolf "example.com/modules/wolf@v0.1.0"
)

m.#ModuleRelease

metadata: {
    name:      "wolf"
    namespace: "gaming"
}

#module: wolf

values: {
    wolf: {
        hostname: "my-wolf-server"
    }

    gpu: {
        type:       "intelamd"      // or "nvidia"
        renderNode: "/dev/dri/renderD128"
    }

    networking: serviceType: "LoadBalancer"

    storage: config: {
        type:         "pvc"
        size:         "50Gi"
        storageClass: "local-path"
    }
}
```

## Configuration

### Top-level

| Field | Default | Description |
|---|---|---|
| `image.tag` | `"stable"` | Wolf container image tag |
| `wolf.hostname` | `"wolf"` | Name shown in Moonlight's host list |
| `wolf.supportHevc` | `true` | Enable HEVC video encoding |
| `wolf.logLevel` | `"INFO"` | Log verbosity (`ERROR` / `WARNING` / `INFO` / `DEBUG` / `TRACE`) |
| `wolf.stopContainerOnExit` | `true` | Remove app containers when session ends |
| `wolf.gstDebug` | — | GStreamer debug level (very verbose; for encoding troubleshooting) |
| `gpu.type` | `"intelamd"` | GPU vendor (`"intelamd"` or `"nvidia"`) |
| `gpu.renderNode` | `"/dev/dri/renderD128"` | DRI render node path |
| `gpu.nvidia.driverPath` | `"/var/lib/docker/volumes/nvidia-driver-vol/_data"` | NVIDIA driver hostPath |
| `networking.serviceType` | `"LoadBalancer"` | Kubernetes Service type |
| `networking.{https,http,control,rtsp,video,audio}Port` | Wolf defaults | Override streaming ports |
| `dind.storage.type` | `"pvc"` | Docker image layer cache (`"pvc"` or `"emptyDir"`) |
| `dind.storage.size` | `"50Gi"` | PVC size for Docker layer cache |
| `storage.config.type` | `"pvc"` | Wolf state storage type |
| `storage.config.size` | `"20Gi"` | PVC size for Wolf config + app state |
| `api.enabled` | `false` | Enable nginx TCP proxy for Wolf REST API |
| `api.port` | `8080` | TCP port for the API proxy |

### Multiple GPUs

Find which render node maps to which GPU:

```bash
ls -l /sys/class/drm/renderD*/device/driver
# /sys/class/drm/renderD128/device/driver -> .../drivers/i915    (Intel)
# /sys/class/drm/renderD129/device/driver -> .../drivers/nvidia  (NVIDIA)
```

Set `gpu.renderNode` to the correct node for your streaming GPU.

### Storage sizing guide

| Use case | `storage.config.size` | `dind.storage.size` |
|---|---|---|
| Wolf UI + Firefox only | `5Gi` | `5Gi` |
| Steam (1 user) | `20Gi` | `30Gi` |
| Steam (3–5 users) | `50Gi` | `50Gi` |
| Steam + multiple games | `100Gi` | `100Gi` |

## Pairing Moonlight

1. Deploy the module and wait for `wolf-0` to be `Running`.
2. Open Moonlight and add the node IP (or LoadBalancer IP) as a host.
3. Moonlight will show a PIN dialog.
4. Check the Wolf logs for a URL like `http://<node-ip>:47989/pin/#XXXXXXXX`.
   Open that URL in a browser (replace `localhost` with the actual node IP).
5. Enter the Moonlight PIN on the Wolf pairing page.
6. Moonlight will now show the Wolf UI application — launch it to access the app browser.

```bash
# Watch Wolf logs for the pairing URL
kubectl logs -f wolf-0 -n gaming -c wolf
```

## Ports reference

| Port | Protocol | Purpose |
|---|---|---|
| 47984 | TCP | HTTPS — Moonlight pairing |
| 47989 | TCP | HTTP  — Moonlight pairing |
| 48010 | TCP | RTSP  — Stream setup |
| 47999 | UDP | Control — Input and control channel |
| 48100 | UDP | Video  — Encoded video (H.264 / HEVC / AV1) |
| 48200 | UDP | Audio  — Opus audio stream |

## App images

Wolf uses the [Games on Whales (GOW)](https://github.com/games-on-whales/gow) app images.
Apps are configured in `/etc/wolf/cfg/config.toml` (on the config PVC). The default
installation includes Wolf UI, which lets users browse and download available apps.

Apps are defined as TOML profiles in `config.toml`. Example for Steam:

```toml
[[profiles]]
id = "user"
name = "User"

    [[profiles.apps]]
    title = "Steam"
    start_virtual_compositor = true

        [profiles.apps.runner]
        type = "docker"
        name = "WolfSteam"
        image = "ghcr.io/games-on-whales/steam:edge"
        mounts = []
        env = [
            "RUN_SWAY=true",
            "GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*",
        ]
        devices = []
        ports = []
        base_create_json = """
        {
          "HostConfig": {
            "IpcMode": "host",
            "Privileged": false,
            "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN"],
            "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw"]
          }
        }
        """
```

Edit the config on the PVC directly:

```bash
kubectl exec -it wolf-0 -n gaming -c wolf -- vi /etc/wolf/cfg/config.toml
# Then restart Wolf to reload:
kubectl rollout restart statefulset/wolf -n gaming
```

## Wolf UI

Wolf UI is a Moonlight app (launched from the Moonlight app list after pairing) that provides:
- Profile selection and management
- App browser (browse, download, launch streaming apps)
- Cooperative lobby creation (multiple users on the same session)
- Return to Wolf UI: `Ctrl+Alt+Shift+W` (keyboard) or `Start+Up+RB` (gamepad)

## Kubernetes resources produced

```text
StatefulSet/wolf
Service/wolf              (LoadBalancer — streaming ports)
PersistentVolumeClaim/wolf-wolf-config   (Wolf config and app state)
PersistentVolumeClaim/wolf-docker-data   (DinD Docker layer cache)
```

## Known limitations

### OPM schema gaps

The current OPM `#SecurityContextSchema` does not model:
- Container-level `privileged: true` (required for DinD)
- `deviceCgroupRules` (required for Wolf virtual input device creation)
- Pod-level `hostNetwork: true` (recommended for streaming latency)

These must be applied via K8s provider-level annotations or a mutating webhook until
the OPM schema and Kubernetes transformer are extended to support these fields.

### NVIDIA on Talos / no Docker host

This module uses Docker-in-Docker (DinD) to avoid needing the host Docker socket.
The NVIDIA driver volume must be prepared as a `hostPath` directory on the node.
On Talos Linux, where Docker is not available, an alternative approach is needed
(e.g., a DaemonSet that extracts driver files, or a pre-provisioned PV).

### AV1 encoding

Some GPUs (AMD 7900 XTX, Intel N150) have known issues with AV1 encoding.
Disable AV1 in `config.toml` by commenting out `[[gstreamer.video.av1_encoders]]`
if you experience stuck 30 FPS or encoding errors.
