# LINSTOR module — deployment notes

Running log of issues/decisions discovered while deploying this module.

## Design

- **Hybrid packaging** (see README). Operator runtime + config CRs are applied
  from `bootstrap/` in the release; this module owns CRDs + StorageClass only.
  Rationale: the operator carries a runtime cert-gen Deployment, a fail-closed
  validating webhook, and a version-pinned `image-config` ConfigMap that are
  coupled to each operator release.

## Talos prerequisites (the part most likely to bite)

LINSTOR needs the **DRBD kernel module** on every node. On Talos:

1. Bake the `siderolabs/drbd` system extension into the image via
   `factory.talos.dev` (same mechanism as `siderolabs/zfs`). drbd 9.2.16 ships
   in the Talos v1.12.x extensions set.
2. Load the modules via machine config:
   ```yaml
   machine:
     kernel:
       modules:
         - name: drbd
           parameters: ["usermode_helper=disabled"]
         - name: drbd_transport_tcp
   ```
   ZFS-backed pools also need the `zfs` module (already present via the zfs
   extension); LVM-thin pools need `dm-thin-pool`.
3. Apply the **mandatory** `talos-loader-override` `LinstorSatelliteConfiguration`
   (`bootstrap/talos-loader-override.yaml`): Talos has no systemd, an immutable
   root, and the DRBD module is already loaded — so the operator's default
   `drbd-shutdown-guard` / `drbd-module-loader` init containers and the
   systemd/lib-modules/usr-src volumes must be `$patch: delete`d, and LVM
   backup/archive redirected to `/var/etc/lvm/*` (`/etc/lvm` is read-only).
4. Exempt the operator namespace (`piraeus-datastore`) from PodSecurity (the
   satellites run privileged), same as the `openebs` namespace exemption.

Verify the module is loaded: `talosctl -n <node> read /proc/modules | grep drbd`.

## Single-node caveat (gon1-nas2)

DRBD replication needs ≥2 nodes. On a single node, `placementCount: 1` and
volumes are local-only — no replication benefit over OpenEBS ZFS LocalPV. The
DRBD layer is still exercised (single replica) for forward-compatibility with a
future multi-node cluster.

## CRD trimming

The vendored CRDs use `x-kubernetes-preserve-unknown-fields: true` rather than
the full ~2,200-line upstream OpenAPI. This is safe because the operator's
admission webhook (`vlinstorcluster.kb.io`, etc.) validates the real structure.
If the operator is ever installed without its webhook, CR specs would be
unvalidated by the apiserver.
