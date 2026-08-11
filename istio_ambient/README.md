# istio_ambient

Istio **ambient mesh** control plane, transcribed from the official `ambient` umbrella chart onto the
OPM v2 catalog line (`opmodel.dev/catalogs/opm@v2` + `opmodel.dev/core@v2`, module path
`opmodel.dev/modules/istio_ambient@v2`; the former `opm_experimental` members now live at
`resources/v1alpha1` inside the main catalog).

Deploys istiod, the istio-cni node agent and ztunnel, the 15 Istio CRDs, both validating webhook
configurations and the sidecar injector, the full RBAC stack, and the mesh / CNI / injector
ConfigMaps.

- **Upstream**: https://istio.io
- **Chart**: https://artifacthub.io/packages/helm/istio-official/ambient
- **Default version**: `1.30.3` (Gateway API CRDs vendored at `v1.5.1`)

---

## Where the chart actually lives

The `ambient` chart looks sourceless because its tarball is published under `charts/samples/` rather
than `charts/`. It is `istio/istio` → `manifests/sample-charts/ambient/`, and it is **two files with
no templates**: a `Chart.yaml` with four `file://` dependencies and a 12-line `values.yaml`.

Its output is provably identical to rendering `base` + `cni` + `istiod` + `ztunnel` individually with
`profile=ambient, global.variant=distroless` — verified by render diff. Those four subcharts are the
real source, and they are fully documented. Re-vendor `crds/` and the injector blobs when bumping
`#config.image.tag`.

## What this module deploys

At upstream defaults this renders **45 objects**; with every flag on, **60**.

| Component | Kind | Description |
|---|---|---|
| `namespace` | Namespace | `istio-system`, exact name, PSS **privileged** (the chart never creates it — see below) |
| `crds` | 15 × CustomResourceDefinition | The Istio API surface |
| `crds-gatewayapi` | 8 × CustomResourceDefinition | Gateway API standard channel — **off by default**, not in the chart at all. Requires `catalog_opm` ≥ `v1.0.0-alpha.5`: `gateway.networking.k8s.io` is a protected group, so these CRDs are rejected without the `api-approved.kubernetes.io` annotation, and because a ModuleInstance applies atomically that failure takes down the whole mesh with it |
| `config` | 3 × ConfigMap | `istio` (mesh), `istio-cni-config` (agent env), `istio-sidecar-injector` (templates + values) — all exact names |
| `gatewayclass-config` | ConfigMap | Per-GatewayClass default overlays; empty at defaults |
| `istiod` | Deployment + Service + SA + HPA | The control plane. Optionally PodDisruptionBudget and NetworkPolicy |
| — | 3 × NetworkPolicy | One per workload (istiod, istio-cni, ztunnel) behind `networkPolicy.enabled` — **off by default**, matching the chart |
| `istio-cni` | DaemonSet + SA | Node agent, **exact name `istio-cni-node`** |
| `ztunnel` | DaemonSet + SA | The ambient L4 dataplane |
| `istio-reader-sa` | ServiceAccount | `istio-reader-service-account` |
| 6 × `*-rbac` | ClusterRole + binding | Rule counts 24/5/11/1/2/2; `istio-cni-ambient` scopes with `resourceNames: ["istio-cni-node"]` |
| `istiod-role` | Role + RoleBinding | Namespace-scoped istiod permissions |
| `injector-webhook` | MutatingWebhookConfiguration | `istio-sidecar-injector`, 4 entries, `failurePolicy: Fail` |
| `validating-webhooks` | 2 × ValidatingWebhookConfiguration | `istio-validator-istio-system` and `istiod-default-validator`, both `Ignore`, **no `caBundle`** — istiod patches them by name at runtime |
| `stable-validation-policy` | ValidatingAdmissionPolicy + Binding | CEL enforcement of the stable API channel — **off by default** |

## Verification

Rendered and diffed against `helm template istio istio/ambient --version 1.30.3`. **All three pod
specs — istiod, istio-cni-node and ztunnel — are byte-identical to upstream**: image, command, args,
env names *and* values, volume mounts and paths, volume sources, securityContext, probes, ports,
tolerations, nodeSelector and priorityClassName. RBAC rule counts, both validators, the 4-entry
injector and all three ConfigMaps match exactly.

Deliberate deltas, all of them additive or structural:

- **No debug `values` ConfigMap.** The chart emits one; it is self-described as a debug artifact.
- **Plus a Namespace**, plus the Gateway API CRDs when enabled.
- **No `revisionTags`** — see "Out of scope".
- `metadata.labels` differ wholesale: OPM stamps its own label set, and the CRD transformer emits
  only `#context.labels`, so CRD labels can never match upstream's. CRD **annotations**, by contrast,
  are carried through verbatim from the vendored source — including the Istio CRDs'
  `helm.sh/resource-policy: keep`, which is inert outside Helm but kept for fidelity.
- `spec.selector.matchLabels` is OPM's 4-key `componentLabels`, not upstream's `{istio: pilot}`.
- `+ restartPolicy: Always`, `+ imagePullPolicy`, `+ automountServiceAccountToken` — OPM emits these
  unconditionally.
- `− replicas` on the istiod Deployment while autoscaling is on. This is deliberate: emitting
  `replicas` alongside an HPA causes a permanent server-side-apply tug-of-war on every re-apply.

## ⚠ This module is NOT instance-safe

