# OpenEBS on Talos Linux

This guide explains how to run the `openebs` module with the **hostpath** engine
on a Talos Linux cluster. It covers the machineconfig changes Talos requires
before the provisioner will work, the OPM release example, and end-to-end
verification.

> **Scope.** Only the hostpath engine is covered here. ZFS LocalPV, LVM
> LocalPV, and Mayastor all carry additional Talos prerequisites (system
> extensions, kernel modules, device selectors) and will be documented in the
> same file as the corresponding engine lands in the module.

---

## 1. Why Talos needs extra configuration

Talos's root filesystem is read-only. Only paths under `/var/*` are writable,
and containerd cannot mount an arbitrary host path into a workload pod unless
the kubelet has been told to propagate that path into the pod mount namespace.
The OpenEBS hostpath provisioner creates one directory per PV under a
configurable `basePath` — if the kubelet cannot see that directory tree, PVs
bind but workload pods fail at mount time with `no such file or directory` or
`mount propagation: not a directory`.

Two machineconfig changes fix this:

1. **Always** — a `kubelet.extraMounts` entry binding the `basePath` into the
   kubelet pod mount namespace with `rshared` propagation.
2. **Optional** — a `UserVolumeConfig` carving a dedicated partition for the
   `basePath`, if you want isolation from the ephemeral root partition or
   dedicated disk capacity.

No Talos system extension is required for hostpath. No kernel modules are
required. No `machine.sysctls` are required.

---

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| Talos version | ≥ v1.7 (stable `UserVolumeConfig`, required only if using option 2b below) |
| Cluster CNI | Any (Flannel, Cilium, Calico) |
| Helm | Not required — the OPM module emits raw Kubernetes resources |
| CUE registry | `opmodel.dev=…` registry set in your environment (see repo root CLAUDE.md) |

---

## 3. Machineconfig patch (required)

