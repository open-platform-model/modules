# OpenEBS ZFS LocalPV — Deployment Notes

## Talos Linux Requirements

### Namespace Pod Security

The `openebs` namespace must have privileged Pod Security Admission labels. The module's namespace is created with `--create-namespace` on first `opm release apply` and inherits no PSA labels — most clusters with a default-allow PSA stance work fine, but a `restricted`/`baseline` cluster needs explicit labels:

```yaml
pod-security.kubernetes.io/enforce: privileged
pod-security.kubernetes.io/audit: privileged
pod-security.kubernetes.io/warn: privileged
```

### Talos Machine Config Patch

A machine-config patch must:

- Load the `zfs` kernel module (`machine.kernel.modules: [{name: zfs}]`)
- Bind-mount the pool path into the kubelet namespace with `rshared` propagation

Two variants live in `larnet/infra/talos/patches/`:

- `openebs-zfs.yaml` — bind path `/var/openebs` (used by `lnn1-mrspel`)
- `openebs-zfs-zfspv-pool.yaml` — bind path `/var/mnt/zfspv-pool` (used by `gon1-nas2`, mirrors `openebs-hostpath.yaml` naming)

The bind path must match the ZFS pool mountpoint set when creating the pool (see ZFS Pool Required below).

### ZFS Pool Required

A ZFS pool named `zfspv-pool` (default — configurable via `storageClass.poolName`) must exist on the node before the CSI node plugin starts. Without it, the node plugin starts but PVC creation fails with `pool not found`.

Create with an explicit mountpoint that matches the Talos bind mount:

```bash
zpool create -m /var/mnt/zfspv-pool -f -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa -O recordsize=1M \
  zfspv-pool raidz2 /dev/disk/by-id/wwn-0x...
```

Always use `/dev/disk/by-id/wwn-*` paths — kernel `sd*` letters drift across reboots.

---

## Upstream 2.6.x divergences (empirically discovered, gon1-nas2, 2026-05-18)

The module's CUE definition diverges from naive readings of the upstream `openebs/zfs-localpv` operator.yaml in several places. Each was discovered by deploying against a real cluster and reading the resulting controller/node logs. If you bump the `image.tag` past `2.6.2` and any of the following stop being true upstream, the module will need follow-up changes.

### Env vars: `OPENEBS_NODE_NAME` required (in addition to `OPENEBS_NODE_ID`)

The 2.6.x binary fatal-exits on startup with `OPENEBS_NODE_NAME environment variable not set` (`volume.go:89`) unless that variable is set. The module sets both `OPENEBS_NODE_ID` and `OPENEBS_NODE_NAME` from `spec.nodeName` on both the controller and node containers — older releases of the driver only needed `OPENEBS_NODE_ID`.

### Args: `--nodename` (was `--nodeid` in pre-2.6 releases)

The CLI flag was renamed. Using the old `--nodeid` produces `Error: unknown flag: --nodeid`. The module passes `--nodename=$(OPENEBS_NODE_NAME)`.

### Args: node container uses `--plugin=agent` (NOT `--plugin=node`)

`--plugin=node` in 2.6.x registers only the Identity CSI service and omits the Node service. Kubelet then fails plugin registration with `unknown service csi.v1.Node`. `--plugin=agent` registers both Identity and Node services — that is what the module uses for the node DaemonSet. The controller container still uses `--plugin=controller`.

### CRD scope: `ZFSNode` is **Namespaced**, not `Cluster`

The driver's controller queries the namespaced endpoint (`/apis/zfs.openebs.io/v1/namespaces/openebs/zfsnodes`) and returns `the server could not find the requested resource (get zfsnodes.zfs.openebs.io)` if the CRD has `scope: Cluster`. The module's `crds_data.cue` defines `zfsnodes.zfs.openebs.io` with `scope: Namespaced` for this reason. The mismatch will look like a generic discovery error in logs — quick test: `kubectl auth can-i list zfsnodes --as=...` will succeed even when the controller cannot, because the controller's typed client uses the namespaced path.

### CRD subresource: `status` subresource **disabled** on all 4 ZFS CRDs

