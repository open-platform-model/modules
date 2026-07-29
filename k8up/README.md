# k8up

K8up restic-based backup operator for Kubernetes, ported to the OPM v1 catalog line
(`opmodel.dev/catalogs/opm@v1`). Replaces the `v0_legacy` module published as
`opmodel.dev/modules/k8up@v1`.

Deploys the operator, all 9 CRDs, and the four upstream ClusterRoles. After deployment you
declare backup policy per application with `Schedule` / `PreBackupPod` CRs — those are
deliberately **not** part of this module (see below).

- **Upstream**: https://k8up.io
- **GitHub**: https://github.com/k8up-io/k8up
- **Default version**: operator `v2.16.0`, transcribed from chart `k8up-4.10.0`

---

## What this module deploys

| Component | Kind | Description |
|---|---|---|
| `crds` | 9 × CustomResourceDefinition | Archive, Backup, Check, PodConfig, PreBackupPod, Prune, Restore, Schedule, Snapshot — full upstream schemas |
| `operator` | Deployment + ServiceAccount + Service | The controller-manager, its identity, and the metrics Service |
| `manager-cluster-role` | ClusterRole + binding | What the operator itself may do |
| `executor-cluster-role` | ClusterRole + binding | What a spawned backup Job may do; the operator RoleBinds it per namespace |
| `edit-cluster-role` | ClusterRole + binding | Aggregates into the built-in `admin` and `edit` roles |
| `view-cluster-role` | ClusterRole + binding | Aggregates into the built-in `view` role |

No Namespace component: the operator is an ordinary non-root Deployment that the `baseline`
Pod Security Standard admits, so there is no PSS labelling for the module to own.

## No backup CRs

This module emits no `Schedule`, `Backup` or `PreBackupPod` instances. They are per-application
policy, they reference restic/S3 credential Secrets, and the core catalog has no backup
primitive — so they are applied separately, exactly as MetalLB's address pools are. Making them
declarative would mean a k8up **provider catalog** with typed `#Schedules` / `#PreBackupPods`
primitives, since the semantics are k8up-shaped rather than generic.

## Deviations from the upstream chart

Everything below was found by rendering the module and diffing against
`helm template k8up k8up/k8up --version 4.10.0`. All four ClusterRoles are rule-for-rule
identical to that output, and all 9 CRDs match their source manifests exactly.

1. **Four ClusterRoleBindings instead of one.** `#RoleSchema.subjects` is required and
   non-empty, so this catalog cannot express an unbound ClusterRole. Upstream binds only
   `k8up-manager` and leaves `k8up-executor` (bound at runtime by the operator to each
   executor's ServiceAccount) plus the aggregation-only `k8up-edit` / `k8up-view` unbound.
   **Consequence:** the operator ServiceAccount gains `pods/exec` cluster-wide via
   `k8up-executor`, which upstream does not grant it. Tracked for a catalog fix (optional
   `subjects` on `#Role`).
2. **Metrics Service is `{instance}-{component}`**, so an instance named `k8up` yields
   `k8up-operator`; the chart calls it `k8up-metrics`. Scrape configs must target the
   rendered name.
3. **No `strategy` on the Deployment.** The module declares `updateStrategy: RollingUpdate`,
   but `deployment_transformer.cue` builds `_updateStrategy: *null | {…}` with `null` as the
   marked default, so no Deployment this catalog renders carries a strategy. Harmless — the
   API server defaults to exactly RollingUpdate 25%/25%.
4. **No cleanup Job.** The chart's `pre-delete` Helm hook (which strips k8up finalizers on
   uninstall) has no OPM equivalent and is not needed; the operator's pruner handles removal.
5. **Container hardening added.** `allowPrivilegeEscalation: false` and `capabilities.drop:
   [ALL]` — the chart's `securityContext` values knob used, not a deviation from it.
   `readOnlyRootFilesystem` is left off (upstream never asserts it). The pod still does not
   satisfy the `restricted` PSS: that also requires `seccompProfile: RuntimeDefault`, which
   `#SecurityContextSchema` cannot express.

## Fixes relative to the v0 legacy module

The bodies here come from the chart, not from the legacy module, whose transcription had
drifted:

- **`BACKUP_IMAGE` was missing entirely.** Executor Jobs fell back to k8up's built-in default
  and could run a different version from the operator scheduling them. Now derived from
  `backupImage`, defaulting to the operator image.
