# Deployment Notes

Running notes on issues encountered when deploying this module. Newest first.

---

## Initial scaffold (v0.1.0, hostpath engine only)

### CSI sidecar modelling gap (blocks zfs/lvm/replicated engines)

OPM's `resources_workload.#Container` trait models a single primary container
per component. OpenEBS CSI drivers (zfs, lvm, mayastor) require
4–5 external sidecars per controller Deployment:

- `csi-provisioner`
- `csi-attacher`
- `csi-resizer`
- `csi-snapshotter`
- `csi-node-driver-registrar` (node DS only)

The hostpath engine sidesteps this entirely — it is not a CSI driver — so
v0.1.0 ships without resolving the gap. Before adding the zfs/lvm/replicated
engines here, the sidecar primitive in the catalog (see
`traits_workload.#SidecarContainers`) must be extended or a module-local
pattern established for CSI external sidecars. Track as a prerequisite for
phases B2–B4, not a blocker for B1.

### StorageClass emission via `kubernetes/v1/resources/storage@v1`

This module uses `resources_storage_k8s.#StorageClass` from the
`opmodel.dev/kubernetes/v1` catalog (v1.0.1) to emit the StorageClass.
`modules/openebs_zfs/` does **not** emit a StorageClass — it documents the
expected shape but leaves creation to downstream releases. This module does
the opposite: the StorageClass is a first-class component. That matches
hostpath's "install the module, get a working SC immediately" ergonomics.

### `extraParameters` shape

`#config.hostpath.storageClass.extraParameters` is a flat `[string]: string`
map merged into `StorageClass.parameters`. The hostpath provisioner accepts
undocumented parameters (e.g. `NodeAffinityLabels`) that are worth having an
escape hatch for without widening the module schema every release. Values
are not validated — passing a bogus key will produce a StorageClass that the
provisioner silently ignores. Use with care.

### Namespace is fixed to `openebs`

`metadata.defaultNamespace: "openebs"` in `module.cue` matches upstream
OpenEBS convention and every other storage module in this repo. Not
parameterised — change it by overriding namespace in the ModuleRelease
metadata if absolutely needed, and be aware that the ServiceAccount name
(`openebs-localpv-provisioner-sa`) and ClusterRoleBinding target subject
would need coordinated overrides too.

---

## Known limitations (hostpath engine)

- Single replica by default. Setting `replicas > 1` works but the
  provisioner uses a leader election lease in the `coordination.k8s.io`
  group — exactly one replica is active at a time. Scale-out only buys
  availability, not throughput.
- No PV-level quota. `PersistentVolumeClaim.resources.requests.storage` is
  **not** enforced by the hostpath provisioner — it is advisory. Pods can
  write until `basePath`'s underlying filesystem fills. If you need quotas,
  put the `basePath` on a dedicated filesystem with project-level quotas
  (XFS project quotas, for example), or switch to the LVM or ZFS engine
  when those land.
- No snapshots. HostPath provisioner does not implement
  `VolumeSnapshotClass`. Snapshotting requires LVM, ZFS, or a filesystem-level
  solution (e.g. btrfs/zfs on the host, backed up via `k8up`/`velero`).
