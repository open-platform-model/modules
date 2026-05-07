# snapshot_controller Module Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../DESIGN_PATTERNS.md).

**Tier:** 2 (infrastructure dependency)
**Upstream:** https://github.com/kubernetes-csi/external-snapshotter
**OPM Module Path:** `opmodel.dev/modules/snapshot_controller`

---

## Overview

The CSI external-snapshotter is a Kubernetes-SIG-Storage component that provides cluster
support for `VolumeSnapshot` / `VolumeSnapshotContent` / `VolumeSnapshotClass` CRDs and
drives the corresponding CSI snapshot RPCs (`CreateSnapshot`, `DeleteSnapshot`,
`ListSnapshots`) against any CSI driver that advertises the
`CONTROLLER_SERVICE_CAPABILITY: CREATE_DELETE_SNAPSHOT` capability.

It is a hard prerequisite for any workload that needs storage-level snapshots —
including ch_vmm (VM disk snapshots), Velero, K8up if used with snapshot mode, and any
manual `kubectl create -f volumesnapshot.yaml` flow.

Required by `ch_vmm` so that VirtualMachineSnapshot / VMRestoreSpec CRs can take
point-in-time snapshots of VM disks. Without it, ch-vmm logs
`no matches for kind "VolumeSnapshot" in version "snapshot.storage.k8s.io/v1"` on a 10s
loop and any snapshot-related VM CR will fail.

---

## Architecture

The external-snapshotter project ships **two** distinct components — the module should
deploy only the cluster-wide one. The per-driver sidecar runs alongside each CSI driver
and is **not** in scope for this module.

```
┌──────────────────────────────────────────────────────────────┐
│  snapshot-controller (Deployment, kube-system or own ns)     │
│    Watches VolumeSnapshot CRs                                │
│    Creates VolumeSnapshotContent CRs                         │
│    Drives Bound + ReadyToUse status                          │
│    Does NOT call any CSI RPC directly                        │
└──────────────────────────────────────────────────────────────┘
                             │ via VolumeSnapshotContent
                             ▼
┌──────────────────────────────────────────────────────────────┐
│  csi-snapshotter sidecar (lives inside each CSI driver pod)  │
│    Reads VolumeSnapshotContent                               │
│    Calls CreateSnapshot / DeleteSnapshot on the CSI socket   │
│    OUT OF SCOPE — shipped as part of openebs/openebs-zfs/etc │
└──────────────────────────────────────────────────────────────┘
```

The per-driver sidecar lives inside the CSI driver Pod and is bundled with the storage
driver's own deployment manifests (`openebs-zfs-controller`, `openebs-localpv-provisioner`,
etc.). This module only owns the cluster-singleton controller plus the three CRDs that
it watches.

---

## Components

| Component | Kind | Purpose |
| --- | --- | --- |
| `snapshot-controller` | Deployment | The cluster-singleton controller (HA via leader election; default replicas: 2) |
| `snapshot-controller-sa` | ServiceAccount | Identity for the controller |
| `snapshot-controller-rbac` | ClusterRole + ClusterRoleBinding | Snapshot CR full access; events; secrets read for CSI auth |
| `validating-webhook` | ValidatingWebhookConfiguration + supporting Service + Deployment + cert | (Optional) `snapshot-validation-webhook` — rejects malformed VolumeSnapshotClass; recommended for production |
| `crds` | 3× CustomResourceDefinition | `volumesnapshots.snapshot.storage.k8s.io`, `volumesnapshotcontents.snapshot.storage.k8s.io`, `volumesnapshotclasses.snapshot.storage.k8s.io` (apiVersion `v1`, served + storage) |

CRDs should be embedded as a `crds_data.cue` file (same pattern as `ch_vmm/`).

The validating webhook needs a TLS Secret. Two options:

1. Cert-manager-issued (preferred — same pattern as `ch_vmm/`'s controller webhook).
2. Inline `gen-self-signed-cert.sh`-style init container (upstream's default).

Pick option 1 since cert-manager is already a dependency on every cluster running
`ch_vmm`.

---

## Configuration (`#config`)

Minimum viable surface:

```cue
#config: {
    namespace: string | *"snapshot-controller"
    releaseName: string | *"snapshot-controller"   // see ch_vmm DEPLOYMENT_NOTES — needed for cert/webhook name alignment

    controller: {
        image:    schemas.#Image  // registry.k8s.io/sig-storage/snapshot-controller
        replicas: int & >=1 | *2
        leaderElection: bool | *true
        resources?: schemas.#ResourceRequirementsSchema
    }

    webhook: {
        enabled: bool | *true
        image:   schemas.#Image  // registry.k8s.io/sig-storage/snapshot-validation-webhook
        replicas: int & >=1 | *2
        resources?: schemas.#ResourceRequirementsSchema
    }

    certificates: {
        duration:    string | *"2160h"
        renewBefore: string | *"360h"
    }
}
```

Image references should be pinned by SHA, sourced from the upstream release tag
(currently v8.2.0 stable as of 2026-04 — controller and webhook ship from the same
release with matching tags).

---

## Prerequisites

- Kubernetes ≥ 1.20 (for `snapshot.storage.k8s.io/v1`)
- `cert-manager` (for the webhook serving cert if `webhook.enabled: true`)
- At least one CSI driver in the cluster that advertises
  `CREATE_DELETE_SNAPSHOT` — otherwise VolumeSnapshot CRs will Pending forever.
  On mr_spel: `openebs-zfs` supports snapshots; `openebs-hostpath` does not.

---

## Install Reference

Upstream layout (kubernetes-csi/external-snapshotter, `client/config/crd/` and
`deploy/kubernetes/snapshot-controller/`):

```
client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
deploy/kubernetes/webhook-example/admission-configuration.yaml
deploy/kubernetes/webhook-example/rbac-snapshot-webhook.yaml
deploy/kubernetes/webhook-example/setup-snapshot-webhook.yaml
```

The cleanest path is to render those into OPM components and pin to a known release tag.

---

## Open Questions

- **Webhook in scope?** The validating webhook is optional but strongly recommended.
  Default to enabled.
- **Single namespace or `kube-system`?** Upstream examples deploy to `kube-system`; OPM
  convention favors a dedicated namespace. Default `snapshot-controller`.
- **Default `VolumeSnapshotClass`?** This module ships only the CRDs + controller. The
  per-driver `VolumeSnapshotClass` (which references a CSI driver name + secret) belongs
  in each storage module (`openebs_zfs`, etc.) — same pattern as `StorageClass`.
- **Coexistence with K8up:** K8up uses snapshot.storage.k8s.io transparently when the
  PVC's StorageClass advertises a default `VolumeSnapshotClass`. No extra wiring needed.
