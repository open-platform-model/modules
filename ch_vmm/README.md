# ch-vmm

OPM module for [ch-vmm](https://github.com/nalajala4naresh/ch-vmm) — a lightweight Kubernetes add-on for running Cloud Hypervisor virtual machines. This is an alternative to [Virtink](https://github.com/smartxworks/virtink) that similarly targets Cloud Hypervisor instead of QEMU/KVM via libvirt.

Upstream version: **v1.4.0** (APIs are still marked experimental).

See [`CRDS.md`](./CRDS.md) for a reference of the Custom Resources this controller exposes (VirtualMachine, VirtualDisk, VMSet, VMPool, VMSnapShot, and friends).

## What it deploys

| Component | Kind | Purpose |
| --- | --- | --- |
| `crds` | 9 × `CustomResourceDefinition` | `virtualmachines`, `virtualdisks`, `virtualdisksnapshots`, `virtualmachinemigrations`, `vmpools`, `vmrestorespecs`, `vmrollbacks`, `vmsets`, `vmsnapshots` (all `cloudhypervisor.quill.today/v1beta1`) |
| `controller` | `Deployment` + `Service` | `virtmanager-controller-manager` — reconciles VMs, hosts admission webhooks |
| `daemon` | `DaemonSet` + `Service` | `ch-vmm-daemon` — runs on every node, drives Cloud Hypervisor, manages VM pod lifecycle |
| `daemon-config-cm` | `ConfigMap` | gRPC port + TLS paths consumed by the daemon |
| RBAC | 5 × `ClusterRole` + 1 × `Role` | Controller reconciler, controller leader-election, controller metrics-auth, VM editor (aggregating), VM viewer (aggregating), daemon permissions |
| cert-manager objects | 2 × `Issuer` + 2 × `Certificate` | Self-signed Issuers + Certificates for the webhook and daemon TLS material |
| Webhooks | `MutatingWebhookConfiguration` + `ValidatingWebhookConfiguration` | Mutating (5 CR types) and validating (6 CR types) admission entrypoints |

## Prerequisites

The module **does not** bundle these — install them first:

- **cert-manager** — required for the `Issuer` and `Certificate` resources. Use the `cert_manager` module in this workspace.
- **Nodes with `/dev/kvm`** and a kernel ≥ 4.11. IOMMU enabled on the BIOS for GPU passthrough.
- **Optional:** external-snapshotter + CSI driver that supports `VolumeSnapshot` (RBAC is granted, but unused without this).
- **Optional:** CDI operator (`cdi.kubevirt.io`) if consumers want `DataVolume`-based VM disks.

## Quick start

```bash
cd modules/
task check
task publish:one MODULE=ch_vmm
```

Then create a `ModuleRelease` under `releases/<env>/ch_vmm/` referencing the published version. Minimal config override:

```cue
release: {
    module:  "ch_vmm"
    version: "0.1.0"

    config: {
        namespace: "ch-vmm-system"
        controller: {
            replicas: 1
            registryCredsSecret: "registry-credentials"
        }
    }
}
```

## Configuration reference

See `module.cue` for the full `#config` surface. The top-level keys are:

| Field | Default | Purpose |
| --- | --- | --- |
| `controllerImage` | `nalajalanaresh/ch-vmm-controller:v1.4.0` (digest-pinned) | Controller image |
| `daemonImage` | `nalajalanaresh/ch-vmm-daemon:v1.4.0` (digest-pinned) | Per-node daemon image |
| `namespace` | `ch-vmm-system` | Namespace where every non-cluster-scoped object lives |
| `controller.replicas` | `1` | Controller replica count (leader-election-gated) |
| `controller.registryCredsSecret` | `registry-credentials` | Secret used by the controller to pull VM base images |
| `controller.metricsPort` | `8443` | `--metrics-bind-address` port |
| `controller.healthProbePort` | `8081` | `--health-probe-bind-address` port |
| `controller.webhookPort` | `9443` | Container port for the webhook HTTPS server |
| `controller.resources` | `10m/64Mi` → `500m/128Mi` | Controller resource requests/limits |
| `daemon.grpcPort` | `8443` | gRPC port for controller → daemon traffic |
| `daemon.resources` | unset | Optional daemon resource requests/limits |
| `certificates.duration` | `2160h` (90d) | Cert validity |
| `certificates.renewBefore` | `360h` (15d) | Renewal window |

## Relation to Virtink and KubeVirt

- **Virtink** (smartxworks): canonical Cloud Hypervisor add-on, broader adoption, more mature.
- **ch-vmm** (this module): smaller/newer, Kubebuilder-based, experimental APIs.
- **KubeVirt 1.8+**: historically KVM/QEMU-only; added a Hypervisor Abstraction Layer (HAL) in March 2026 that allows Cloud Hypervisor as an alternate backend.

Pick ch-vmm if you want a minimal Cloud Hypervisor controller surface. For production use Virtink or KubeVirt (with HAL).