- **`BACKUP_OPERATOR_NAMESPACE` was emitted as a literal empty string** and documented as a
  watch-scope switch ("empty means cluster-wide"). It is neither: it selects where
  EffectiveSchedules are stored, and upstream fills it from the downward API. K8up always
  reconciles cluster-wide.
- **Manager ClusterRole was both too broad and too narrow.** It granted `secrets`,
  `namespaces` and rbac `roles` that upstream does not, left `clusterroles … bind` unscoped
  (upstream restricts it to `resourceNames: [k8up-executor]`, which is what keeps `bind` from
  being an escalation path), and omitted every `/finalizers` subresource plus
  `effectiveschedules`.
- **Executor ClusterRole granted `clusterrolebindings` (full CRUD), PVC reads, secret reads
  and `*/status` writes** that upstream does not include.
- **CRDs carried no real schema** — every one was collapsed to
  `x-kubernetes-preserve-unknown-fields: true`, so the API server accepted any Schedule body.
  All 9 now ship their full upstream `openAPIV3Schema`.
- **`BACKUP_METRICS_PORT` and the invented `OPERATOR_NAME` / `OPERATOR_NAMESPACE` env vars**
  are gone; the chart sets none of them and the container port is fixed at 8080.

## ⚠ Applying the CRDs by hand needs `--server-side`

`podconfigs.k8up.io` and `prebackuppods.k8up.io` both embed a full PodSpec and exceed 256 KiB.
A client-side `kubectl apply -f` stores the whole object in the
`kubectl.kubernetes.io/last-applied-configuration` annotation and the API server rejects it:

```
metadata.annotations: Too long: may not be more than 262144 bytes
```

The opm-operator applies with server-side apply (field manager `opm-controller`), so the
normal deployment path is unaffected. Only ad-hoc `kubectl apply` needs `--server-side`.

## Configuration

| Key | Default | Notes |
|---|---|---|
| `image` | `ghcr.io/k8up-io/k8up:v2.16.0` | Operator image; `crds_data.cue` is vendored to match |
| `backupImage` | same as `image` | Passed as `BACKUP_IMAGE` to executor Jobs |
| `replicas` | `1` | Followers are hot standby; leader election picks one active |
| `timezone` | `""` | Interprets Schedule cron expressions; empty uses the node's zone |
| `enableLeaderElection` | `true` | |
| `skipWithoutAnnotation` | `false` | Ignore PVCs without `k8up.io/backup` |
| `skipSnapshotSync` | `false` | New in v2.16.0 |
| `operatorNamespace` | `""` | Where EffectiveSchedules live; empty → own namespace via downward API |
| `globalResources` | all `""` | Default requests/limits stamped on every spawned Job |
| `resources` | *(unset)* | Operator container requests/limits |
| `serviceAccountName` | `"k8up"` | Also the subject of all four ClusterRoles |
| `metrics.port` / `metrics.serviceType` | `8080` / `ClusterIP` | Service port only — the container port is fixed at 8080 |
| `extraEnv` | *(unset)* | Upstream's `k8up.envVars` escape hatch |
| `podScheduling` / `podMetadata` | *(unset)* | nodeSelector/tolerations/priorityClass; pod labels+annotations |

### Referencing a pre-existing Secret from `extraEnv`

Use the `#SecretK8sRef` form (`secretName` + `remoteKey`) to point at a Secret provisioned
outside the module — it wires a `secretKeyRef` to that exact name and emits nothing. The
`#SecretLiteral` form (`value`) instead makes OPM create the Secret under the instance-prefixed
name `{instance}-{$secretName}`, which cannot address a pre-existing object.

```cue
extraEnv: BACKUP_GLOBALACCESSKEYID: {
    name: "BACKUP_GLOBALACCESSKEYID"
    from: {
        $secretName: "global-s3-credentials"
        $dataKey:    "access-key-id"
        secretName:  "global-s3-credentials"
        remoteKey:   "access-key-id"
    }
}
```

## Re-vendoring CRDs

```sh
curl -sL -O https://github.com/k8up-io/k8up/releases/download/k8up-<chart-version>/k8up-<chart-version>.tgz
tar xzf k8up-<chart-version>.tgz
cp k8up/crds/*.yaml modules/k8up/crds/

cd modules/k8up
for f in crds/*.yaml; do
  plural=$(basename "$f" .yaml); plural=${plural#k8up.io_}
  cue import -f -p k8up -l "#k8up_io_${plural}:" -o "/tmp/crd_${plural}.cue" "$f"
done
# concatenate into crds_data.cue under the existing header, then:
cue fmt ./... && cue vet -c ./...
```
