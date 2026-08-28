## Context

Files: `istio_ambient/cue.mod/module.cue` (pin), `istio_ambient/components_control_plane.cue` (`istiod`: trait at line 30, `spec.resourceName` at 102, guard at 355), `istio_ambient/components_dataplane.cue` (`istio-cni`: 43, 59; `ztunnel`: 246, 258; guard at 426), `istio_ambient/DEPLOYMENT_NOTES.md` (new). Patterns in play: `DESIGN_PATTERNS.md` 12 (Component Trait Composition), which lists traits attached per component; the trait leaves that list. Depends on `fleet-identity-version-interpolation` only for the render gate (task 4.2), not for the migration.

Both files already hoist conditional `spec` fields to component level for the CUE v0.17 closedness workaround; `metadata: resourceName:` is a component-level field and sits beside those hoists.

## Goals / Non-Goals

**Goals:**
- No `tr.#ResourceName` left in the fleet before the catalog deletes it.
- The three exact names are asserted on the value transformers read.
- Rendered output byte-identical, measured once the render path is open.

**Non-Goals:**
- Renaming anything. Every override keeps its value.
- The catalog role-transformer fix and the `cli` instance-name defect.

## Decisions

**D-A. `metadata.resourceName`, set at component level.**

```cue
istiod: {
	bp.#StatelessWorkload
	// ...
	metadata: resourceName: "istiod"
	spec: {...}
}
```
`#Component.metadata.resourceName` (core alpha.6) is `*"\(#instance.name)-\(name)" | #ObjectNameType`; an explicit string is concrete regardless of `#instance`. No `#config` field changes default, requiredness or closedness.

**D-B. Guards read `#names.resourceName`.**

```cue
_istiodResourceName: "\(#components.istiod.#names.resourceName)" & "istiod"
_cniResourceName:    "\(#components["istio-cni"].#names.resourceName)" & "istio-cni-node"
```
`#names` is the projection every transformer reads after D15, so the guard checks the rendered name's source, not the input. It is concrete here only because the override is explicit; a default-named component's `#names` would be incomplete without an instance and the guard would pass vacuously under plain `cue vet` (measured in `catalog_opm`, `catalog-names-readonly-workloads`), so `task vet CONCRETE=true` is the gate.

**D-C. Semantic note for `istiod`.** With the trait, `#names.dns.*` stayed `istio-istiod...`; with the core field they follow `istiod`. Nothing in the module reads `#ctx`/`dns.*` and `expose.name` is explicit, so no rendered value moves. Recorded in `DEPLOYMENT_NOTES.md` because a future author removing the explicit `expose.name` would now get `istiod` (correct) where before D22 they got `istio-istiod`.

## Research & Decisions

### Trait users in the fleet
**Context**: D15 named istio-cni-node, istiod and database as trait fixtures.
**Explored**: `grep -rn 'tr.#ResourceName' modules` 2026-08-28: three sites, all `istio_ambient`; no module sets `metadata.resourceName`; no module reads `#ctx` or `dns.*`.
**Decision**: one module-scoped change.
**Rationale**: the unit is one module (Principle VI).

### Render gate
**Context**: the sweep's contract is "invisible rename".
**Explored**: scratch renders 2026-08-28 with a fresh `cli` build: the loader refuses `metadata.version` (fleet defect, `fleet-identity-version-interpolation`); with that patched and `--name istio -n istio-system --platform <alpha.7 pin>`, the render fails in `#RoleTransformer` on the `istio-cni` ClusterRole's plain rule (unresolved `#PolicyRuleSchema` disjunction, `role_transformer.cue:56`, also at alpha.6). `cue vet -c ./...` on the migrated scratch copy is clean and both guards resolve.
**Decision**: land the migration on the `cue vet -c` gate; add the kernel render diff when the catalog fix ships, as a `DEPLOYMENT_NOTES.md` entry.
**Rationale**: the catalog deletion (sweep 3) is gated on this change; the render defect predates it and blocks the module regardless of naming.

### alpha.7 side effects on the fleet
**Context**: alpha.7 makes the four route transformers require `#Expose`.
**Explored**: every route-using module (11) attaches `tr.#Expose`.
**Decision**: the fleet-wide pin bump carries no other migration.

## Risks / Trade-offs

- `#names.resourceName` incomplete in a guard -> only with a default-named component; both guarded components are explicit; `task vet CONCRETE=true` in verification.
- `task deps:update` rewrites other repos -> commit only the `modules` hunk here; leave the rest for their own PRs.
- The CNI failsafe name -> `_cniResourceName` stays a hard assertion on `"istio-cni-node"`.

## Durable decisions

- "Exact object names are set with `metadata: resourceName:` at component level and asserted on `#names.resourceName`; `#ResourceNameTrait` is retired" -> `DESIGN_PATTERNS.md` section 12 (Component Trait Composition) gains the note; `istio_ambient/DEPLOYMENT_NOTES.md` (new) records the three external-contract names, D-C, and the pending render diff.
