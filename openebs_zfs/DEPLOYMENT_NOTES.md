# OpenEBS ZFS LocalPV — Deployment Notes

## Talos Linux Requirements

### Namespace Pod Security

The `openebs` namespace must have privileged Pod Security Admission labels.
The gon1-nas2 cluster already has this configured via `cni-none.yaml` patch.

### Talos Machine Config Patch

Apply the `openebs-zfs.yaml` Talos patch before deploying:

- Location: `larnet/infra/talos/patches/openebs-zfs.yaml`
- This patch: loads the ZFS kernel module and mounts `/var/openebs` for kubelet

### ZFS Pool Required

A ZFS pool named `zfspv-pool` must exist on the node before CSI node plugin starts.
Without it, the node plugin will start but PVC creation will fail.

## Sidecar Containers

The CSI controller requires 4 sidecar containers in addition to the main driver:

- `csi-provisioner` — handles CreateVolume/DeleteVolume
- `csi-attacher` — handles ControllerPublishVolume
- `csi-resizer` — handles ControllerExpandVolume
- `csi-snapshotter` — handles CreateSnapshot/DeleteSnapshot

The CSI node plugin requires 1 sidecar:

- `csi-node-driver-registrar` — registers the driver with kubelet

**Note:** OPM's `#Container` trait manages a single primary container per component.
The sidecar containers are currently not modeled in this CUE module. When deploying
via `opm apply`, sidecars will need to be added as a post-processing step or via
an OPM trait if one becomes available for multi-container pods.

See: <https://github.com/openebs/zfs-localpv/blob/develop/deploy/zfs-operator.yaml>

## CRD Stubs

The CRD YAML files in `crds/` are minimal stubs created from schema documentation
because the upstream GitHub URLs were unreachable at module creation time.
Replace them with the upstream CRDs from:
  <https://github.com/openebs/zfs-localpv/tree/develop/deploy/yamls/>

## Known Issues

### subPath Mount on Talos

The upstream chart uses a ConfigMap with a ZFS wrapper script and mounts it via
subPath to `/host/sbin`. This pattern does NOT work on Talos (immutable /sbin).
The solution used here: mount `/host` directly and use `chroot /host` in commands.

### Upgrade Data Preservation

When upgrading Talos, always use `--preserve` flag to keep ZFS pool data:

```bash
talosctl upgrade --preserve --image <new-installer-url>
```
