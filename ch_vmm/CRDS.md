# ch-vmm Custom Resources

Reference for the Custom Resources exposed by the ch-vmm controller. All CRs live under the `cloudhypervisor.quill.today/v1beta1` API group and are `Namespaced` (scoped to the namespace where the VM workload lives — typically the same namespace as the PVCs and Secrets each VM depends on).

**The API is marked experimental upstream**: "ch-vmm is still a work in progress, its API may change without prior notice." Pin the CRD version together with the controller/daemon image pair.

## Source links

- Project: [nalajala4naresh/ch-vmm](https://github.com/nalajala4naresh/ch-vmm)
- Release asset (all CRDs + controller + daemon in one YAML): [`ch-vmm.yaml`](https://github.com/nalajala4naresh/ch-vmm/releases/latest/download/ch-vmm.yaml)
- CRD source directory (latest on `main`): [`config/crd/bases/`](https://github.com/nalajala4naresh/ch-vmm/tree/main/config/crd/bases)
- Go types (behaviour + comments live here): [`api/v1beta1/`](https://github.com/nalajala4naresh/ch-vmm/tree/main/api/v1beta1)
- Latest release: [v1.4.0](https://github.com/nalajala4naresh/ch-vmm/releases/tag/v1.4.0)

## Summary

| Kind | Short name | Purpose |
| --- | --- | --- |
| [VirtualMachine](#virtualmachine) | `vm` | A single Cloud Hypervisor VM instance (CPU, memory, disks, NICs, cloud-init) |
| [VirtualDisk](#virtualdisk) | `vdisk` | A disk image materialised from HTTP, registry, snapshot, or empty, backed by a PVC |
| [VirtualDiskSnapshot](#virtualdisksnapshot) | `vdss` | Point-in-time snapshot of a VirtualDisk |
| [VirtualMachineMigration](#virtualmachinemigration) | `vmm` | Live-migration request that moves a VM between nodes |
| [VMSet](#vmset) | — | Replica controller for stateful VMs (StatefulSet analogue) |
| [VMPool](#vmpool) | — | Replica controller without strong identity (Deployment/ReplicaSet analogue) |
| [VMSnapShot](#vmsnapshot) | `vmsnap` | Point-in-time snapshot of a whole VM, optionally exported to S3 |
| [VMRollback](#vmrollback) | — | Request to roll a VM back to a VMSnapShot |
| [VMRestoreSpec](#vmrestorespec) | — | Declarative request to restore a VM from a snapshot into a fresh VM spec |

---

## VirtualMachine

A single Cloud Hypervisor VM. This is the core CR — everything else either composes into it (disks, snapshots) or manages groups of them (VMSet, VMPool).

- Upstream CRD: [`cloudhypervisor.quill.today_virtualmachines.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_virtualmachines.yaml)
- Go type: [`api/v1beta1/virtualmachine_types.go`](https://github.com/nalajala4naresh/ch-vmm/blob/main/api/v1beta1/virtualmachine_types.go)

### Spec

| Field | Type | Required | Purpose |
| --- | --- | --- | --- |
| `instance` | object | yes | Hardware shape: CPU, disks, NICs, GPUs, filesystems |
| `volumes[]` | list | — | Volume sources (container disk, PVC, VirtualDisk, cloud-init, DataVolume, memory snapshot) |
| `networks[]` | list | — | Pod/Multus network attachments |
| `resources` | `corev1.ResourceRequirements` | — | Compute requests/limits for the VM pod (mirrors Kubernetes container resources) |
| `runPolicy` | string | — | VM run policy (e.g. `Always`, `Manual`) |
| `nodeSelector`, `affinity`, `tolerations` | K8s-standard | — | Placement hints forwarded to the per-VM pod |
| `livenessProbe`, `readinessProbe` | K8s probes | — | Health checks on the VM pod |

### `spec.instance`

```yaml
instance:
  cpu:
    sockets: 2           # total vCPU sockets
    coresPerSocket: 2    # cores per socket — total vCPU = sockets * coresPerSocket
    dedicatedCPUPlacement: true   # pin vCPUs 1:1 to host cores
  disks:
    - name: root
      readOnly: false
  fileSystems:
    - name: shared       # virtiofs passthrough (see volumes[].fileSystem in upstream)
  gpus:
    - name: gpu0
      resourceName: nvidia.com/gpu
      resourceEnvName: NVIDIA_VISIBLE_DEVICES
  interfaces:
    - name: eth0
      masquerade: { cidr: 10.0.2.0/24 }   # or bridge: {}
      mac: "02:42:ac:11:00:02"
```

### `spec.volumes[]`

Each entry has a required `name` plus exactly one of the following volume sources:

| Source | Behaviour |
| --- | --- |
| `containerDisk: { image, imagePullPolicy }` | Ephemeral disk materialised from a container image layer |
| `containerRootfs: { image, size, imagePullPolicy }` | Writable rootfs built from a container image, backed by an ephemeral volume of `size` |
| `persistentVolumeClaim: { claimName, hotpluggable }` | Attach an existing PVC as a block device |
| `virtualDisk: { virtualDiskName, hotpluggable }` | Attach a `VirtualDisk` CR managed by ch-vmm |
| `dataVolume: { volumeName, hotpluggable }` | Attach a CDI `DataVolume` (requires CDI operator) |
| `cloudInit: { userData, networkData, *Base64, *SecretName }` | Inject cloud-init user-data / network-data |
| `memorySnapshot: { bucket, key }` | Restore live memory from an S3-compatible snapshot |

### `spec.networks[]`

```yaml
networks:
  - name: eth0
    pod: {}                        # default pod network
  - name: vlan100
    multus: { networkName: vlan100 }
```

### Status

`.status.phase` enum: `Pending | Scheduling | Scheduled | Running | Succeeded | Failed | Unknown | PodResizeInProgress | ResizeInProgress`. The controller also stores per-component conditions and the node the VM is pinned to.

---

## VirtualDisk

A disk image materialised from a source URL, registry, or snapshot and backed by a `PersistentVolumeClaim`. VMs then reference it via `spec.volumes[].virtualDisk`.

- Upstream CRD: [`cloudhypervisor.quill.today_virtualdisks.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_virtualdisks.yaml)
- Go type: [`api/v1beta1/virtualdisk_types.go`](https://github.com/nalajala4naresh/ch-vmm/blob/main/api/v1beta1/virtualdisk_types.go)

### Spec

```yaml
spec:
  source:
    http:     { url: "https://cloud-images.ubuntu.com/.../jammy.img" }
    registry: { url: "docker.io/library/alpine:latest", pullMethod: "" }
    diskSnapshot: { snapshotName: "<VirtualDiskSnapshot name>" }
    empty: {}
  storage:
    accessModes: ["ReadWriteOnce"]
    resources:
      requests: { storage: 20Gi }
    volumeMode: Block             # or Filesystem
```

Exactly one entry inside `source` is used. `empty: {}` allocates a blank PVC sized by `storage.resources.requests.storage`.

### Status

`.status.phase` enum: `Pending | Bound | Ready | Failed | Terminating`. Status also reports `path`, `capacity`, `used`, `available`, `attached`, `attachedTo`, and K8s-standard `conditions[]`.

---

## VirtualDiskSnapshot

Point-in-time snapshot of a single `VirtualDisk`. Stored either in the configured `spec.storage` PVC or at a custom `spec.destination` path.

- Upstream CRD: [`cloudhypervisor.quill.today_virtualdisksnapshots.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_virtualdisksnapshots.yaml)

### Spec

```yaml
spec:
  virtualDiskName: root-disk       # required
  destination: /snapshots/root/1   # optional — path on the daemon
  skipSnapshot: false              # if true, just marks the spec without triggering a real snapshot
  storage:
    accessModes: ["ReadWriteOnce"]
    resources: { requests: { storage: 10Gi } }
```

Status carries `completedAt` and K8s-standard `conditions[]`. The resulting object is consumable by a new `VirtualDisk` via `spec.source.diskSnapshot`.

---

## VirtualMachineMigration

Declarative request to live-migrate a running VM to a different node. The controller coordinates state transfer between the source and target `ch-vmm-daemon` pods.

- Upstream CRD: [`cloudhypervisor.quill.today_virtualmachinemigrations.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_virtualmachinemigrations.yaml)

### Spec

```yaml
spec:
  vmName: my-vm        # required — VirtualMachine in the same namespace
```

### Status

`.status.phase` enum: `Pending | Scheduling | Scheduled | TargetReady | Running | Sent | Succeeded | Failed`.

The name of this type disambiguates from the core `VirtualMachine` CR — think of it as an imperative "migrate once" task object, not a long-lived resource.

---

## VMSet

Replica controller for VMs that have stable identity and persistent storage — the StatefulSet analogue. Each replica gets `-0`, `-1`, … suffix and its own set of disk templates materialised per-ordinal.

- Upstream CRD: [`cloudhypervisor.quill.today_vmsets.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_vmsets.yaml)
- Go type: [`api/v1beta1/vmset_types.go`](https://github.com/nalajala4naresh/ch-vmm/blob/main/api/v1beta1/vmset_types.go)

### Spec

| Field | Purpose |
| --- | --- |
| `replicas` | Desired replica count |
| `selector` | Label selector matching the VMs this VMSet owns |
| `virtualMachineTemplate` | Embedded `VirtualMachineSpec` template cloned per replica |
| `diskTemplates[]` | Embedded `VirtualDiskSpec` templates materialised per replica |
| `strategy` | Rolling update policy (`maxSurge`, `maxUnavailable`, `volumeClaimRetentionPolicy.{whenDeleted, whenScaled}`) |

Use VMSet when each VM needs a persistent identity (hostname, stable networking, dedicated disks).

---

## VMPool

Replica controller for stateless or interchangeable VMs — the Deployment/ReplicaSet analogue. Similar surface to VMSet but without the ordinal-stable identity or `strategy` block.

- Upstream CRD: [`cloudhypervisor.quill.today_vmpools.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_vmpools.yaml)
- Go type: [`api/v1beta1/vmpool_types.go`](https://github.com/nalajala4naresh/ch-vmm/blob/main/api/v1beta1/vmpool_types.go)

### Spec

| Field | Purpose |
| --- | --- |
| `replicas` | Desired replica count |
| `selector` | Label selector for owned VMs |
| `virtualMachineTemplate` | Embedded `VirtualMachineSpec` template |
| `diskTemplates[]` | Embedded `VirtualDiskSpec` templates |

Use VMPool for worker-style fleets (CI runners, disposable build VMs, autoscaling compute).

---

## VMSnapShot

Whole-VM snapshot — captures every disk and optionally the VM's live memory, then streams the bundle to an S3-compatible backend.

- Upstream CRD: [`cloudhypervisor.quill.today_vmsnapshots.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_vmsnapshots.yaml)

### Spec

```yaml
spec:
  vm: my-vm                   # source VirtualMachine name
  skipMemorySnapshot: false   # required — if true, snapshot is disks-only
  bucket: vm-backups
  path: snapshots/my-vm/2026-04-19T10-00
  region: us-east-1
  accessKey: ...              # S3 credentials (inline — prefer storing in a Secret + refactor)
  secretKey: ...
  sessionToken: ...           # optional for temporary credentials
```

> ⚠️ Embedding raw S3 credentials inline in the CR is the upstream default. Pair with restrictive RBAC on `vmsnapshots` or use a mutating webhook to pull credentials from a Secret at admission time.

---

## VMRollback

Request to roll a VM back to a previously captured `VMSnapShot`.

- Upstream CRD: [`cloudhypervisor.quill.today_vmrollbacks.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_vmrollbacks.yaml)

### Spec

```yaml
spec:
  snapshot: my-vm-2026-04-18    # VMSnapShot name in the same namespace
```

The field is named `snapshot` in the current upstream schema despite the Go comment calling it `Foo` (pre-release boilerplate). Treat this CR as experimental.

---

## VMRestoreSpec

Declarative restore request — creates a *new* VM from a VMSnapShot, using the embedded `vmSpec` to describe the target VM shape. Differs from `VMRollback`, which mutates the existing VM in place.

- Upstream CRD: [`cloudhypervisor.quill.today_vmrestorespecs.yaml`](https://github.com/nalajala4naresh/ch-vmm/blob/main/config/crd/bases/cloudhypervisor.quill.today_vmrestorespecs.yaml)

### Spec

```yaml
spec:
  vmName: restored-vm
  vmSpec: { ... VirtualMachineSpec ... }
```

`vmSpec` is the full `VirtualMachineSpec` (same surface as [VirtualMachine](#virtualmachine)) — the controller uses it to construct a new VM and seed disks from the referenced snapshot.

---

## Admission webhooks

The ch-vmm controller registers the following mutating and validating webhooks. CR apply operations fail if the controller is unreachable (`failurePolicy: Fail`).

| Webhook | Operations | Applies to |
| --- | --- | --- |
| `mvirtualmachine.kb.io` / `vvirtualmachine.kb.io` | CREATE, UPDATE | `virtualmachines` |
| `mvirtualdisk-v1beta1.kb.io` / `vvirtualdisk-v1beta1.kb.io` | CREATE, UPDATE | `virtualdisks` |
| `mvirtualdisksnapshot-v1beta1.kb.io` / `vvirtualdisksnapshot-v1beta1.kb.io` | CREATE, UPDATE | `virtualdisksnapshots` |
| `mvmpool-v1beta1.kb.io` / `vvmpool-v1beta1.kb.io` | CREATE, UPDATE | `vmpools` |
| `mvmset-v1beta1.kb.io` / `vvmset-v1beta1.kb.io` | CREATE, UPDATE | `vmsets` |
| `vvirtualmachinemigration.kb.io` | CREATE, UPDATE | `virtualmachinemigrations` (validate-only) |

## Schema in this module

The OPM module in this repo installs simplified CRDs using `x-kubernetes-preserve-unknown-fields: true` — the controller still enforces the real schema at reconcile time, but `kubectl explain` and server-side dry-runs will show only a stub. For the authoritative field list, refer to the upstream sources linked above or read the raw YAML bundled in the release asset.

## Typical workflow

```text
VirtualDisk(source=http://ubuntu.img)         ─┐
                                               ├─► VirtualMachine(volumes=[virtualDisk: root, cloudInit: ...])
VirtualDisk(source=empty, 50Gi)               ─┘            │
                                                            │ (VirtualMachineMigration moves it to another node)
                                                            ▼
                                                    VMSnapShot (to S3)
                                                            │
                                               ┌────────────┴────────────┐
                                               ▼                         ▼
                                          VMRollback               VMRestoreSpec (new VM)
```
