# OPM Modules

Workspace-level OPM module definitions (CUE), published to `opmodel.dev/modules/*`.

## Branch split: OPM v1 (main) vs OPM v0 (`v0_legacy`)

This repo is split into two branches because the OPM v0 and v1 generations cannot share one CUE toolchain or catalog:

| Branch | OPM line | CUE language | Catalog dependencies | Status |
| --- | --- | --- | --- | --- |
| `main` (this one) | v1 | `v0.17.0` | `opmodel.dev/core@v1`, `opmodel.dev/catalogs/opm@v1` | Active development |
| `v0_legacy` | v0 | `v0.16.0` | `opmodel.dev/core/v1alpha1`, `opmodel.dev/opm/v1alpha1` | Maintenance only |

The old catalog schemas rely on CUE behavior removed in v0.17, while the new catalog requires v0.17+. Splitting the branches gives each line one toolchain, one dependency set, and an unambiguous publish pipeline. New modules are always added here on `main`; the v0.16 fleet (wolf, metallb, linstor, k8up, …) is on `v0_legacy`.

## Working here

- `CLAUDE.md` — repo working rules and agent guidance.
- `DESIGN_PATTERNS.md` — reusable CUE patterns across modules.
- `Taskfile.yml` — `task fmt` / `task vet` / `task check` / `task publish`.
- `versions.yml` — published version + checksum registry for this branch's modules.
