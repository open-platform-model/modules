# LINSTOR (Piraeus) module

Replicated/distributed block storage for Kubernetes, built on
[LINSTOR](https://linbit.com/linstor/) + DRBD and deployed by the
[Piraeus operator](https://github.com/piraeusdatastore/piraeus-operator).

Pinned to **piraeus-operator v2.10.7** (LINSTOR v1.33.3, linstor-csi v1.11.2).

## Packaging model (hybrid — read this first)

This module deliberately owns only two things:

| Owned by this OPM module | Owned by the release `bootstrap/` dir |
| --- | --- |
| The 4 `piraeus.io` CRDs (`crds` component) | Operator runtime: controller-manager + gencert Deployments, validating webhook + Service, `image-config` ConfigMap, RBAC, Namespace |
| One `linstor.csi.linbit.com` StorageClass per `#config.storageClasses` entry (one component per key) | `LinstorCluster` + `LinstorSatelliteConfiguration` config CRs (incl. the storage-pool definitions) |

**Why split?** The Piraeus operator install ships a runtime TLS cert-generator,
a fail-closed `ValidatingWebhookConfiguration`, and a 250-line `image-config`
ConfigMap that pins ~13 downstream image versions — all tightly coupled to each
operator release. Re-typing that immutable, upstream-maintained plumbing into
CUE adds a recurring re-translation tax for no benefit, so it is applied from
the pinned upstream `manifest.yaml`. The config CRs live in `bootstrap/` because
OPM has no native arbitrary custom-resource primitive yet (RFC-0002); when that
lands they can fold into this module.

The CRDs are **not** double-managed: the `bootstrap/` operator manifest has its
CRD documents stripped, so this module is the single owner of the CRDs.

## What it deploys

- **CRDs:** `LinstorCluster`, `LinstorNodeConnection`,
  `LinstorSatelliteConfiguration`, `LinstorSatellite` (group `piraeus.io`).
  Vendored trimmed (`x-kubernetes-preserve-unknown-fields`); structural
  validation is enforced by the operator's admission webhook.
- **StorageClasses:** one per `#config.storageClasses` entry, provisioner
  `linstor.csi.linbit.com`, each with its own storage pool / replica placement
  count / DRBD layer stack / filesystem.

## Configuration (`#config.storageClasses`)

`storageClasses` is a map — one `linstor.csi.linbit.com` StorageClass is emitted
per entry. The map **key** becomes the StorageClass name suffix: the OPM
transformer names each rendered resource `<release-name>-<key>`. So on the
`linstor` release, key `storage` → `linstor-storage`, key `nvme` → `linstor-nvme`.
PVCs reference those names. At most one entry should set `isDefault: true`.

Each entry (`#storageClassConfig`) takes:

| Field | Default | Notes |
| --- | --- | --- |
| `storagePool` | `zfspv-pool` | Must match the pool on the satellites (see `bootstrap/`) |
| `placementCount` | `1` | Replica count. **1** on a single node — no replication until ≥2 nodes |
| `layerList` | `drbd storage` | `drbd storage` = DRBD on backend; `storage` = plain, no DRBD |
| `allowRemoteVolumeAccess` | `false` | Diskless network attach; keep `false` single-node |
| `fsType` | `ext4` | `ext4` or `xfs` |
| `isDefault` | `false` | Set the cluster default StorageClass |
| `reclaimPolicy` | `Retain` | `Retain` or `Delete` |
| `volumeBindingMode` | `WaitForFirstConsumer` | Local affinity |
| `allowVolumeExpansion` | `true` | |

## Deploy order

The StorageClass is validated by the operator's `vstorageclass.kb.io` webhook,
so the **operator runtime must be up first**:

1. `kubectl apply --server-side -f bootstrap/operator-v2.10.7.yaml`
2. Apply this module's release (creates CRDs + StorageClasses). CRDs can also be
   applied before the operator; the StorageClasses must follow the operator.
3. `kubectl apply -f bootstrap/linstorcluster.yaml -f bootstrap/talos-loader-override.yaml -f bootstrap/storage-pool.yaml`
4. Verify: `kubectl -n piraeus-datastore get pods`, then
   `linstor node list` / `linstor storage-pool list` via the controller pod.

See the release `bootstrap/README.md` for the gon1-nas2 specifics (Talos + ZFS
pools `linstor-pool` / `nvme-pool`).

## Validate

```bash
cd modules && task fmt && task vet CONCRETE=true
```

## Upgrading Piraeus

1. Pull the new `manifest.yaml`; strip the 4 CRD documents → refresh
   `bootstrap/operator-vX.Y.Z.yaml`.
2. Re-extract the CRD metadata into `crds_data.cue` (group/names/scope/version
   are stable across v2.x — usually no change).
3. Bump the pinned-version notes in `module.cue` / this README.
