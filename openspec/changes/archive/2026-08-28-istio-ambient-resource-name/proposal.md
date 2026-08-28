## Why

`catalogs/opm` 2.0.0-alpha.7 (enhancement 0019 D15, `catalog-names-readonly-workloads`) deprecates `#ResourceNameTrait`: transformers now read a workload's name from `#component.#names.resourceName`, which core derives from `metadata.resourceName`; the trait survives one release behind a seam and is deleted in the next catalog change. `istio_ambient` is the only module in the fleet attaching the trait, at three components whose names are external contracts: `istiod` (mesh discovery identity), `istio-cni-node` (the CNI plugin's failsafe matches on this name) and `ztunnel`. This is sweep 2 of the staged retirement: migrate the fleet before the catalog deletes the trait.

## What Changes

`istio_ambient/` only:
- `cue.mod/module.cue`: `catalogs/opm@v2` alpha.6 -> alpha.7 (via `task deps:update`; at alpha.6 `metadata.resourceName` is ignored by the transformers, so the bump is a precondition, not a courtesy).
- `components_control_plane.cue` (`istiod`) and `components_dataplane.cue` (`istio-cni`, `ztunnel`): drop `tr.#ResourceName`; `spec: resourceName: "<x>"` becomes `metadata: resourceName: "<x>"`.
- The two guards, `_istiodResourceName` and `_cniResourceName`, re-target `#components.<id>.#names.resourceName`: the value the transformers actually read, concrete without an instance because the override is explicit.
- `README.md` / a new `DEPLOYMENT_NOTES.md` entry naming the three exact names as external contracts and where they are now set.

Not breaking: every rendered object keeps its name. `istiod`'s Service is already `expose.name: "istiod"` explicitly, so `#names.dns.short` following the override changes nothing rendered.

## Before / After

**Before**

```cue
istiod: {
	bp.#StatelessWorkload
	tr.#Expose
	tr.#ResourceName
	spec: {
		resourceName: "istiod"
		expose: name: "istiod"
	}
}
_istiodResourceName: "\(#components.istiod.spec.resourceName)" & "istiod"
```

**After**

```cue
istiod: {
	bp.#StatelessWorkload
	tr.#Expose
	metadata: resourceName: "istiod"
	spec: expose: name: "istiod"
}
_istiodResourceName: "\(#components.istiod.#names.resourceName)" & "istiod"
```

Same shape for `istio-cni` (`"istio-cni-node"`) and `ztunnel` (`"ztunnel"`). Rendered Deployment/DaemonSet `metadata.name`, HPA `scaleTargetRef.name`, PDB name and Service name: unchanged.

## Catalog contract

- `catalogs/opm@v2` >= 2.0.0-alpha.7 (D15 seam: `#WorkloadName` reads the trait if set, else `#names.resourceName`; `metadata.resourceName` honoured). `core@v2` alpha.6 already carries `metadata.resourceName` and `#names` (D16/D20).
- `task deps:update` from the workspace root MUST run first. It is not scopeable and also rewrites the `catalog_opm`, `cli`, `core` and `opm-operator` pins; only the `modules` hunk belongs to this change (committed as `fix(deps)` across the fleet), the rest are those repos' own `fix(deps)` PRs.
- No missing catalog member. A kernel render of this module is blocked by a `catalog_opm` defect (`#RoleTransformer` leaves a plain resource rule as an unresolved `#PolicyRuleSchema` disjunction, reproduced at alpha.6 and alpha.7); that fix is a separate `catalog_opm` change and gates only the render diff, not this migration.

## Impact

- `istio_ambient/`: `fix(istio_ambient)` (identical output, trait-free; a `refactor:` is hidden from release-please here, and the module should re-release once the dep bump lands anyway). No path major moves.
- Every other module: `fix(deps)` for the alpha.7 pin. alpha.7 also makes route transformers require `#Expose`; verified 2026-08-28 that all 11 route-using modules attach `tr.#Expose`, so nothing stops matching.
- Operators: nothing to do; names, selectors and Service names are unchanged.

## Enhancement

`enhancements/0019` D15, the `modules` half of the staged `#ResourceNameTrait` retirement (sweep 2 of 3). `enhancement.yaml` declares D15.
