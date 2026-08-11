# metallb

MetalLB bare metal load-balancer for Kubernetes, on the OPM v2 line
(`opmodel.dev/catalogs/opm@v2` + `opmodel.dev/core@v2`; module path
`opmodel.dev/modules/metallb@v2`).

Deploys the MetalLB controller and speaker alongside all required CRDs, cluster-wide RBAC,
and the `metallb-system` namespace (exact name, PSS-privileged labels). After deployment,
configure MetalLB by creating `IPAddressPool` and advertisement CRs in the same namespace —
pools are deliberately **not** part of this module.

- **Upstream**: https://metallb.io
- **GitHub**: https://github.com/metallb/metallb
- **API reference**: https://metallb.universe.tf/apis/
- **Default version**: `v0.16.1`

---

## What this module deploys

| Component | Kind | Description |
|---|---|---|
| `namespace` | Namespace | `metallb-system`, exact name, all three PSS labels `privileged` (speaker violates baseline PSS) |
| `crds` | 9 × CustomResourceDefinition | All MetalLB CRD types, vendored from upstream v0.16.1 |
| `controller` | Deployment | IP address assignment controller (`--webhook-mode=disabled`) |
| `speaker` | DaemonSet | Per-node L2 announcement daemon (hostNetwork, root, NET_RAW) |
| `controller-rbac` / `controller-role` | ClusterRole/Role + bindings | Controller permissions (memberlist Secret + Deployment scoped via `resourceNames`) |
| `speaker-rbac` / `speaker-role` | ClusterRole/Role + bindings | Speaker permissions (memberlist Secret scoped; controller SA is a second subject on the role binding) |

The speaker's memberlist gossip key is modeled in-module (`speaker.memberlistKey`) and rendered
as the Secret `{instance}-speaker-memberlist`.

## v0.16.1 notes (vs the legacy v0.15.3 module)

- Metrics are HTTPS-only on port **9120** (port name `metricshttps`); the old 7472 port and the
  controller's unused 9443 webhook port are gone.
- Controller liveness/readiness probes hit `/healthz` / `/readyz` on **17472**. Speaker probes
  are omitted: upstream probes them via `host: 127.0.0.1`, which the catalog `#ProbeSchema`
  cannot express.
- Both ClusterRoles carry `tokenreviews`/`subjectaccessreviews` create (native metrics authn/authz).
- The dead `validatingwebhookconfigurations` grant was dropped (webhook mode is disabled); the
  CRD grant keeps only `list,watch`.
- Speaker `--host=0.0.0.0` and `METALLB_DEPLOYMENT` embellishments were dropped (not in the chart);
  controller gained `METALLB_POD_NAME`.

## ⚠ Instance naming

RBAC `resourceNames` scoping references the **rendered** object names
(`metallb-controller`, `metallb-speaker-memberlist`), which embed the ModuleInstance name.
Deploy as an instance named exactly `metallb` in namespace `metallb-system`.

## Configuration

See `#config` in `module.cue`: `image{repository,tag,digest,pullPolicy}`,
`controller{logLevel,replicas,resources?}`, `speaker{logLevel,resources?,memberlistKey}`.

The v2 `#Secret` is a disjunction — pick a concrete branch in instance values.
The usual choice here is the literal branch (OPM creates and manages the Secret):

```cue
speaker: memberlistKey: value: "<generated key>"
```

Alternatively reference a pre-existing Secret with the k8s-ref branch
(`secretName:` + `remoteKey:` — OPM emits no Secret resource then).

Generate a memberlist key with:

```bash
head -c 128 /dev/urandom | base64 | tr -d '\n'
```

## Re-vendoring CRDs

`crds_data.cue` is generated from `crds/*.yaml` (upstream `config/crd/bases` at the pinned tag):
download the 9 YAML files, then wrap each `cue import`ed file in a `#metallb_io_<name>` definition
(see the header comment in `crds_data.cue`).