Create (or reuse) a patch file used by your Talos config pipeline. If you are
using [talhelper](https://github.com/budimanjojo/talhelper), drop the file
under `talos/patches/` and reference it from `talconfig.yaml`.

### `talos/patches/openebs-hostpath.yaml`

```yaml
# OpenEBS LocalPV Hostpath provisioner — kubelet mount.
# Binds the host directory into the kubelet pod mount namespace so the
# provisioner's helper pods and workload pods can read/write PV contents.
# rshared propagation is required: the provisioner creates new subdirectories
# at runtime and they must become visible to subsequently-started pods.
machine:
  kubelet:
    extraMounts:
      - destination: /var/openebs/local
        type: bind
        source: /var/openebs/local
        options:
          - bind
          - rshared
          - rw
```

**Do not omit `rshared`.** With only `bind + rw` (the default), newly created
PV directories are invisible to pods scheduled after the provisioner created
them, and mounts intermittently fail.

The `destination` and `source` paths must match the `basePath` set in the
OpenEBS release (see §5). Default in this module is `/var/openebs/local`.

### Wire it into `talconfig.yaml`

```yaml
controlplane:
  patches:
    - '@talos/patches/openebs-hostpath.yaml'
```

For multi-node clusters, add the same patch under `worker.patches` as well (or
use `nodes[].patches` per node).

---

## 4. Optional: dedicated Talos UserVolume

If you want the hostpath PVs to live on a dedicated disk (or a dedicated
partition carved from the system disk) instead of the ephemeral root
partition, add a `UserVolumeConfig` and point OpenEBS at the resulting mount.

### Option 4a — grow to fill the system disk

Patch fragment:

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: openebs-hostpath
provisioning:
  diskSelector:
    match: system_disk
  grow: true
```

Talos mounts this at `/var/mnt/openebs-hostpath`. Set `#config.hostpath.basePath`
to `/var/mnt/openebs-hostpath` and update the `extraMounts` destination/source
in the patch file in §3 to match.

### Option 4b — dedicated NVMe device

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: openebs-hostpath
provisioning:
  diskSelector:
    match: disk.transport == "nvme" && disk.size > 500u * GB && !system_disk
  grow: true
  filesystemSpec:
    type: xfs
    label: OPENEBS
```

Again: `basePath` must match the resulting mount path (`/var/mnt/openebs-hostpath`),
and the `extraMounts` entry must bind that path.

### Caveats

- **Path consistency is on you.** Talos does not complain if `extraMounts`
  points at a path that does not exist yet (it will be created as an empty
  directory), so a typo in `basePath` results in silently-empty PVs instead of
  an error. Double-check all three spots: `UserVolumeConfig.name`,
  `extraMounts.source`/`destination`, and `#config.hostpath.basePath`.
- **Existing data** — changing `basePath` after PVs have been provisioned will
  orphan them; new PVCs get new PVs at the new path, old PVs remain bound to
  the old path but can no longer be mounted by pods.

---

## 5. Apply the Talos configuration

With talhelper:

```bash
task baremetal:genconfig ENV=<your-env>
talosctl --talosconfig ./clusterconfig/talosconfig \
         apply-config --nodes <node-ip> \
         --file ./clusterconfig/<env>-<node>.yaml
```

Without talhelper, apply your patched machineconfig directly:

```bash
talosctl apply-config --nodes <node-ip> --file patched.yaml
```

Reboot is not required for a new `extraMounts` entry, but kubelet restarts
automatically when its config changes — that is enough.

Verify the mount propagation is active on the node:

```bash
talosctl --nodes <node-ip> read /proc/self/mountinfo | grep openebs
```

You should see a line containing `/var/openebs/local` with `shared:` in its
propagation flags.

---

## 6. Install the OPM release

Minimal release wiring this module with the hostpath engine.

### `releases/<env>/openebs/release.cue`

```cue
package openebs

import (
    mr "opmodel.dev/core/v1alpha1/modulerelease@v1"
    openebs "opmodel.dev/modules/openebs@v0"
)

mr.#ModuleRelease

metadata: {
    name:      "openebs"
    namespace: "openebs"
}

#module: openebs
```

### `releases/<env>/openebs/values.cue`

```cue
package openebs

values: {
    engine: "hostpath"
    hostpath: {
        basePath: "/var/openebs/local"
        storageClass: {
            name:              "openebs-hostpath"
            // Keep `false` when another default SC is already in place
            // (e.g. local-path-provisioner). Set `true` only if you want
            // openebs-hostpath to become the cluster default.
            isDefault:         false
            reclaimPolicy:     "Delete"
            volumeBindingMode: "WaitForFirstConsumer"
        }
    }
}
```

Validate before applying:

```bash
cd releases
task fmt
task vet CONCRETE=true
```

Then apply through whatever the environment uses to materialise releases
(flux/argocd/direct apply of the rendered manifests).

---

## 7. Verification

### 7.1 Provisioner pod is healthy

```bash
kubectl -n openebs get pods -l openebs.io/component-name=openebs-localpv-provisioner
kubectl -n openebs logs deploy/openebs-localpv-provisioner
```

Expect a single Running pod and log lines ending with `Starting Provisioner...`.

### 7.2 StorageClass is present

```bash
kubectl get sc openebs-hostpath -o yaml
```

Check that `provisioner` is `openebs.io/local`, that `parameters.basePath` is
your intended path, and that `volumeBindingMode` is `WaitForFirstConsumer`.

### 7.3 End-to-end PVC smoke test

```yaml
# smoke-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openebs-smoke
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: openebs-hostpath
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: openebs-smoke
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox
      command: ["sh", "-c", "echo hello > /data/proof && ls -la /data && sleep 5"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: openebs-smoke
```

```bash
kubectl apply -f smoke-pvc.yaml
kubectl wait --for=condition=Ready pod/openebs-smoke --timeout=2m
kubectl logs openebs-smoke
kubectl get pv
```

You should see `hello` in the logs, and a PV whose `.spec.local.path` is
`/var/openebs/local/pvc-<uid>`. Inspect the host directly:

```bash
talosctl --nodes <node-ip> ls /var/openebs/local
```

Clean up:

```bash
kubectl delete -f smoke-pvc.yaml
```

With `reclaimPolicy: Delete`, the host directory is removed by a helper pod
within a few seconds of the PVC being deleted.

---

## 8. Multi-pod / sidecar access on a single node

OpenEBS hostpath produces `ReadWriteOnce` PVs. On Kubernetes, `ReadWriteOnce`
restricts the PV to a single **node** — not a single pod. Multiple pods (or a
workload pod plus its sidecars) scheduled on the same node may mount the same
PVC concurrently. This is the standard pattern for a main container plus a
logging/metrics sidecar, or a job running alongside a long-lived workload.

The stricter mode that actually limits to one pod is `ReadWriteOncePod`. The
module does not emit PVs with that mode, and a PVC requesting it is not
compatible with this StorageClass.

If you need true multi-node `ReadWriteMany`, put an NFS gateway
(`csi-driver-nfs` or similar) in front of an openebs-hostpath PVC — OpenEBS
hostpath is block-oriented and cannot deliver RWX directly.

---

## 9. Uninstall / remove

1. Delete or scale down all workloads using PVCs backed by this StorageClass.
2. Delete the PVCs (PVs will be reclaimed per `reclaimPolicy`).
3. Delete the OPM ModuleRelease.
4. Remove the `openebs-hostpath.yaml` patch reference from `talconfig.yaml`
   and re-apply machineconfig.
5. If a UserVolume was dedicated to OpenEBS, remove its `UserVolumeConfig`
   (Talos will reclaim the partition on the next wipe; data on that partition
   is destroyed).

Manually clean any orphaned directories under `basePath` if you used
`reclaimPolicy: Retain`.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pod stuck in `ContainerCreating` with `MountVolume.SetUp failed … no such file or directory` | `extraMounts` missing or `basePath` mismatch between SC and patch | Confirm §3 patch applied; `talosctl read /proc/self/mountinfo \| grep openebs` |
| PVC stuck `Pending`, provisioner logs `BasePath does not exist` | Path typo; `basePath` does not resolve on every node | Fix `basePath` in values or in the extraMounts patch; re-roll provisioner |
| Helper pod (`init-pv-<pvc>`) stuck `Pending` | Node has no PVC taint tolerations or is cordoned | Uncordon/untaint; verify provisioner ClusterRole permits pod create/delete |
| PV bound, pod writing fine, but directory invisible via `talosctl ls` | `rshared` option missing on the extraMount | Re-apply patch with the full options list from §3 |
| PVC deleted, directory remains on host | `reclaimPolicy: Retain` (expected) OR helper pod failed | If unexpected, check provisioner logs for helper-pod errors |

### Useful commands

```bash
# Provisioner logs
kubectl -n openebs logs deploy/openebs-localpv-provisioner -f

# Events for a specific PVC
kubectl describe pvc <pvc-name>

# What the kubelet actually mounted
talosctl --nodes <node-ip> read /proc/self/mountinfo | grep -E 'openebs|shared:'

# Disk usage of the backing path
talosctl --nodes <node-ip> read /proc/self/mountinfo | grep '/var/openebs'
```

---

## 11. References

- Talos storage guide — <https://www.talos.dev/latest/kubernetes-guides/configuration/storage/>
- Talos `UserVolumeConfig` — <https://www.talos.dev/latest/reference/configuration/block/uservolumeconfig/>
- OpenEBS LocalPV HostPath — <https://openebs.io/docs/concepts/localpv-hostpath>
- OpenEBS upstream Talos notes — <https://github.com/openebs/dynamic-localpv-provisioner/blob/develop/docs/installation/platforms/talos.md>
