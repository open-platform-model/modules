# cert_manager

cert-manager X.509 certificate management for Kubernetes, on the OPM v2 line
(`opmodel.dev/modules/cert_manager@v2`, built on `opmodel.dev/catalogs/opm@v2` — the former
`opm_experimental` members now live in the main catalog's `resources/v1alpha1`).

Deploys the cert-manager control plane: controller, webhook, and cainjector Deployments,
all 6 CRDs, the Validating/Mutating webhook configurations (exact names, caBundle injected
at runtime), the webhook Service, the full bound RBAC stack, and the `cert-manager`
namespace. Issuers/Certificates are **not** part of this module (see the separate
cert-manager-config module).

- **Upstream**: https://cert-manager.io
- **GitHub**: https://github.com/cert-manager/cert-manager
- **Default version**: `v1.21.0`

---

## What this module deploys

| Component | Kind | Description |
|---|---|---|
| `namespace` | Namespace | `cert-manager`, exact name, baseline PSS (no privileged labels needed) |
| `crds` | 6 × CustomResourceDefinition | certificates, certificaterequests, issuers, clusterissuers, orders, challenges |
| `controller` | Deployment | Issuance/renewal controller; ACME solver image pinned to the same tag |
| `webhook` | Deployment + Service | Admission webhook; self-managed serving cert (`cert-manager-webhook-ca` Secret); Service `cert-manager-webhook` 443→10250 + metrics 9402 |
| `cainjector` | Deployment | Injects the webhook CA into webhook configs and CRD conversion specs |
| `webhook-validating` / `webhook-mutating` | VWC / MWC | Exact name `cert-manager-webhook`, `inject-ca-from-secret` annotation, **no caBundle** |
| 10 × `*-rbac` | ClusterRole + binding | Exact upstream names incl. `approve:cert-manager-io` and `certificatesigningrequests` (`resourceNames` signer scoping) |
| 3 × `*-role` | Role + binding | Leader-election ×2 (Lease `resourceNames`) and `webhook:dynamic-serving` (CA Secret scoping) |

## Fixes vs the legacy v0 module

The legacy module was transcribed by hand and had drifted from the chart; this port
re-vendors every body from the upstream v1.21.0 static manifest:

- Webhook configs: correct `timeoutSeconds: 30`, MWC rules narrowed to
  `certificaterequests`/CREATE, dropped the bogus `name NotIn [cert-manager]` selector term,
  and replaced the obsolete `inject-apiserver-ca` annotation with
  `inject-ca-from-secret: cert-manager/cert-manager-webhook-ca`.
- The webhook Service is actually emitted (the legacy module never emitted one, breaking
  the webhook clientConfig on any cluster not running the Helm chart in parallel).
- The webhook's 9402 metrics container port is present.

Known expressiveness gaps (accepted): pod-level `seccompProfile: RuntimeDefault`,
`enableServiceLinks: false`, and the `kubernetes.io/os` nodeSelector are dropped;
controller/cainjector metrics Services, the chart's `startupapicheck` post-install hook Job
(with its SA/Role/RoleBinding), and the unbound view/edit/cluster-view aggregation
ClusterRoles are deliberately not emitted.

The controller Deployment renders as `cert-manager-controller`, where upstream names it
`cert-manager` — Deployments are instance-scoped and nothing references that name (the
leader-election Lease name comes from the binary, not the Deployment). The three
ServiceAccounts, the webhook Service, the webhook configurations, and all 13 RBAC objects
do keep their exact upstream names, because those *are* referenced.

Verified by rendering the module and diffing every object against
`helm template cert-manager --version v1.21.0`: RBAC and CRDs are identical, and the only
remaining deltas are the ones listed above.

## ⚠ Instance naming

The webhook configurations' `clientConfig` targets Service `cert-manager-webhook` in
namespace `cert-manager`, and Services/Deployments render as `{instance}-{component}`.
Deploy as an instance named exactly `cert-manager` in namespace `cert-manager`.

## Leader election

The leader-election Roles are emitted into the module instance's namespace, not upstream's
`kube-system`. Keep `#config.leaderElection.namespace` at its default (`cert-manager`).

## Re-vendoring

`crds_data.cue` is generated from `crds/*.yaml` (the CRD documents of the upstream release
manifest): wrap each `cue import`ed file in its `#<group>_<plural>` definition (see the
header comment in `crds_data.cue`). Webhook/RBAC/deployment bodies come from the same
manifest — re-check all of them when bumping `#config.image.tag`.
