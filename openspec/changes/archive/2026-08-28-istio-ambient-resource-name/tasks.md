## 1. Dependency pin

- [x] 1.1 From the workspace root run `task deps:update`; keep only the `modules/*/cue.mod/module.cue` hunks (`catalogs/opm@v2` -> 2.0.0-alpha.7) for this change; `task tidy`.

## 2. istio_ambient/components_control_plane.cue

- [x] 2.1 `istiod`: remove `tr.#ResourceName`; move `resourceName: "istiod"` from `spec` to `metadata: resourceName: "istiod"` at component level (D-A).
- [x] 2.2 `_istiodResourceName` reads `#components.istiod.#names.resourceName` (D-B).

## 3. istio_ambient/components_dataplane.cue

- [x] 3.1 `istio-cni`: remove `tr.#ResourceName`; `metadata: resourceName: "istio-cni-node"`.
- [x] 3.2 `ztunnel`: remove `tr.#ResourceName`; `metadata: resourceName: "ztunnel"`.
- [x] 3.3 `_cniResourceName` reads `#components["istio-cni"].#names.resourceName`.

## 4. Durable decisions

- [x] 4.1 `DESIGN_PATTERNS.md` section 12: exact names via `metadata.resourceName`, asserted on `#names.resourceName`; `#ResourceNameTrait` retired.
- [x] 4.2 `istio_ambient/DEPLOYMENT_NOTES.md` (new): the three external-contract names and where they are set; D-C; the kernel render diff is pending the `catalog_opm` role-transformer fix (link the change when it exists).

## 5. Verification

- [x] 5.1 `grep -rn 'tr.#ResourceName\|spec.resourceName' istio_ambient` returns nothing.
- [x] 5.2 `task check`, then `task vet CONCRETE=true` (both guards must resolve, not pass vacuously).
- [x] 5.3 `opm module publish ./istio_ambient --dry-run`.
- [ ] 5.4 When the catalog role-transformer fix is published: `opm module build ./istio_ambient --name istio -n istio-system --platform <pin>` before (trait, alpha.7) and after; `diff` must be empty; record in `DEPLOYMENT_NOTES.md`.
