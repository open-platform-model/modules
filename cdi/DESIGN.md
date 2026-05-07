# cdi Module Design

> For reusable CUE patterns used in implementing this module, see [`modules/DESIGN_PATTERNS.md`](../DESIGN_PATTERNS.md).

**Tier:** 2 (infrastructure dependency)
**Upstream:** https://github.com/kubevirt/containerized-data-importer
**OPM Module Path:** `opmodel.dev/modules/cdi`

---

## Overview

CDI (Containerized Data Importer) is a KubeVirt sub-project that provides VM-disk
provisioning for Kubernetes. It introduces the `DataVolume` CRD — a thin abstraction
over `PersistentVolumeClaim` that auto-imports disk image content from external sources
(HTTP/S URLs, container registries, container images, blank, S3, GCS, upload, clone)
into the underlying PVC before any VM consumes it.

Required by `ch_vmm` (Cloud Hypervisor virtualization add-on) so that VirtualMachine CRs
can reference DataVolumes for their boot disks. Without CDI installed, the ch-vmm
controller logs `no matches for kind "DataVolume" in version "cdi.kubevirt.io/v1beta1"`
on a 10s loop and any VirtualMachine spec referencing a DataVolume will not reconcile.

---

## Architecture

CDI ships as an operator-pattern install:

```
┌──────────────────────────────────────────────────────────────┐
│  cdi-operator (Deployment, cdi namespace)                    │
│    Watches a single CDI CR and reconciles all CDI components │
│    (controller, apiserver, uploadproxy, cloner, importer)    │
└──────────────────────────────────────────────────────────────┘
                             │ creates
                             ▼
┌──────────────────────────────────────────────────────────────┐
│  cdi-deployment (Deployment) — main DataVolume controller    │
│  cdi-apiserver  (Deployment) — admission for upload tokens   │
│  cdi-uploadproxy (Deployment) — receives /upload PUT         │
│  cdi-cronjob-controller (Deployment) — DataImportCron        │
└──────────────────────────────────────────────────────────────┘
                             │ on demand
                             ▼
┌──────────────────────────────────────────────────────────────┐
│  importer / cloner / uploadserver Pods (per DataVolume)      │
│    Streams source → PVC, then exits                          │
└──────────────────────────────────────────────────────────────┘
```

The recommended deployment pattern is to install the operator and a single `CDI` CR;
the operator then manages every other CDI component itself. This module should mirror
that pattern rather than directly emitting the inner Deployments.

---

## Components

| Component | Kind | Purpose |
| --- | --- | --- |
| `operator` | Deployment | cdi-operator — single reconciler for the CDI CR |
| `operator-sa` | ServiceAccount | bound to cluster-admin-equivalent role for managing CDI subresources |
| `operator-rbac` | ClusterRole + ClusterRoleBinding | broad permissions the operator needs to reconcile CDI components |
| `crds` | CustomResourceDefinitions | CDI's own CRDs: `cdis.cdi.kubevirt.io`, `datavolumes.cdi.kubevirt.io`, `dataimportcrons.cdi.kubevirt.io`, `datasources.cdi.kubevirt.io`, `objecttransfers.cdi.kubevirt.io`, `storageprofiles.cdi.kubevirt.io`, `volumeimportsources.cdi.kubevirt.io`, `volumeuploadsources.cdi.kubevirt.io`, `volumeclonesources.cdi.kubevirt.io` |
| `cdi` | CDI custom resource | `apiVersion: cdi.kubevirt.io/v1beta1, kind: CDI` — single instance the operator watches; fields: `spec.imagePullPolicy`, `spec.uninstallStrategy`, optional `spec.config` (feature gates, scratch space storage class, default proxy, etc.) |

CRDs should be embedded as a `crds_data.cue` file (same pattern as `ch_vmm/`).

---

## Configuration (`#config`)

Minimum viable surface:

```cue
#config: {
    namespace: string | *"cdi"           // operator + workload namespace
    operatorImage: schemas.#Image        // pin operator image + digest
    cdiImage:      schemas.#Image        // image used for the inner components
    importerImage: schemas.#Image        // image used by per-DataVolume importer pods
    uploadserverImage: schemas.#Image
    uploadproxyImage:  schemas.#Image
    controllerImage:   schemas.#Image
    apiserverImage:    schemas.#Image

    // Optional CDI CR config
    config?: {
        scratchSpaceStorageClass?: string
        featureGates?: [...string]
        // ... see https://github.com/kubevirt/containerized-data-importer/blob/main/staging/src/kubevirt.io/containerized-data-importer-api/pkg/apis/core/v1beta1/types.go for full schema
    }
}
```

Image digests should be pinned by SHA, sourced from the upstream release manifest
(`cdi-operator.yaml` + `cdi-cr.yaml` for the chosen tag — currently v1.62.0 is the
latest stable as of 2026-04).

---

## Prerequisites

- Kubernetes ≥ 1.28
- A working storage class with `ReadWriteOnce` (CDI uses PVCs as the import target)
- `cert-manager` is **not** required (CDI's apiserver generates its own TLS via a
  self-signed CA stored in the `cdi-uploadproxy-server-cert` Secret)

---

## Install Reference

Upstream release manifests (single-file install):

```
https://github.com/kubevirt/containerized-data-importer/releases/download/v<VERSION>/cdi-operator.yaml
https://github.com/kubevirt/containerized-data-importer/releases/download/v<VERSION>/cdi-cr.yaml
```

The cleanest path for this module is to render those two files into OPM components
(operator Deployment + RBAC + CRDs in `cdi-operator.yaml`, the `CDI` CR in `cdi-cr.yaml`)
rather than re-deriving the manifests from scratch.

---

## Open Questions

- **Storage class binding:** mr_spel currently has openebs (hostpath) and (planned)
  openebs-zfs. Which should be the default `scratchSpaceStorageClass`? Likely the same
  class ch-vmm VM disks use.
- **Network policies:** upstream ships none; defer to a separate `cdi_netpol` module if
  needed.
- **DataImportCron defaults:** consider a separate `cdi_imagestreams` module that
  publishes a curated set of golden images (Ubuntu cloud, Fedora CoreOS, etc.) via
  `DataImportCron` so VMs can reference `sourceRef.kind: DataSource` instead of pulling
  fresh per-VM.
