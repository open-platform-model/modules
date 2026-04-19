# Deployment Runbook — OpenEBS HostPath on lnn1-mrspel

End-to-end steps to ship the changes made in this workstream. No step has been
applied to the cluster yet; the author of the changes deliberately stopped at
the point where a human operator should take over.

Two repositories are involved:

- **larnet** (`/var/home/emil/Dev/larnet`) — Timoni-based infrastructure
  config. Adds the OpenEBS HostPath Timoni bundle to the lnn1-mrspel Talos
  cluster **alongside** the existing Rancher local-path-provisioner.
  `local-path` remains the cluster default StorageClass; `openebs-hostpath`
  becomes a second, opt-in StorageClass.
- **open-platform-model** (`/var/home/emil/Dev/open-platform-model`) —
  scaffolds a new OPM module `modules/openebs/` (v0.1.0, hostpath engine)
  that supersedes the single-purpose `modules/openebs_zfs/`. Not consumed by
  any release in this change — scaffolded for future use.

The two tracks are independent. Track A (larnet) delivers production value
now; Track B (OPM module) is infrastructure for future releases. Deploy Track
A first. Track B only needs publishing when a release wants to consume it.

---

## Change summary

### larnet

| File | Action |
|---|---|
| `infra/bundles/openebs-hostpath.cue` | **New.** `#OpenEBSHostpath` bundle schema wrapping the existing `infra/timoni/modules/openebs-hostpath` module. |
| `infra/config/envs/lnn1-mrspel/config.cue` | **Modified.** Added `openebs-hostpath.yaml` to `talos.patches` list. |
| `infra/config/envs/lnn1-mrspel/bundle_21_openebs_hostpath.cue` | **New.** Instantiates `#OpenEBSHostpath` as a non-default StorageClass. |
| `infra/config/envs/lnn1-mrspel/talconfig.yaml` | **Regenerated.** Now references the additional Talos patch. |

No change to:

- `infra/talos/patches/openebs-hostpath.yaml` — already existed, reused as-is.
- `infra/timoni/modules/openebs-hostpath/` — already existed, reused as-is.
- `infra/config/envs/lnn1-mrspel/bundle_20_storage.cue` — local-path-provisioner
  bundle is untouched.

### open-platform-model

| File | Action |
|---|---|
| `modules/openebs/cue.mod/module.cue` | **New.** CUE module metadata (`opmodel.dev/modules/openebs@v0`). |
| `modules/openebs/module.cue` | **New.** `#config` schema with engine discriminator; hostpath sub-config. |
| `modules/openebs/components.cue` | **New.** `provisioner` Deployment, `provisioner-rbac`, `storageclass`. |
| `modules/openebs/README.md` | **New.** Architecture + config reference. |
| `modules/openebs/TALOS.md` | **New.** Full Talos install guide (prereqs, patch, release, verification). |
| `modules/openebs/DEPLOYMENT_NOTES.md` | **New.** Gotchas and known limitations. |
| `modules/openebs/DEPLOYMENT.md` | **New.** This file. |

No change to `modules/openebs_zfs/` or any `releases/*`.

---

## Pre-flight

Requirements on the operator's workstation:

- `talosctl` matching Talos v1.12.x.
- `talhelper` in `$PATH` (provides `task baremetal:genconfig`).
- `cue` ≥ v0.16.0.
- `task` (go-task).
- `kubectl` configured against the lnn1-mrspel cluster.
- SOPS age private key that can decrypt `infra/config/envs/lnn1-mrspel/secrets.enc.yaml`.
- Network reachability to the node at `192.168.11.224`.

Sanity checks — run before doing anything else:

```bash
# larnet side
cd /var/home/emil/Dev/larnet/infra
task timoni:vet ENV=lnn1-mrspel                       # all bundles valid
task timoni:vet ENV=lnn1-mrspel BUNDLE=openebs_hostpath  # new bundle valid

# OPM side
cd /var/home/emil/Dev/open-platform-model/modules
task fmt
task vet CONCRETE=true
```

