# OpenEBS ZFS LocalPV

This module deploys the [OpenEBS ZFS LocalPV](https://github.com/openebs/zfs-localpv) CSI driver, which provisions Kubernetes PersistentVolumes as native ZFS datasets on a local pool. It gives you copy-on-write snapshots, inline compression, and fine-grained dataset management — without the overhead of a distributed storage system.

## Architecture

The module deploys five components into the `openebs` namespace:

| Component | Kind | Purpose |
|-----------|------|---------|
| `crds` | CustomResourceDefinitions | Registers `ZFSVolume`, `ZFSSnapshot`, `ZFSBackup`, `ZFSRestore`, and `ZFSNode` |
| `controller` | Deployment | Handles `CreateVolume`, `DeleteVolume`, snapshotting, and resizing via the CSI controller path |
| `node` | DaemonSet | Runs on every node; handles `NodeStageVolume` / `NodePublishVolume` by executing ZFS operations on the host |
| `controller-rbac` | ClusterRole + ClusterRoleBinding | Grants the controller service account access to PVs, PVCs, StorageClasses, events, and ZFS CRDs |
| `node-rbac` | ClusterRole + ClusterRoleBinding | Grants the node plugin service account access to ZFS CRDs, nodes, and CSI node objects |

The CSI controller runs as a single Deployment (scale to 2+ for HA). The CSI node plugin runs as a DaemonSet with `hostNetwork: true` and privileged access — it mounts the host's `/dev`, `/sys`, and root filesystem so it can call `zfs` and `zpool` commands via `chroot /host`.

**Note on sidecars:** The CSI controller requires four sidecar containers (`csi-provisioner`, `csi-attacher`, `csi-resizer`, `csi-snapshotter`) and the node plugin requires one (`csi-node-driver-registrar`). These are not yet modeled in the CUE module. See `DEPLOYMENT_NOTES.md` for the current workaround.

---

## Prerequisites

### 1. Talos Linux with ZFS Extension

ZFS is not part of the default Talos kernel. You must build a custom installer image using the Talos Image Factory that includes the `siderolabs/zfs` system extension, then upgrade your node to that image.

### 2. ZFS Pool on Each Node

The CSI node plugin expects a ZFS pool named `zfspv-pool` (configurable via `storageClass.poolName`) to exist on each node before the DaemonSet starts. The plugin will start without the pool, but PVC creation will fail with a "pool not found" error until the pool is present.

### 3. Privileged Pod Security on the `openebs` Namespace

The node plugin runs privileged containers. The `openebs` namespace must carry the following labels:

```yaml
pod-security.kubernetes.io/enforce: privileged
pod-security.kubernetes.io/audit: privileged
pod-security.kubernetes.io/warn: privileged
```

On Talos clusters managed with talconfig/talhelper, this is typically handled by a CNI patch (e.g., `cni-none.yaml`).

---

## Step 1: Add ZFS Extension to Talos

### Create a Talos Image Schematic

The Talos Image Factory at `factory.talos.dev` generates custom installer images from a schematic YAML that lists the system extensions you need. Create a file named `zfs-schematic.yaml` that includes your existing extensions plus `siderolabs/zfs`:

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/amd-ucode
      - siderolabs/amdgpu
      - siderolabs/zfs
```

Keep all extensions you are currently using. Omitting an existing extension will remove it from the node after upgrade.

Submit the schematic to the factory:

```bash
SCHEMATIC_ID=$(curl -s -X POST https://factory.talos.dev/schematics \
  -H "Content-Type: application/yaml" \
  --data-binary @zfs-schematic.yaml | jq -r '.id')
echo "Schematic ID: ${SCHEMATIC_ID}"
```

Record this ID. You will use it in the machine config and the upgrade command.

### Update Machine Configuration

In your cluster configuration (e.g., `larnet/infra/config/envs/gon1-nas2/config.cue` or the equivalent talconfig), make three changes:

1. Add `siderolabs/zfs` to the extensions list alongside your existing extensions.
2. Add the ZFS kernel module to the machine config so it loads on boot:
   ```yaml
   machine:
     kernel:
       modules:
         - name: zfs
   ```
3. Update the install image URL to the factory URL for your new schematic:
   ```
   https://factory.talos.dev/image/<SCHEMATIC_ID>/v1.12.5/metal-amd64.tar.gz
   ```

Also ensure the `openebs-zfs.yaml` Talos patch is referenced in your cluster config. This patch mounts `/var/openebs` for kubelet and loads the ZFS kernel module. It lives at `larnet/infra/talos/patches/openebs-zfs.yaml`.

### Apply and Upgrade

Apply the updated machine config to the node:

```bash
talosctl apply-config \
  -n <node-ip> -e <node-ip> \
  --file <generated-config.yaml>
```

Then upgrade the node to the new image:

```bash
talosctl upgrade \
  -n <node-ip> \
  --image https://factory.talos.dev/image/${SCHEMATIC_ID}/v1.12.5/metal-amd64.tar.gz \
  --preserve
```

Always pass `--preserve` during upgrades to prevent Talos from wiping the data disk.

### Verify ZFS is Loaded

After the node reboots, confirm the ZFS extension and kernel module are active:

```bash
talosctl get extensions -n <node-ip> | grep zfs
talosctl read /proc/modules -n <node-ip> | grep zfs
```

Both commands must return output before proceeding.

---

## Step 2: Create a ZFS Pool

### Identify Your Disk

Talos does not expose a shell, so you interact with the node through `talosctl` or a privileged debug container. First, identify your target disk:

```bash
talosctl get discoveredvolumes -n <node-ip>
```

This lists all block devices visible to Talos. Note the device path for the disk you want to use for ZFS. You will look up its stable `by-id` path in the next step.

### Create the Pool via Debug Container

Talos has no SSH. Use a `kubectl debug` container with `--profile=sysadmin` to get a root shell on the node's host filesystem:

```bash
kubectl -n kube-system debug -it \
  --profile=sysadmin \
  --image=alpine \
  node/<node-name>
```

Inside the debug container, the host filesystem is available under `/host`. All ZFS commands must go through `chroot /host` because the ZFS utilities are part of the Talos extension, not the Alpine image.

```bash
# List disks by stable ID (prefer by-id over /dev/sdX or /dev/nvmeXnX)
ls /host/dev/disk/by-id/ | grep -v part

# Verify the correct disk size before proceeding
# The system disk with Talos is typically much smaller (e.g., 240 GB)
# The data disk is much larger (e.g., 1.82 TiB)

# ⚠️ DESTRUCTIVE: this permanently erases all data on the target disk.
# Double-check the disk ID before running.

chroot /host wipefs --all /dev/disk/by-id/<YOUR_DISK_ID>
chroot /host zpool create -f -m legacy \
  -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  zfspv-pool /dev/disk/by-id/<YOUR_DISK_ID>

# Confirm the pool was created
chroot /host zpool status zfspv-pool
```

The `-m legacy` flag tells ZFS not to auto-mount the pool at a fixed path; OpenEBS manages dataset mount points independently.

### Reboot and Verify Persistence

The Talos ZFS extension configures automatic pool import on boot via `zpool-import.service`. Reboot to confirm:

```bash
exit  # exit the debug container
talosctl reboot -n <node-ip>
talosctl health -n <node-ip> --wait-timeout 5m

# Re-enter debug container after reboot
kubectl -n kube-system debug -it \
  --profile=sysadmin \
  --image=alpine \
  node/<node-name>

# Inside: verify the pool is online
chroot /host zpool status zfspv-pool
```

The pool must show `state: ONLINE` before deploying OpenEBS.

---

## Step 3: Deploy via OPM

With the ZFS pool online, deploy the module from the workspace root:

```bash
export CUE_REGISTRY='opmodel.dev=localhost:5000+insecure,registry.cue.works'

# Publish the module to the local registry
task publish:one MODULE=openebs_zfs

# Apply the release for your environment
opm apply releases/<env>/openebs_zfs/

# Verify all pods are running
kubectl get pods -n openebs

# Verify the StorageClass was created
kubectl get sc
```

The controller pod and node plugin pod should both reach `Running` within 60 seconds.

---

## Configuration Reference

All fields live under `#config` in `module.cue`. Override them in your `values.cue`.

### `image`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `image.repository` | string | `openebs/zfs-driver` | Container image repository for the ZFS CSI driver |
| `image.tag` | string | `2.6.2` | Image tag. See [releases](https://github.com/openebs/zfs-localpv/releases) |
| `image.pullPolicy` | enum | `IfNotPresent` | `Always`, `IfNotPresent`, or `Never` |

### `sidecars`

Sidecar image tags are pinned separately so you can upgrade them independently of the main driver.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `sidecars.provisionerTag` | string | `v3.6.3` | `csi-provisioner` sidecar tag |
| `sidecars.attacherTag` | string | `v4.4.3` | `csi-attacher` sidecar tag |
| `sidecars.resizerTag` | string | `v1.9.3` | `csi-resizer` sidecar tag |
| `sidecars.snapshotterTag` | string | `v6.3.3` | `csi-snapshotter` sidecar tag |
| `sidecars.nodeRegistrarTag` | string | `v2.9.3` | `csi-node-driver-registrar` sidecar tag |

### `controller`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `controller.replicas` | int ≥ 1 | `1` | Number of controller Deployment replicas. Set to `2` or more for HA |
| `controller.resources` | object | unset | CPU/memory requests and limits for the controller container |

### `nodePlugin`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `nodePlugin.kubeletDir` | string | `/var/lib/kubelet` | Path to the kubelet data directory. Talos uses the standard path |
| `nodePlugin.resources` | object | unset | CPU/memory requests and limits for the node plugin container |

### `storageClass`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `storageClass.poolName` | string | `zfspv-pool` | Name of the ZFS pool that must exist on all nodes |
| `storageClass.fsType` | enum | `zfs` | `zfs` for native ZFS datasets; `ext4` for zvol-backed ext4 volumes |
| `storageClass.recordSize` | string | `128k` | ZFS dataset recordsize. Only applies when `fsType` is `zfs` |
| `storageClass.compression` | enum | `lz4` | Compression algorithm: `off`, `lz4`, `gzip`, or `zstd` |
| `storageClass.dedup` | enum | `off` | ZFS deduplication. Leave `off` unless you have a specific reason and understand the memory cost |
| `storageClass.isDefault` | bool | `false` | Set to `true` to make this the cluster's default StorageClass |
| `storageClass.reclaimPolicy` | enum | `Retain` | `Retain` keeps the ZFS dataset after PVC deletion; `Delete` removes it |
| `storageClass.volumeBindingMode` | enum | `WaitForFirstConsumer` | `WaitForFirstConsumer` ensures the PV is created on the node where the Pod is scheduled |

---

## Testing Your Installation

Create a test PVC and a Pod to confirm the CSI driver can provision ZFS datasets end-to-end:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zfs-test-pvc
  namespace: default
spec:
  storageClassName: openebs-zfspv
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: zfs-test-pod
  namespace: default
spec:
  containers:
    - name: test
      image: busybox
      command: ["sh", "-c", "echo ZFS OK > /data/test.txt && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: zfs-test-pvc
EOF

# The PVC will remain Pending until a Pod is scheduled (WaitForFirstConsumer)
kubectl get pvc zfs-test-pvc
kubectl get pod zfs-test-pod

# After both are Running/Bound, verify the write succeeded
kubectl exec zfs-test-pod -- cat /data/test.txt

# Cleanup
kubectl delete pod zfs-test-pod
kubectl delete pvc zfs-test-pvc
```

The PVC should reach `Bound` within 30 seconds of the Pod being scheduled.

---

## Troubleshooting

### ZFS module not loading after reboot

Ensure `kernel.modules` with `name: zfs` is present in your Talos machine config. The ZFS extension alone is not sufficient — the kernel module must also be explicitly listed. Apply the updated config and reboot.

### Pool not auto-importing after reboot

The Talos ZFS extension uses `zpool-import.service` to import pools on boot. If the pool was created by-path (e.g., `/dev/nvme0n1`) rather than by-id, the import may fail after a reboot where device enumeration order changes. Always create pools using the stable `/dev/disk/by-id/` path.

### Pod Security blocking privileged pods

If pods in the `openebs` namespace fail with admission errors referencing Pod Security, the namespace is missing its privileged labels. Apply the required labels directly or via your CNI/Talos patch that manages namespace policies.

### Data loss during Talos upgrade

Never upgrade a node that has a ZFS pool without `--preserve`. Without this flag, Talos will wipe the disk during the upgrade process. Always run:

```bash
talosctl upgrade --preserve --image <new-installer-url> -n <node-ip>
```

### subPath mounts with ConfigMaps do not work on Talos

The upstream OpenEBS chart mounts a wrapper script via `subPath` into `/host/sbin`. This pattern fails on Talos because `/sbin` is immutable. This module works around the issue by mounting the host root filesystem at `/host` and using `chroot /host` to invoke ZFS utilities. Do not attempt to use `subPath` mounts targeting paths under `/host/sbin`.

### PVC stuck in Pending after pool creation

Check that the node plugin DaemonSet pod on the affected node is `Running`. If it crashlooped before the pool was created, it may not have re-registered with kubelet. Delete the node plugin pod on that node; the DaemonSet will recreate it and the driver will re-register.
