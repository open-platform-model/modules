## 1. Fleet-wide: `<module>/identity/identity.cue`

- [x] 1.1 In all 20 files: replace `Version: #VersionType | *"x.y.z"` with `Version: "x.y.z"` (same literal), delete the `#VersionType` definition and its two comment lines, and extend the `Version` comment with the WHY (concrete literal; kernel gate; core's `#IdentityPackage` supplies the constraint). `grep -l '#VersionType' */identity/identity.cue` and `grep -L '^Version: "' */identity/identity.cue` both return nothing; `git diff` shows no version literal changed.

## 2. Durable decisions

- [x] 2.1 `DESIGN_PATTERNS.md`: add section "13. Module identity" (literal `Version`, no local `#VersionType`, `metadata` plain references, `identity.cue` written only by `opm module version set`) plus the Table of Contents and Quick Reference entries.

## 3. Verification

- [x] 3.1 `task check`.
- [x] 3.2 `opm module vet ./<module>` for every module: `Identity conforms to #IdentityPackage` and `Version matches path major` green.
- [x] 3.3 `opm module build ./web_app --name web -n default --platform <platform pinned at catalogs/opm alpha.6>` renders (previously refused at the shape gate); repeat for `istio_ambient` and record that its remaining failure is the `catalog_opm` role-transformer defect, not the gate.
  Recorded 2026-08-28: `web_app` renders Service + Deployment; `istio_ambient` passes the gate and fails in `role-transformer@2.0.0-alpha.6` (`ClusterRole/istio-cni`: `_k8sRules.0.resourceNames` incomplete), a `catalog_opm` defect.
- [x] 3.4 `opm module version set <current version> ./<module>` on one module reports "already ...; untouched" (idempotency the release workflow relies on).
  `web_app` 1.0.1: "Version already 1.0.1; identity/identity.cue untouched".
- [x] 3.5 `opm module publish ./<module> --dry-run` for every module: the only refusal is already-published (the filter `ci.yml` applies).

## 4. Follow-ups filed outside this repo (not tasks here)

- [ ] 4.1 `cli`: scaffold emits `Version: "x.y.z"` (`internal/scaffold/repair.go`), podinfo fixture drops its interpolation workaround, and `opm module publish` runs the loader shape gate so publish refuses what load refuses.
- [ ] 4.2 `catalog_opm`: identity files to the literal form.
- [ ] 4.3 `library`: `requireConcrete` names a defaulted disjunction and points at `identity/identity.cue`.