Expected: all four commands exit 0. Stop and investigate if any fail.

---

## Track A — Deploy OpenEBS HostPath to lnn1-mrspel

### A1. Regenerate the Talos machine config

```bash
cd /var/home/emil/Dev/larnet/infra
task baremetal:genconfig ENV=lnn1-mrspel
```

Expected output ends with:

```
generated config for lnn1-mrspel-control-plane-1 in config/envs/lnn1-mrspel/clusterconfig/lnn1-mrspel-lnn1-mrspel-control-plane-1.yaml
```

Verify `talconfig.yaml` now lists the patch:

```bash
grep openebs-hostpath config/envs/lnn1-mrspel/talconfig.yaml
# expected: - '@talos/patches/openebs-hostpath.yaml'
```

### A2. Apply the Talos machineconfig

> **Operator action required.** This mutates the node. Make sure no critical
> workload is mid-operation; the kubelet will restart as the config lands.

```bash
cd /var/home/emil/Dev/larnet/infra

talosctl --talosconfig ./config/envs/lnn1-mrspel/clusterconfig/talosconfig \
         apply-config \
         --nodes 192.168.11.224 \
         --file ./config/envs/lnn1-mrspel/clusterconfig/lnn1-mrspel-lnn1-mrspel-control-plane-1.yaml
```

No reboot required — Talos restarts kubelet in-place when `extraMounts`
change. Wait for the node to settle (~30 s).

### A3. Verify the kubelet mount is active

```bash
talosctl --talosconfig ./config/envs/lnn1-mrspel/clusterconfig/talosconfig \
         --nodes 192.168.11.224 \
         read /proc/self/mountinfo | grep openebs
```

Expect a line containing `/var/openebs/local` with `shared:` in its
propagation flags. If absent, the patch did not apply — inspect
`talosctl dmesg` for kubelet complaints.

### A4. Deploy the Timoni bundle

> **Operator action required.** This creates the OpenEBS namespace, Helm
> repository, and HelmRelease.

Dry run first:

```bash
cd /var/home/emil/Dev/larnet/infra
task timoni:apply ENV=lnn1-mrspel BUNDLE=openebs_hostpath DRY_RUN=true
```

Review the planned changes. Then apply for real:

```bash
task timoni:apply ENV=lnn1-mrspel BUNDLE=openebs_hostpath
```

The Helm chart (OpenEBS v4.1.1) deploys the localpv provisioner and a
matching StorageClass. The bundle disables the LVM/ZFS/Mayastor engines
inside the chart — only the hostpath pieces come up.

### A5. Verify

```bash
kubectl -n openebs get pods
# expect one Running pod: <release>-openebs-localpv-provisioner-...

kubectl get sc
# expect both:
#   local-path         (default)
#   openebs-hostpath   (non-default)

kubectl get sc openebs-hostpath -o yaml | grep -E 'provisioner|basePath'
# expect:
#   provisioner: openebs.io/local
#   basePath: /var/openebs/local
```

### A6. Smoke test

