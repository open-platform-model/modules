# Istio Ambient Deployment Notes

## Three workload names are external contracts

| Component | Rendered name | Why it is fixed | Set at |
| --- | --- | --- | --- |
| `istiod` | `istiod` | Mesh discovery identity; the mesh ConfigMap embeds it (`_istiodExposeName`) | `components_control_plane.cue`, `metadata: resourceName:` |
| `istio-cni` | `istio-cni-node` | The CNI plugin's failsafe matches on this DaemonSet name; a mismatch deadlocks the node | `components_dataplane.cue`, `metadata: resourceName:` |
| `ztunnel` | `ztunnel` | Node-local proxy the control plane addresses by name | `components_dataplane.cue`, `metadata: resourceName:` |

Each is asserted, not trusted: `_istiodResourceName` and `_cniResourceName` unify
`#components.<id>.#names.resourceName` with the literal, so a drift fails `cue vet`.
`#names` is the value the transformers read, which is why the guard targets it rather than
the input field. Both guards resolve to concrete strings without an instance only because the
overrides are explicit; `task vet CONCRETE=true` is the gate that proves they are not passing
vacuously.

Migrated 2026-08-28 from `traits_workload.#ResourceName` (`spec.resourceName`) to
`metadata.resourceName` (catalog 2.0.0-alpha.7, enhancement 0019 D15, change
`istio-ambient-resource-name`). Every rendered name is unchanged.

## istiod: `#names.dns.*` now follows the override

With the trait, `#names.dns.short` stayed `istio-istiod` (instance-prefixed) while the
Deployment was `istiod`; with `metadata.resourceName` the whole `#names` projection follows
the override, so `dns.short` is `istiod`. Nothing in the module reads `#ctx` or `dns.*`, and the
Service name is set explicitly (`spec: expose: name: "istiod"`), so no rendered value moved.
A future author who removes the explicit `expose.name` now gets `istiod` (correct) where they
previously would have got `istio-istiod`.

## Kernel render diff: pending a catalog fix

`opm module build ./istio_ambient --name istio -n istio-system --platform <alpha.7 pin>` fails
in `catalogs/opm/transformers/role-transformer` on the `istio-cni` ClusterRole: a plain
resource rule is left as an unresolved `#PolicyRuleSchema` disjunction
(`_k8sRules.0.resourceNames` incomplete), reproduced at alpha.6 and alpha.7. The migration
therefore landed on the `cue vet -c` gate. When the `catalog_opm` fix is published, render
before (trait, alpha.7) and after and record the empty diff here.
