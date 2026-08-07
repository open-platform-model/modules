# FileFlows — Media Processing Server

**Complexity:** Intermediate
**Workload Types:** `stateful` (StatefulSet)
**Module path:** `opmodel.dev/modules/fileflows@v1`

FileFlows is a .NET file-processing automation server. Libraries are scanned, matched
files are pushed through user-authored *flows*, and the heavy step is almost always an
FFmpeg transcode. This module deploys the **server** (which contains its own internal
processing node) as a single stateful component.

Its reason for existing beyond "another media app" is the GPU shape: it is the first
module to claim **two GPUs from two different vendors in one container**, so a flow can
choose NVENC or QSV per job.

## Requirements

| | |
|---|---|
| `opmodel.dev/catalogs/opm` | **`>= v1.0.0-alpha.8`** — first version with `resources.gpus` |
| `opmodel.dev/core` | `>= v1.1.0-alpha.1` |

## Three things that will cost you an afternoon

### 1. The `modded` image prefix is mandatory on Kubernetes

The plain `stable` / `latest` images **ship without FFmpeg**. They fetch it at runtime
through DockerMods, which talk to a Docker daemon over the `/var/run/docker.sock` bind
mount you see in every upstream compose example. Under containerd there is no Docker
daemon, so that path cannot work at all.

The failure is late and misleading: the server starts, the web UI loads, libraries scan
happily, and only the first flow reaching an FFmpeg node fails. Upstream frames
`modded-*` as a workaround for hosts with no internet; here it is the only correct tag.

The default is `modded-26.07` — a dated pin, so an upgrade is a deliberate edit rather
than whatever `modded-stable` moved to overnight.

### 2. NVIDIA needs a RuntimeClass *and* a driver capability

Two separate settings, each with its own silent failure:

- **`runtimeClass: "nvidia"`** — without it the pod starts, `nvidia-smi` is simply
  absent, and every NVENC flow fails while QSV keeps working. Intel does not need this;
  its devices arrive as plain device nodes under the default runtime.
- **`NVIDIA_DRIVER_CAPABILITIES`** — the module emits this automatically whenever
  `runtimeClass` is set, defaulting to `compute,video,utility`. `video` is the one that
  matters: the NVIDIA runtime grants only `utility` when the variable is unset, which is
  enough for `nvidia-smi` to run and report the card **while every NVENC encoder stays
  invisible to FFmpeg**. GPU clearly present, hardware encoding "unsupported" — the
  classic dead end.

The module deliberately does **not** set `NVIDIA_VISIBLE_DEVICES`, though every upstream
Docker example does. Under Kubernetes the device plugin owns that variable and writes the
UUID of the GPU it allocated. Setting it in the pod spec overrides that allocation and
hands the container every GPU on the node, quietly defeating the scheduler's accounting.

### 3. You can inject your own FFmpeg instead of trusting the image's

Neither FileFlows image is a good bet for GPU work: the plain tags ship no FFmpeg at all,
and the `modded-*` tags ship one whose encoder support upstream never states. Rather than
hope, hand the container a binary whose hardware support is known:

```yaml
ffmpegInjection: {}          # defaults are the whole feature
```

An init container copies a self-contained FFmpeg tree out of a donor image into a shared
`emptyDir`, which the app container mounts at the donor's original path. The default donor
is `linuxserver/jellyfin` — `jellyfin-ffmpeg` is built precisely for mixed
NVENC/QSV/VAAPI transcoding and ships `ffmpeg`, `ffprobe`, `vainfo` and its own `lib/`
including the bundled libva drivers.

This works because FileFlows resolves its encoder through an editable **`FFmpeg`
variable** — the same indirection that lets a processing node point at a different install
path, and which upstream documents as the way to "work around limitations in specific
builds".

⚠ **Half the change is in the UI.** The module makes the binary available; it cannot make
FileFlows use it. Set **Settings → Variables → `FFmpeg`** to `<path>/ffmpeg`. Until then
the injected tree is mounted and silently ignored while the image's own FFmpeg is used —
which looks exactly like the injection not working.

The mount path is deliberately the same as the donor's own (`/usr/lib/jellyfin-ffmpeg`).
jellyfin-ffmpeg locates its bundled VA-API drivers relative to its install location, so
relocating it costs QSV and VAAPI unless `LIBVA_DRIVERS_PATH` is also set. Keeping the
path removes that coupling rather than documenting it.

### 4. `temp` must be sized for a whole file

FileFlows writes the full working copy to `/temp` before moving the result into place, so
a 60 GB remux needs 60 GB of temp. Left as the default `emptyDir` on the node's ephemeral
partition, one large job can fill it and trigger kubelet eviction of **unrelated pods on
the same node** — the damage is not contained to FileFlows. Point it at a PVC or an NFS
dataset on bulk storage.

