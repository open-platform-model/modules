# FileFlows — Media Processing Server

**Complexity:** Intermediate
**Workload Types:** `stateful` (StatefulSet) + `stateless` (Deployment, one per processing node)
**Module path:** `opmodel.dev/modules/fileflows@v2`

FileFlows is a .NET file-processing automation server. Libraries are scanned, matched
files are pushed through user-authored *flows*, and the heavy step is almost always an
FFmpeg transcode.

This module deploys the **server** (which contains its own internal processing node) as a
stateful component, and optionally a set of **external processing nodes** — one stateless
worker per `#config.nodes` entry, each typically owning a single GPU. See
[External processing nodes](#external-processing-nodes--one-card-per-worker).

## Requirements

| | |
|---|---|
| `opmodel.dev/catalogs/opm@v2` | `v2.0.0-alpha.2` |
| `opmodel.dev/core@v2` | `v2.0.0-alpha.4` |

## Hardware transcoding — one or more cards

Cards are keyed by vendor. Adding one is a single line:

```yaml
hardwareAcceleration:
  devices:
    nvidia: {}      # → nvidia.com/gpu: 1
    intel:  {}      # → gpu.intel.com/i915: 1
```

Everything each vendor needs is derived from the key alone:

| `devices` | claims | `runtimeClassName` | `NVIDIA_DRIVER_CAPABILITIES` | `supplementalGroups` |
|---|---|---|---|---|
| `{nvidia, intel}` | both | `nvidia` | `compute,video,utility` | `[44, 109]` |
| `{nvidia}` | `nvidia.com/gpu: 1` | `nvidia` | `compute,video,utility` | `[44, 109]` |
| `{intel}` | `gpu.intel.com/i915: 1` | *absent* | *absent* | `[44, 109]` |
| *(no block)* | *absent* | *absent* | *absent* | *absent* |

Per-card overrides live inline, so there is no parallel map to keep in sync:

```yaml
devices:
  intel:  {resource: gpu.intel.com/xe, count: 2}   # Battlemage+ binds xe, not i915
  nvidia: {count: 3}
```

**Why derived rather than assembled by hand.** Every wrong assembly is *silent*: an
`nvidia.com/gpu` claim without a RuntimeClass is a healthy-looking pod with **no NVENC at
all**, and nothing in the module could catch it. Deriving the RuntimeClass and driver
capabilities from the vendor key makes that unrepresentable.

**Why this differs from `modules/jellyfin` v2.5.0**, which takes a scalar `vendor`. Not
inconsistency — Jellyfin's `HardwareAccelerationType` is a single global setting, so it
genuinely uses one card at a time. FileFlows picks its encoder **per flow**, so every
attached card can be busy simultaneously, and capping it at one would cap throughput for
no reason.

⚠ **A GPU is consumed cluster-wide.** Each card claimed here is unavailable to every
other workload for as long as the pod exists, and Kubernetes does **not** preempt for
extended resources — a second claimant just sits `Pending` forever. Taking a card another
instance holds means removing it there *in the same change*.

Setting both `hardwareAcceleration` and a conflicting `resources.gpu` fails the build
rather than silently picking one. An unknown vendor key also fails the build, though the
message points at a missing `count` field rather than naming the bad key.

## Getting maximum throughput

Neither card on a typical build imposes a driver-level concurrency cap, so the ceiling is
runner count and silicon — not licensing:

- **Quadro P2200 — unrestricted NVENC sessions.** Quadro ≥ x2000 (and Tesla/GRID) carry
  no session limit, unlike GeForce, which fails the third `NvEncOpenEncodeSessionEx` with
  `OUT_OF_MEMORY`. Pascal 6th-gen NVENC: H.264 + HEVC 8-bit, **no AV1 encode**.
- **Arc A310 — two media engines**, AV1/HEVC/H.264 encode up to 8K 10-bit, and no
  documented session cap. Materially better quality-per-bitrate than Pascal, and the only
  one of the two that can produce AV1.

So the knobs that actually matter, in order:

1. **Runners** (Settings → Nodes → the node → Runners) — how many files process at once.
   FileFlows costs runners *by resolution*, so a 4K file consumes more than an SD one.
   This is UI state, not module config. Start at 2 and raise while watching encode time.
2. **`resources.limits.cpu` / `memory`** — filters, muxing and I/O stay on the CPU even
   with hardware encode. Under-provisioning here starves the GPUs.
3. **`temp` throughput** — a full working copy is written per job, so concurrent jobs
   multiply the I/O. This is the usual bottleneck once both GPUs are fed.

Flows choose their encoder, so **which card gets used is a flow-authoring decision**, not
something the module schedules. If you want work pinned deterministically per card,
that is what external processing nodes are for — see below.

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
    path: opmodel.dev/modules/fileflows@v2
    version: v2.0.0
  values:
    puid: 3005
    pgid: 3005
    hardwareAcceleration:
      devices:
        nvidia: {}
        intel: {}
    ffmpegInjection: {}
    resources:
      requests: {cpu: "1000m", memory: 2Gi}
      limits:   {cpu: "8000m", memory: 8Gi}
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
| `resources` | *(unset)* | CPU/memory. Legacy `resources.gpu` still works |
| `ffmpegInjection` | *(unset)* | `{}` enables it; see above. Requires the UI variable too |
| `ffmpegInjection.image` | `linuxserver/jellyfin:10.11.11ubu2604-ls43` | Donor. Pinned — it is a toolchain, not an app |
| `ffmpegInjection.path` | `/usr/lib/jellyfin-ffmpeg` | Same path in donor and app container, on purpose |
| `hardwareAcceleration` | *(unset)* | See the table above |
| `hardwareAcceleration.devices` | *(required in block)* | Map keyed by `intel` \| `nvidia`; one entry per card |
| `…devices.<vendor>.count` | `1` | Raise only on a node with several of the same model |
| `…devices.<vendor>.resource` | per vendor | Override only if the plugin advertises another name (`xe` on Battlemage+) |
| `hardwareAcceleration.runtimeClass` | `nvidia` | NVIDIA only; ignored for Intel |
| `hardwareAcceleration.driverCapabilities` | `compute,video,utility` | NVIDIA only |
| `hardwareAcceleration.renderGroups` | `[44, 109]` | video/render GIDs |
| `startupFailureThreshold` | `30` | 5 min of grace for first-run DB creation |
| `livenessFailureThreshold` | `6` | |
| `readinessFailureThreshold` | `3` | |
| `terminationGracePeriodSeconds` | `300` | The unit of work is a transcode, not a request |
| `podScheduling` / `podMetadata` | *(unset)* | Passed through to the catalog schemas |
| `accessToken` | *(unset)* | Required once `nodes` is non-empty. Must match Settings → Security |
| `serverUrl` | derived from the instance | Override the URL nodes dial; almost never needed |
| `nodes` | `{}` | External processing nodes — see below |
| `nodes.<key>.enabled` | `true` | `false` parks the pod and **releases its GPU** |
| `nodes.<key>.nodeName` | the map key | Must be stable — churn leaves orphan node records |
| `nodes.<key>.runners` | *(unset, UI-owned)* | `NodeRunnerCount`. A cost budget, not a file count |
| `nodes.<key>.temp` | *(required)* | Its own dataset. Never shared between nodes |
| `nodes.<key>.hardwareAcceleration` | *(unset)* | One entry; same shape as the server's |
| `nodes.<key>.resources` | *(unset)* | Per-card CPU/memory |

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

## External processing nodes — one card per worker

`#config.nodes` renders one headless worker Deployment per entry. Each registers with the
server and runs flows on its behalf.

Nodes were built to spread work across **machines**, which is why this module declined to
model them while there was only one host. The reason they earn their keep on a *single*
host is different and specific:

- **FileFlows' runner budget is a property of a node.** One card per node pod is the only
  way to express "N concurrent jobs on *this* card".
- **A pod is allocated its GPUs by the device plugin.** A pod holding exactly one card has
  only one encoder for `Encoder: Automatic` to resolve to — so per-card encoder selection
  needs no in-flow logic at all. On a server holding several cards, `Automatic` walks a
  fixed vendor priority list, stops at the first encoder that probes clean, and every other
  card idles no matter how many runners are active.

```cue
// #Secret literal branch: OPM creates the Secret itself. Alternatively supply
// `secretName:` + `remoteKey:` to reference a pre-existing K8s Secret.
accessToken: {value: "..."}          // required whenever nodes exist — see below

nodes: {
    p2200: {
        runners: 2
        hardwareAcceleration: devices: nvidia: {}
        temp: {mountPath: "/temp", type: "nfs", server: "10.0.0.2", path: "/mnt/ff-nvidia"}
    }
    "arc-1": {
        runners: 2
        hardwareAcceleration: devices: intel: {}
        temp: {mountPath: "/temp", type: "nfs", server: "10.0.0.2", path: "/mnt/ff-arc1"}
    }
}
```

Renders `{instance}-node-p2200` and `{instance}-node-arc-1` as Deployments, plus a Secret
holding the access token. Nodes get **no Service and no HTTPRoute** — `FileFlows.Node.dll`
has no HTTP listener; it dials the server and holds a SignalR connection. For the same
reason they carry no probes: the entrypoint's `wait $dotnet_pid` makes container exit track
process exit, so `restartPolicy` is the whole health story.

Their update strategy is `Recreate`, not `RollingUpdate`, and that is not a style choice —
a rolling update starts the replacement pod while the outgoing one still holds its GPU, and
because Kubernetes does not preempt extended resources the new pod waits forever for a card
the old pod will not release until the new one is Ready.

### Per-node vs inherited

| field | per-node? | why |
|---|---|---|
| `hardwareAcceleration` | **yes** | the entire point |
| `runners` | **yes** | `NodeRunnerCount`, the per-card concurrency knob |
| `temp` | **yes, required** | see the shared-temp warning below |
| `resources`, `podScheduling`, `podMetadata` | **yes** | different cards want different CPU budgets and hosts |
| `terminationGracePeriodSeconds` | optional, else the server's | one knob, two scopes |
| `image` | inherited, **no override** | version lockstep is enforced by the node's own auto-updater, which downloads into `/app/NodeUpdate` — a container layer discarded on restart. A divergent tag is a permanent update loop, not an upgrade. |
| `puid` / `pgid` / `timezone` | inherited, no override | a node writing library files as a different owner breaks the server |
| `ffmpegInjection` | inherited, always applied | the `FFmpeg` variable is one server-wide string, so the tree must sit at the same path on every pod |
| `storage.media` | inherited verbatim | identical mount paths on every pod is exactly what makes FileFlows' `NodeMappings` unnecessary |
| `storage.data` / `storage.logs` | **not mounted** | the server's RWO volumes; `data` holds the SQLite database and two writers would fight |

Inheritance is *set it or inherit it*, never a partial merge.

### `accessToken` is required once any node exists

Each node sends it as an `x-token` header to register. It is **optional** on an instance
with no nodes and mandatory as soon as one appears — enforced by an unconditional reference
in the node container, so a missing token fails the build naming the field rather than
producing a Running pod the server never sees.

⚠ **The module cannot set the server side.** `FileFlows.Server.dll` reads no environment
variable for this (only `FF_EULA_ACCEPTED`), so the value lives in the server's database and
this field hands a *copy* to the nodes. The two must agree and nothing here can check that —
a wrong value is a silent `Failed to register node` in the node's log.

### `runners` is a unit budget, not a file count

In 26.07 active files consume the budget according to their assigned cost
(audio/SD/720p/1080p/4K), so `2` is not necessarily two files. Start low and measure.

Setting it also **hands ownership to the module**: FileFlows hides env-provided settings in
the Web Console rather than let the UI overwrite them. Leave `runners` unset to keep the UI
in charge.

### Three things that will bite

**Never point two nodes at one temp directory.** Each node sweeps its own temp on a schedule
and skips only the `Runner-<uid>` directories *it* knows are executing — it has no
visibility into another node's runners. A shared temp lets one node delete another's
in-flight working copy mid-encode. Give every node its own dataset.

**Moving a card to a node means taking it from the server in the same change.** Kubernetes
does not preempt extended resources, so a node claiming a card the server still holds sits
`Pending` forever with no self-correction. Clear `#config.hardwareAcceleration` in the same
apply that adds the node.

**One physical card per pod is the device plugin's business, not this field's.** With the
Intel plugin's `sharedDevNum > 1`, N advertised slots may map onto one physical card, and
two nodes can land on the same silicon while another idles. `allocationPolicy: balanced`
makes spreading likely; only `sharedDevNum: 1` makes it certain.

### What this module still cannot do

**Set the server's own internal-node runner count.** `NodeRunnerCount` is read by
`FileFlows.Node.dll`, not by `FileFlows.Server.dll` — the internal node's budget is database
state, reachable only through Settings → Nodes. Until it is zeroed by hand, the server keeps
taking work alongside the nodes it is supposed to be delegating to.

**Clean up after a removed node.** Deleting a `nodes:` entry removes the pod but leaves an
offline node record in the FileFlows database; delete it in the UI too.