The upstream zfs-driver 2.6.x writes `ZFSVolume.status.state = "Ready"` via a regular `Update()` call after the node finishes `zfs create`. When the API server treats `status` as a subresource, regular `Update()` silently strips the `status` field, leaving `status` empty. The controller's wait loop then polls until its 10-second deadline expires and tears the volume back down — observable as `CreateVolume failed ... DeadlineExceeded`, with the dataset visible on the host (created and then destroyed within ~10s).

The module's `crds_data.cue` therefore intentionally does NOT enable the `status` subresource on `zfsvolumes`, `zfssnapshots`, `zfsbackups`, or `zfsrestores`. This deviates from upstream operator.yaml. If the upstream binary is patched to call `UpdateStatus()` in a future release, re-enable the subresources.

This change is destructive on existing CRDs: a CRD's subresource toggle cannot be edited in place — the CRD must be deleted and recreated, which removes all existing CRs. The module will recreate the CRD on the next `opm release apply`, but in-flight `ZFSVolume` CRs are lost. Avoid bumping past a module version that toggles this on a cluster with live workloads.

### CRD required-fields: `nodeID` **NOT required** on ZFSVolume / ZFSSnapshot spec

A naive transcription of the upstream CRD lists `["capacity", "nodeID", "ownerNodeID", "poolName"]` as required spec fields. The 2.6.x driver creates the CR with only `ownerNodeID` populated and lets the node controller fill in `nodeID` later when the volume is actually mounted. Marking `nodeID` as required causes `CreateVolume` to fail with `ZFSVolume.zfs.openebs.io "pvc-..." is invalid: spec.nodeID: Required value`. The module's required list omits `nodeID`.

### Controller RBAC: needs `csinodes` (storage.k8s.io)

The `csi-provisioner` sidecar lists `csinodes.storage.k8s.io` for topology-aware scheduling. Without this verb the sidecar log-spams `cannot list resource "csinodes"`. The module's `controller-rbac` includes it.

### Controller RBAC: needs `zfsnodes` in the controller rule

The controller polls `ZFSNode` CRs to find which pools live on which nodes. Without `zfsnodes` in the controller rule (only the node has it by default in some templates), the controller log-spams `cannot list resource "zfsnodes"`. The module's `controller-rbac` rule for `zfs.openebs.io` includes `zfsnodes` and `zfsnodes/status`.

---

## Node plugin runtime: chroot wrapper for `zfs` / `zpool`

The `openebs/zfs-driver` container image is glibc-based. The Talos `siderolabs/zfs` extension installs `zfs` and `zpool` as **musl-linked** binaries at `/usr/local/sbin/` on the host. Mounting `/host` into the container and adding `/host/usr/local/sbin` to `PATH` is not enough — the binary's interpreter (`/lib/ld-musl-x86_64.so.1`) does not exist inside the glibc container, so `fork/exec /host/usr/local/sbin/zfs` fails with `no such file or directory`.

Workaround: an init container (`install-zfs-wrappers`) writes one-line `chroot /host /usr/local/sbin/zfs "$@"` (and the same for `zpool`) into an emptyDir mounted at `/opt/zfs-bin` on the main container. The main container's `PATH` prepends `/opt/zfs-bin`, so the driver's `exec.Command("zfs")` resolves to the wrapper, which then chroots into the host where the interpreter and libs exist.

This implies the node container must keep:

- `host-root` volume mount at `/host` (already present)
- `chroot` capability via `securityContext.privileged: true` (already present)
- `traits_workload.#InitContainers` trait + a `zfs-wrappers` emptyDir volume (added by this module)

If a future driver release ships in a musl-based image (or includes its own zfs binaries), drop the init container and revert `PATH` to a normal value.

---

## Sidecar containers

The module emits all 5 required CSI sidecars:

- Controller Deployment: `csi-provisioner`, `csi-attacher`, `csi-resizer`, `csi-snapshotter`
- Node DaemonSet: `csi-node-driver-registrar`

Versions are pinned via `#config.sidecars.{provisionerTag, attacherTag, resizerTag, snapshotterTag, nodeRegistrarTag}` — defaults match the upstream operator.yaml at v2.6.2:

| Sidecar | Default tag |
|---|---|
| csi-provisioner | v3.6.3 |
| csi-attacher | v4.4.3 |
| csi-resizer | v1.9.3 |
| csi-snapshotter | v6.3.3 |
| csi-node-driver-registrar | v2.9.3 |

All sidecars pull from `registry.k8s.io/sig-storage/`.

Note: `csi-attacher` is technically not used (the driver advertises `attachRequired: false` via the absent `CSIDriver` object — see below). It is included for parity with upstream operator.yaml. Removing it has no functional impact and would save one container slot per controller pod.

---

## Known limitations

### No `CSIDriver` object is emitted

The OPM workspace catalog (`catalog/kubernetes/v1/resources/storage/`) does not currently have a `CSIDriver` resource type — only `StorageClass`, `PV`, `PVC`. The upstream operator.yaml ships a `CSIDriver` object that pins:

```yaml
spec:
  attachRequired: false
  podInfoOnMount: true
```

Without the explicit object, kubelet uses its defaults:

- `attachRequired` defaults to `true` — kubelet calls `ControllerPublishVolume` before mount. The driver returns `Unimplemented`, and kubelet falls back to direct mount via the node plugin. This works but adds one round-trip per volume mount and a benign error log entry per mount.
- `podInfoOnMount` defaults to `false` — the driver does not receive pod metadata (name, namespace, uid) in `NodeStageVolume`/`NodePublishVolume` calls. The zfs-localpv driver does not use this metadata for anything user-visible, so the default is acceptable.

End-to-end smoke testing on gon1-nas2 (2026-05-18) confirmed PVCs bind and pods mount/read/write successfully without the `CSIDriver` object.

Two routes to fix this properly:

1. Add a `CSIDriver` resource definition to the workspace catalog (`catalog/kubernetes/v1/resources/storage/csidriver.cue`) and a `kubernetes/providers/.../csidriver-transformer@v1`. Then add a `csidriver` component to this module.
2. Apply a one-off `CSIDriver` YAML out of band:
   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: CSIDriver
   metadata:
     name: zfs.csi.openebs.io
   spec:
     attachRequired: false
     podInfoOnMount: true
     volumeLifecycleModes: [Persistent]
   ```

### StorageClass name has the release-name prefix

The OPM Kubernetes provider's StorageClass transformer renders the SC as `<release-name>-<component-name>`. With `metadata.name: "openebs-zfs"` on the release and the component named `zfspv`, the resulting SC is `openebs-zfs-zfspv` regardless of what `#config.storageClass.name` is set to in values. Anything that hard-codes the SC name needs to use the prefixed form.

### CRD schema is heavily stripped

`crds_data.cue` carries a minimal subset of each upstream CRD's openAPI schema — enough to make the driver work, but not the full upstream surface. Specifically, the `pools[]` items on `ZFSNode` only list `name`, `uuid`, and `free` — the node plugin populates `used` too, which the API server silently drops, producing a benign `W ... warnings.go: unknown field "pools[0].used"` log entry. If you need richer CR validation or want printer columns (kubectl wide output), expand `crds_data.cue` from the upstream operator.yaml.

### Module is tested only on gon1-nas2

All discoveries above are from a single cluster (Talos v1.12.7, k8s v1.33.0, `siderolabs/zfs` v2.4.1). Behavior may differ on:

- Different Talos versions (kernel module ABI, /usr/local/sbin layout)
- Different driver versions (the 2.6.x divergences may regress or change in 2.7+)
- Non-Talos hosts where zfs binaries live at `/sbin/zfs` and use glibc (no chroot wrapper needed; init container should be made conditional)

---

## Reference

- Upstream: <https://github.com/openebs/zfs-localpv>
- Upstream operator.yaml (canonical reference): <https://github.com/openebs/zfs-localpv/blob/develop/deploy/zfs-operator.yaml>
- ZFS-on-Talos blog (original `openebs-zfs.yaml` patch source): <https://www.roosmaa.net/blog/2024/setting-up-zfs-on-talos/>