## Quick start

```yaml
apiVersion: opmodel.dev/v1alpha1
kind: ModuleInstance
metadata:
  name: fileflows
  namespace: fileflows
spec:
  module:
    path: opmodel.dev/modules/fileflows@v1
    version: v1.0.0
  values:
    puid: 3005
    pgid: 3005
    runtimeClass: nvidia          # required for NVENC; omit on Intel-only clusters
    resources:
      requests: {cpu: "1000m", memory: 2Gi}
      limits:   {cpu: "8000m", memory: 8Gi}
      gpus:
        nvidia: {resource: nvidia.com/gpu,     count: 1}
        intel:  {resource: gpu.intel.com/i915, count: 1}
    storage:
      data: {mountPath: /app/Data, type: pvc, size: 10Gi, storageClass: my-class}
      temp: {mountPath: /temp, type: nfs, server: 10.0.0.2, path: /mnt/bulk/ff-temp}
      media:
        movies: {mountPath: /media/movies, type: nfs, server: 10.0.0.2, path: /mnt/bulk/movies}
  prune: true
```

## Configuration reference

| Field | Default | Notes |
|---|---|---|
| `image.repository` | `revenz/fileflows` | |
| `image.tag` | `modded-26.07` | `modded-*` is mandatory — see above |
| `port` | `5000` | Service port. Container always listens on 5000 |
| `puid` / `pgid` | `1000` | Process identity |
| `timezone` | `Europe/Stockholm` | |
| `storage.data` | PVC `10Gi` at `/app/Data` | Config + flows + SQLite. `/app/Data`, **not** the docs' `/data` |
| `storage.logs` | *(unset)* | Optional; logs are read through the UI anyway |
| `storage.temp` | *(unset)* | Strongly recommended — see above |
| `storage.media` | *(unset)* | Map of library mounts |
| `serviceType` | `ClusterIP` | |
| `httpRoute` | *(unset)* | Gateway API HTTPRoute |
| `resources` | *(unset)* | Includes `gpu` (single) and `gpus` (multi) |
| `ffmpegInjection` | *(unset)* | `{}` enables it; see above. Requires the UI variable too |
| `ffmpegInjection.image` | `linuxserver/jellyfin:10.11.11ubu2604-ls43` | Donor. Pinned — it is a toolchain, not an app |
| `ffmpegInjection.path` | `/usr/lib/jellyfin-ffmpeg` | Same path in donor and app container, on purpose |
| `runtimeClass` | *(unset)* | Set to `nvidia` for NVENC |
| `nvidiaDriverCapabilities` | `compute,video,utility` | Emitted only with `runtimeClass` |
| `renderGroups` | `[44, 109]` | video/render GIDs; applied only when a GPU is claimed |
| `startupFailureThreshold` | `30` | 5 min of grace for first-run DB creation |
| `livenessFailureThreshold` | `6` | |
| `readinessFailureThreshold` | `3` | |
| `terminationGracePeriodSeconds` | `300` | The unit of work is a transcode, not a request |
| `podScheduling` / `podMetadata` | *(unset)* | Passed through to the catalog schemas |

### Probes are TCP, not HTTP

All three probe the listener on 5000. FileFlows publishes no documented health endpoint,
and probing the SPA root would assert far more than liveness needs while risking a false
restart on any UI-route change across an image bump.

### Ownership and `root_squash`

The `fix-permissions` init container chowns `data`, and `temp` **only when it is not
NFS**. That exclusion is deliberate: an NFS export with `root_squash` maps root to
`nobody`, so a chown from the root init container fails and takes the pod down before
FileFlows ever starts. NFS mounts must already carry the right owner server-side. Media
mounts are never chowned — both for that reason and because recursively chowning a media
library is not a module's business.

### `readOnly` on media

Leave it `false` for anything FileFlows processes. Unlike a media *server*, which only
reads, FileFlows exists to rewrite files in place — a read-only library will fail every
in-place flow at the final move.

## Not modelled: external processing nodes

FileFlows supports external *processing nodes* — extra containers that register with the
server and run flows on its behalf. This module covers the **server only**.

Nodes exist to spread work across **machines**. On a single-node cluster a second pod on
the same host adds scheduling and path-mapping surface while contending for the same CPU,
disk and GPUs, so it buys nothing. Adding them later is a `nodes: [Name=string]: {...}`
map plus `FFNODE=1` / `ServerUrl` / `NodeName` on the extra pods — the server does not
change shape, so nothing here has to be undone to get there.

That said, a node split is the natural answer to *one GPU per worker* if you ever want
flows pinned to a specific card rather than choosing per job.
