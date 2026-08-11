# OPM Modules

Workspace-level OPM module definitions (CUE), published to `opmodel.dev/modules/*`.

## Branch model: one branch per OPM generation

This repo is split by OPM generation because the lines cannot share one CUE toolchain or catalog:

| Branch | OPM line | CUE language | Catalog dependencies | Status |
| --- | --- | --- | --- | --- |
| `main` (this one) | v2 | `v0.17.0` | `opmodel.dev/core@v2`, `opmodel.dev/catalogs/opm@v2` | Active development. The fleet is authored against the v2 prereleases; **publish-on-push is disabled** until the v2 fleet publishes (a deliberate enablement step). |
| `v1` | v1 | `v0.17.0` | `opmodel.dev/core@v1`, `opmodel.dev/catalogs/opm@v1` | **Protected live maintenance line** — publishes on push (checksum-driven patch bumps via `versions.yml`). Fixes for the published v1 fleet go here. |
| `v0_legacy` | v0 | `v0.16.0` | `opmodel.dev/core/v1alpha1`, `opmodel.dev/opm/v1alpha1` | Frozen legacy line, maintenance only. |

The v0 catalog schemas rely on CUE behavior removed in v0.17, the v1 catalog requires v0.17+, and the v2 line re-keys module identity (enhancements 0010/0011). Splitting the branches gives each line one toolchain, one dependency set, and an unambiguous publish pipeline.

New modules land here on `main` against the v2 line. A registry path may exist on several branches, but each branch publishes it at its own major (cross-train major separation — e.g. the v1 branch publishes `opmodel.dev/modules/jellyfin` at major v2, this branch at major v3); CI enforces that majors never collide across branches.

## Module anatomy (v2 line)

```text
<module-name>/
  cue.mod/module.cue      CUE module manifest — opmodel.dev/modules/<name>@<major>
  identity/identity.cue   committed identity package (ModulePath + Version, core #IdentityPackage)
  module.cue              module metadata + #config schema + debugValues
  components.cue          component definitions (catalog blueprints/traits/resources)
  README.md               usage, architecture, quick start
  DEPLOYMENT_NOTES.md     issues and fixes found during deployment
```

## Working here

- `CLAUDE.md` — repo working rules and agent guidance (read first; includes the branch rules above in normative form).
- `DESIGN_PATTERNS.md` — reusable CUE patterns across modules.
- `Taskfile.yml` — `task fmt` / `task vet` / `task check` / `task publish`.
- `versions.yml` — published version + checksum registry for this branch's modules.