Create a PVC + pod to confirm end-to-end provisioning:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openebs-smoke
  namespace: default
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
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox
      command: ["sh", "-c", "echo hello > /data/proof && cat /data/proof && sleep 10"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: openebs-smoke
EOF

kubectl wait --for=condition=Ready pod/openebs-smoke --timeout=2m
kubectl logs openebs-smoke
# expected: hello

kubectl get pv
# expected: one PV with .spec.local.path = /var/openebs/local/pvc-<uid>

# Inspect host path directly
talosctl --talosconfig /var/home/emil/Dev/larnet/infra/config/envs/lnn1-mrspel/clusterconfig/talosconfig \
         --nodes 192.168.11.224 \
         list /var/openebs/local
# expected: a pvc-* subdirectory

# Clean up
kubectl delete pod openebs-smoke
kubectl delete pvc openebs-smoke
```

With `reclaimPolicy: Delete` (the default in this wiring), the host directory
is cleaned up within a few seconds of the PVC being deleted. Verify:

```bash
talosctl --nodes 192.168.11.224 list /var/openebs/local
# expected: empty or no pvc-* entries
```

### A7. Rollback (if needed)

```bash
cd /var/home/emil/Dev/larnet/infra

# Remove the Timoni bundle
task timoni:delete ENV=lnn1-mrspel BUNDLE=openebs_hostpath

# Revert the config.cue change: remove "openebs-hostpath.yaml" from talos.patches
# Revert by deleting bundle_21_openebs_hostpath.cue and editing config.cue
task baremetal:genconfig ENV=lnn1-mrspel
talosctl --talosconfig ./config/envs/lnn1-mrspel/clusterconfig/talosconfig \
         apply-config --nodes 192.168.11.224 \
         --file ./config/envs/lnn1-mrspel/clusterconfig/lnn1-mrspel-lnn1-mrspel-control-plane-1.yaml
```

Any PVs that were using `openebs-hostpath` before rollback will become
unmountable once the provisioner goes away. Migrate or delete them first.

---

## Track B — Publish OPM `openebs` module (optional, future)

No release currently consumes `modules/openebs/`. Publishing is not required
for Track A to work. Publish when a release wants to import it.

### B1. Dry-run publish

```bash
cd /var/home/emil/Dev/open-platform-model/modules
task publish:dry
```

Inspect the output for the `openebs` entry. Version will be `0.1.0` (new
module).

### B2. Publish

Requires registry credentials and the registry running at `localhost:5000`
(or whichever your workspace `CUE_REGISTRY` points at).

```bash
cd /var/home/emil/Dev/open-platform-model/modules
task publish:one MODULE=openebs
```

Publishing is idempotent for unchanged content. Re-publishing after edits
bumps the checksum in `releases/versions.yml` entries that pin the module.

### B3. (Future) Consume from a release

Once Track A has been running happily on lnn1-mrspel for a reasonable period,
the larnet Timoni path can be migrated to an OPM release:

1. Create `releases/lnn1_mrspel/openebs/release.cue` importing
   `opmodel.dev/modules/openebs@v0` with `engine: "hostpath"`.
2. Create `releases/lnn1_mrspel/openebs/values.cue` with
   `hostpath.basePath: "/var/openebs/local"` matching the Talos patch.
3. Apply the release via the OPM delivery pipeline.
4. Remove the Timoni bundle and `openebs-hostpath` bundle file from larnet.

This migration is out of scope for the current change. It is called out here
because the architecture of the OPM module was chosen with this future
migration in mind.

---

## Post-deployment checklist

- [ ] `kubectl -n openebs get pods` shows provisioner Running.
- [ ] `kubectl get sc` shows both `local-path` (default) and `openebs-hostpath`.
- [ ] Smoke PVC (§A6) binds, pod writes successfully, directory appears on host.
- [ ] Smoke PVC deletion cleans up the host directory (Delete reclaim policy).
- [ ] No regression on existing workloads that use the default `local-path` SC.
- [ ] `talconfig.yaml` committed to git with the new patch reference.
- [ ] `bundle_21_openebs_hostpath.cue` + `bundles/openebs-hostpath.cue` committed to git.

---

## Cross-references

- Talos machineconfig details and troubleshooting: [`TALOS.md`](./TALOS.md).
- OPM module config reference: [`README.md`](./README.md).
- Known limitations and gaps: [`DEPLOYMENT_NOTES.md`](./DEPLOYMENT_NOTES.md).
- Planning document that drove this change:
  `/var/home/emil/.claude/plans/1-look-at-larnet-infra-config-envs-lnn1-fizzy-nygaard.md`.
