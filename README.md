# OPM Modules — `v0_legacy` branch

Workspace-level OPM module definitions (CUE), published to `opmodel.dev/modules/*`.

## ⚠️ This is the frozen OPM v0 line

This repo is split into two branches because the OPM v0 and v1 generations cannot share one CUE toolchain or catalog:

| Branch | OPM line | CUE language | Catalog dependencies | Status |
| --- | --- | --- | --- | --- |
| `v0_legacy` (this one) | v0 | `v0.16.0` | `opmodel.dev/core/v1alpha1`, `opmodel.dev/opm/v1alpha1` | Maintenance only |
| `main` | v1 | `v0.17.0` | `opmodel.dev/core@v1`, `opmodel.dev/catalogs/opm@v1` | Active development |

The old catalog schemas rely on CUE behavior removed in v0.17, while the new catalog requires v0.17+. Splitting the branches gives each line one toolchain, one dependency set, and an unambiguous publish pipeline.

**Do not add new modules on this branch.** New development happens on `main` against the OPM v1 catalog. Publishing from this branch is triggered by pushes to `v0_legacy` (see `.github/workflows/publish.yml`).

## Working here

- `CLAUDE.md` — repo working rules and agent guidance.
- `DESIGN_PATTERNS.md` — reusable CUE patterns across modules.
- `Taskfile.yml` — `task fmt` / `task vet` / `task check` / `task publish`.
- `versions.yml` — published version + checksum registry for this branch's modules.
