# sealed-secrets

OPM module that deploys the [Bitnami sealed-secrets controller](https://github.com/bitnami-labs/sealed-secrets).
SealedSecret custom resources carry asymmetrically-encrypted Kubernetes Secrets.
The controller holds the private key and decrypts them in-cluster, so the
encrypted manifest is safe to commit to git.

- **App version:** 0.36.6
- **CRD:** `SealedSecret` (`bitnami.com/v1alpha1`)
- **Default namespace:** `sealed-secrets`
- **Image:** `docker.io/bitnami/sealed-secrets-controller:0.36.6`

## Architecture

Five components, each emitted as one or more Kubernetes objects:

| Component              | Kind(s)                                    | Scope     |
| ---------------------- | ------------------------------------------ | --------- |
| `crds`                 | CustomResourceDefinition                   | cluster   |
| `controller`           | ServiceAccount + Deployment + 2 Services   | namespace |
| `secrets-unsealer-rbac`| ClusterRole + ClusterRoleBinding           | cluster   |
| `key-admin-rbac`       | Role + RoleBinding                         | namespace |
| `leader-election-rbac` | Role + RoleBinding *(only if HA enabled)*  | namespace |
| `service-monitor`      | ConfigMap *(only if monitoring enabled)*   | namespace |

The controller runs a single pod with a read-only root filesystem and
an emptyDir at `/tmp` for transient key-generation files.

## Quick Start

Minimal ModuleRelease pinning the default namespace and enabling Prometheus
scraping:

```cue
spec: {
    moduleRef: { name: "sealed-secrets", version: "v0.1.0" }
    config: {
        monitoring: {
            enabled: true
            additionalLabels: "prometheus": "kube-prometheus"
        }
    }
}
```

Apply with `opm` or your ModuleRelease operator of choice. On first start the
controller auto-generates a 4096-bit RSA key pair and stores it as a Secret
labelled `sealedsecrets.bitnami.com/sealed-secrets-key=active` in the
controller namespace.

## Creating sealed secrets

```bash
# Fetch the controller's public certificate
kubeseal --fetch-cert \
  --controller-namespace sealed-secrets \
  --controller-name sealed-secrets-controller \
  > pub-cert.pem

# Seal a Secret manifest
kubectl create secret generic db-password \
  --from-literal=password=hunter2 \
  --dry-run=client -o yaml |
kubeseal --cert pub-cert.pem -o yaml > db-password.sealed.yaml

# Commit db-password.sealed.yaml to git, apply via git-ops
```

## Key management

- The controller rotates signing keys every `controller.keyRenewPeriod`
  (default `720h` / 30 days). Old keys are retained so already-sealed
  secrets keep decrypting.
- Set `controller.keyCutoffTime` to an RFC3339 timestamp to force rotation
  of any key older than that point on the next reconcile — useful for
  compromise response.
- **Back up the key Secrets out of band.** Losing them means every
  SealedSecret in git becomes undecryptable:

  ```bash
  kubectl get secret -n sealed-secrets \
    -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o yaml > sealed-secrets-keys.backup.yaml
  ```

  Store the backup in a secrets vault (1Password, Vault, SOPS-encrypted
  git). This step is deliberately not automated — the encrypted backup
  is operator responsibility.

## Configuration reference

### `image`

Container image for the controller.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `repository` | string | `docker.io/bitnami/sealed-secrets-controller` | |
| `tag`        | string | `0.36.6` | Upstream tags drop the leading `v`. |
| `digest`     | string | `""` | Optional SHA256 digest. |
| `pullPolicy` | enum | `IfNotPresent` | From `schemas.#Image`. |

### `controller`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `replicas` | int | `1` | Keep at 1 unless `highAvailability.enabled`. |
| `logLevel` | enum | `info` | `info` / `debug` / `warn` / `error`. |
| `logFormat` | enum | `json` | `json` / `text`. |
| `keyRenewPeriod` | duration | `720h` | Pass `"0"` to disable rotation. |
| `keyTTL` | duration | `87600h` | 10 years — cert validity for new keys. |
| `keyPrefix` | string | `sealed-secrets-key` | Prefix for key Secret objects. |
| `keyCutoffTime` | RFC3339 | — | Force-rotate keys older than this. |
| `additionalNamespaces` | `[...string]` | — | Extra namespaces to watch. |
| `updateStatus` | bool | `true` | Populate SealedSecret.status. |
| `watchForSecrets` | bool | `false` | Reconcile on external Secret edits. |
| `maxUnsealRetries` | int | `3` | |
| `kubeclientQPS` / `kubeclientBurst` | int | `20` / `30` | Raise on large clusters. |
| `resources` | `#ResourceRequirementsSchema` | — | Optional. |

### `service`

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `httpPort`    | port | `8080` | kubeseal API + `/healthz`. |
| `metricsPort` | port | `8081` | Prometheus `/metrics`. |

### `monitoring`

Prometheus Operator integration. Off by default. The ServiceMonitor is
carried as JSON inside a ConfigMap for deployment tooling to extract —
the OPM catalog does not model `monitoring.coreos.com` CRDs directly.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | |
| `scrapeInterval` | duration | `30s` | |
| `namespace` | string | `""` | Empty = controller namespace. |
| `additionalLabels` | `{[string]: string}` | `{}` | Target labels for Prometheus CR. |

### `highAvailability`

Experimental. Upstream hard-codes `replicas: 1` and ships leader election
as opt-in. Flipping this on wires the CLI flags and the lease Role, but
does **not** modify the upstream binary — confirm the version you deploy
actually honours `--leader-elect`. Verified from v0.22.0 onwards.

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | |
| `leaseName` | string | `sealed-secrets-controller` | |
| `pdbMinAvailable` | int | `1` | Reserved for future PDB wiring. |

## Security posture

- `runAsNonRoot: true`, UID `1001`, `fsGroup: 65534`.
- `readOnlyRootFilesystem: true`; `/tmp` is an emptyDir.
- `allowPrivilegeEscalation: false`; `capabilities.drop: [ALL]`.
- `automountServiceAccountToken: true` (controller calls kube-apiserver).

**Known gap vs upstream:** the OPM `SecurityContext` schema does not
model `seccompProfile`. Upstream sets `RuntimeDefault` at pod level; the
provider applies the cluster default. If your cluster enforces a stricter
profile via PodSecurity admission this may need explicit wiring.

**Not deployed:** the optional `sealed-secrets-service-proxier` Role +
RoleBinding that upstream uses to grant `system:authenticated` group
access to `services/proxy`. OPM RBAC subjects currently only accept
ServiceAccount references, not Kubernetes Groups. `kubeseal --fetch-cert`
still works via direct kubectl Service access for users whose existing
RBAC allows it, or via port-forward:

```bash
kubectl port-forward -n sealed-secrets svc/sealed-secrets-controller-http 8080
kubeseal --cert http://localhost:8080/v1/cert.pem ...
```

## Upgrading

Bump `image.tag` to the target upstream release. The controller handles
the key Secret format compatibly across all v0.x releases. CRD schema
changes ship with controller releases — re-publish this module whenever
the CRD updates so `crds_data.cue` stays in sync.

## References

- Upstream: <https://github.com/bitnami-labs/sealed-secrets>
- Controller flags: <https://github.com/bitnami-labs/sealed-secrets/blob/main/docs/developer.md>
- CRD source: `controller.yaml` in each GitHub release