The istiod Service, the CNI DaemonSet and every RBAC object render under **exact upstream names**,
because those names are load-bearing:

- **`istiod`** (Service) — `discoveryAddress`, ztunnel's XDS/CA defaults and every webhook
  `clientConfig.service.name` hard-code it.
- **`istio-cni-node`** (DaemonSet) — `cni/pkg/plugin/plugin.go` matches
  `strings.HasPrefix(podName, "istio-cni-node-")` as the failsafe that lets the *replacement* agent
  pod through when the plugin cannot reach the API server.

**Deploy exactly one instance per cluster**, in the namespace named by `#config.namespace.name`.

## ⚠ No in-place migration from a Helm-installed mesh

`spec.selector.matchLabels` is **immutable** in Kubernetes and OPM's differs from the chart's.
Adopting an existing Helm-installed mesh therefore means **deleting and recreating** `istiod`,
`istio-cni-node` and `ztunnel` — there is no rolling path.

Deleting `istio-cni-node` is **the one genuinely dangerous step**. The CNI plugin only lets its own
replacement pod through because that pod's name starts with `istio-cni-node-`; while no agent is
running, pod creation on that node can block. **Recreate on a drained node**, or accept a window with
no CNI agent.

## Namespace and Pod Security

The chart never creates the namespace. This module does, because istio-cni and ztunnel violate
baseline Pod Security and the `pod-security.kubernetes.io/{enforce,audit,warn}: privileged` labels
must be in place *before* the DaemonSets are admitted. On clusters where the namespace is managed
out-of-band (Talos/larnet-infra pre-creates it), set `namespace.create: false` — the module still
adopts it via server-side apply.

## Configuration

Ambient's defining settings are **hard-locked in the components, not exposed in `#config`**: a
deployment with `PILOT_ENABLE_AMBIENT`, `CA_TRUSTED_NODE_ACCOUNTS`, the HBONE proxy metadata or the
distroless variant flipped is simply broken rather than differently configured.

What `#config` does expose: `image.{hub,tag,pullPolicy}`, `namespace.{name,create}`,
`mesh.{clusterName,network,meshID,trustDomain}`, `pilot.{replicas,autoscale,pdb,resources,traceSampling,env}`, `cni.{logLevel,binDir,confDir,chained,repair,resources}`,
`ztunnel.{logLevel,resources}`, `networkPolicy.enabled`, `gatewayAPI.enabled`, `gatewayClasses` and
`experimental.stableValidationPolicy`.

`cni.binDir`/`cni.confDir` default to `/opt/cni/bin` and `/etc/cni/net.d`, which are correct for
Talos and most distributions; k3s and GKE need overrides.

## NetworkPolicy

`networkPolicy.enabled` emits a policy for **each** of the three workloads, mirroring the chart's
single `global.networkPolicy.enabled` switch rather than inventing three flags upstream doesn't have.
Ingress rules and ports are transcribed from the chart; egress is allow-all (one empty rule) on all
three, because each reaches endpoints that cannot be enumerated — the API server, DNS, and for istiod
user-supplied JWKS URLs.

Two things worth knowing:

- Each policy's `podSelector` is **derived** by the transformer from the workload's own rendered pod
  labels, so it cannot drift from the pods it protects. Verified in the render: all three selectors
  are byte-identical to their workload's `spec.selector.matchLabels`.
- An empty egress rule means *allow-all*, but naming `Egress` in `policyTypes` with **no** rules is a
  *deny-all*. Losing that rule inverts the policy rather than relaxing it, so the module asserts it
  survives.

Requires `catalog_opm` ≥ `v1.0.0-alpha.6`. Earlier versions shipped `#NetworkPolicyTrait` only in
`catalog_opm_experimental`, from where it **could not be attached at all**: a blueprint's
`spec: close({_allFields})` rejects a field contributed by a trait from a *foreign* CUE module.
`tr.#DisruptionBudget` always worked because it ships alongside the blueprint.

## Out of scope for v1.0.0

- **`revisionTags`** — renders an extra MutatingWebhookConfiguration *and* a second Service for the
  same istiod pods, which `#ExposeSchema` (one Service per component) cannot express. More
  importantly the real canary flow needs a second istiod at a different revision, which under OPM is
  a second module instance rather than a config flag — shipping only the render half would give a
  feature that cannot be used correctly.
- Remote istiod, multi-cluster, external CA, the openshift/GKE/k3s platform profiles, and the sidecar
  (non-ambient) data path.

## Re-vendoring

`crds_istio_data.cue`, `crds_gatewayapi_data.cue`, `injector_data.cue` and `injector_values_data.cue`
are **generated — do not hand-edit**. Sources live in `crds/`.

```bash
cue import -f -p istio_ambient -l '"_istioCRDs"' -l 'metadata.name' \
  -o crds_istio_data.cue crds/istio-crds.yaml
```

Two gotchas that cost real time:

- `cue import -l '"_x"'` emits a **quoted** label. `"_x"` is *not* hidden — only bare `_x` is — so the
  field violates `#Module` closedness and must be unquoted afterwards.
- `yq -N` strips the `---` separators; don't use it when writing these files back.

The injector `values` blob is vendored as a base with the `#config`-owned fields projected over it,
rather than generated from scratch: a template referencing a key we forgot to emit fails at
*injection* time in the cluster, not at render time. Guards in `components_config.cue` assert both
that the projection overrides and that it preserves every other key.
