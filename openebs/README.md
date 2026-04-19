# OpenEBS (generic, engine-pluggable)

OPM module for [OpenEBS](https://openebs.io) persistent-volume engines.

A single `#config.engine` discriminator selects which OpenEBS data-plane to
deploy. v0.1.0 implements the **hostpath** engine only; zfs, lvm, and replicated
(Mayastor) are reserved for later minor versions.

This module supersedes `modules/openebs_zfs/`. The old module remains published
and consumable — migrate when convenient.

---

## Why this exists

OpenEBS ships several independent data-plane drivers. Originally each had its
own `modules/openebs_<engine>/` directory, but they share a common namespace,
RBAC surface, StorageClass shape, and operational story. Splitting them across
modules was duplicating work and pushing engine selection up to the release
config. This module consolidates them behind a single discriminator so a
release author writes `engine: "hostpath"` (or later `"zfs"`, `"lvm"`,
`"replicated"`) and the correct components materialise automatically.

---

## Engines

| Engine | Status | Notes |
|---|---|---|
| `hostpath` | **Implemented in v0.1.0** | Node-local PVs, no CSI driver, no DaemonSet. Lightest option. |
| `zfs` | Reserved (planned) | Will port from `modules/openebs_zfs/`. Requires ZFS kernel module + pool. |
| `lvm` | Reserved (planned) | Will require an LVM volume group on the node. |
| `replicated` | Reserved (planned) | Mayastor. Requires NVMe-oF, significant Talos prep. |

Until the other engines land, `#config.engine` only accepts `"hostpath"`.

---

## Quick start (hostpath on Talos)

See [`TALOS.md`](./TALOS.md) for the full Talos install flow, including the
required `machine.kubelet.extraMounts` patch. Condensed:

1. Add `talos/patches/openebs-hostpath.yaml` binding `/var/openebs/local` into
   the kubelet mount namespace with `rshared`.
2. Reference that patch from `talconfig.yaml`.
3. `talosctl apply-config` to push the new machineconfig.
4. Publish a ModuleRelease pointing at this module with `engine: "hostpath"`.
5. Verify with a smoke PVC bound to `storageClassName: openebs-hostpath`.

---

## Architecture (hostpath engine)

Three components:

- **`provisioner`** — `Deployment` running `openebs/provisioner-localpv`.
  Watches PVCs with the matching StorageClass, dispatches short-lived
  BusyBox helper pods to create per-PV directories on the target node, and
  emits the backing PV. Runs as a single replica by default.
- **`provisioner-rbac`** — `ClusterRole` + `ClusterRoleBinding` +
  `ServiceAccount` granting the provisioner the access required to watch
  PVCs/PVs, list nodes, and create/delete helper pods.
- **`storageclass`** — Kubernetes `StorageClass` with provisioner
  `openebs.io/local` and parameters selecting the hostpath storage type and
  the configured `basePath`.

No CRDs, no DaemonSet, no CSI sidecars.

---

## Configuration reference (v0.1.0)

All fields live under `#config` (see [`module.cue`](./module.cue)).

| Field | Type | Default | Description |
|---|---|---|---|
| `engine` | enum | `"hostpath"` | Engine discriminator. Only `"hostpath"` is implemented. |
| `hostpath.image.repository` | string | `openebs/provisioner-localpv` | Provisioner image repository. |
| `hostpath.image.tag` | string | `4.2.0` | Provisioner image tag. |
| `hostpath.image.digest` | string | `""` | Optional image digest pin. |
| `hostpath.helperImage.repository` | string | `openebs/linux-utils` | Short-lived helper pod image. |
| `hostpath.helperImage.tag` | string | `4.2.0` | Helper image tag. |
| `hostpath.replicas` | int | `1` | Provisioner Deployment replicas. |
| `hostpath.resources?` | schema | unset | Requests/limits for the provisioner container. |
| `hostpath.basePath` | string | `/var/openebs/local` | Host directory where PVs are created. Must match the Talos `extraMounts` destination. |
| `hostpath.storageClass.name` | string | `openebs-hostpath` | Emitted StorageClass name. |
| `hostpath.storageClass.isDefault` | bool | `false` | Mark as cluster default. |
| `hostpath.storageClass.reclaimPolicy` | enum | `Delete` | `Delete` or `Retain`. |
| `hostpath.storageClass.volumeBindingMode` | enum | `WaitForFirstConsumer` | Binding mode. `WaitForFirstConsumer` is the safe default for node-local storage. |
| `hostpath.storageClass.extraParameters?` | map | unset | Additional `StorageClass.parameters` entries (merged as-is). |

---

## Access modes

The provisioner produces `ReadWriteOnce` PVs. On Kubernetes, `ReadWriteOnce`
allows multiple pods on the **same node** to mount the same PVC concurrently
— sidecars, init containers, debugging pods all work. Only `ReadWriteOncePod`
restricts to a single pod; this module does not emit that mode.

If you need true multi-node `ReadWriteMany`, layer an NFS gateway
(`csi-driver-nfs`) on top of an openebs-hostpath PVC. Hostpath cannot deliver
RWX on its own.

---

## Relationship to `modules/openebs_zfs/`

The ZFS LocalPV module remains published and supported for existing
consumers. When the `zfs` engine lands here, migration will be a release-level
change (swap the import from `opmodel.dev/modules/openebs_zfs@v0` to
`opmodel.dev/modules/openebs@v0` and set `engine: "zfs"`). No urgent migration
is needed.

---

## See also

- [`TALOS.md`](./TALOS.md) — Talos machineconfig + install flow.
- [`DEPLOYMENT_NOTES.md`](./DEPLOYMENT_NOTES.md) — gotchas encountered in the field.
- [`../openebs_zfs/`](../openebs_zfs/) — predecessor module, ZFS-specific.
