# Modules repository guide

## Branch model (read before committing)

This repo is split by OPM generation because the lines cannot share one CUE toolchain or catalog:

| Branch | Line | Purpose |
| --- | --- | --- |
| `main` | OPM v2 (staging) | Staging line for the OPM v2 fleet (enhancements 0010/0011). Publish-on-push disabled until that fleet is authored. |
| `v1` | OPM v1 | Protected live maintenance line. Modules pin CUE `v0.17.0` and depend on stable `opmodel.dev/core@v1` + `opmodel.dev/catalogs/opm@v1`. Publishes on push; fixes and new v1 modules go there. |
| `v0_legacy` | OPM v0 | Frozen legacy line (this branch). Modules pin CUE `language: version: "v0.16.0"` and depend on the deprecated `opmodel.dev/core/v1alpha1` + `opmodel.dev/opm/v1alpha1` catalog (old `catalog/` repo). Maintenance only — no new modules here. |

**You are on `v0_legacy`.** Maintenance fixes only. Never merge another branch into this one.

Why: the old catalog schemas use CUE features removed in v0.17 (e.g. `div`), and the newer catalogs require v0.17+. Keeping generations on one branch forced every tool (`task vet`, `task publish`, CI) to special-case per-module CUE binaries and made "publish all changed" ambiguous. The split gives each line a single toolchain and a clean `versions.yml`. The `jellyfin_v016`/`seerr_v016` names are kept as-is here — their registry paths are their published identity (`jellyfin_v016/` publishes `opmodel.dev/modules/jellyfin@v1`).

**Major separation rule:** a registry path may exist on several trains, but two trains must never share a major for the same path (legacy `jellyfin@v1` vs the v1 train's `jellyfin@v2`). This branch's majors are frozen; when a module gets rewritten for a newer train, it takes the next major above this line. CI enforces this (`Cross-train major separation guard` in `publish.yml`).

## Purpose

This directory contains workspace-level OPM module definitions. Unlike the submodule repos (`cli/`, `catalog/`, etc.), files here live directly in the workspace root git repository.

## Repository Rules

- Follow the CUE style from `catalog/`: `#` definitions, `_` hidden fields, `*` defaults, `?` optional fields.
- Do not put build artifacts, binaries, or generated Kubernetes YAML here — those belong in the cluster or CI.
- To update CUE deps for all workspace modules at once, run `task deps:update` from the workspace root. Do not manually edit version pins in `cue.mod/module.cue` — use the task instead.
- Validate with `cue vet -c ./modules/<name>/...` before committing.

## Entrypoint

Read these on entry:

- `CLAUDE.md` — repo working rules (this file).
- `DESIGN_PATTERNS.md` (if present) — reusable patterns across modules (catalog schema helpers, volume type-switch, ConfigMap rendering, sidecar container pattern). Read before writing any new CUE.
- `Taskfile.yml` — authoritative format/validate/publish entrypoints.
- `catalog/CLAUDE.md` — referenced CUE style guidelines.

## Repository Layout

```text
modules/
  <module-name>/          — OPM module definition
    module.cue            — Module metadata and #config schema
    components.cue        — Workload/resource component definitions
    README.md             — Usage, architecture, quick start
    DEPLOYMENT_NOTES.md   — Issues and fixes encountered during deployment
```

### Current modules

| Module | Description |
| --- | --- |
| `ch_vmm/` | ch-vmm — Cloud Hypervisor virtualization add-on (controller + per-node daemon + CRDs) |
| `wolf/` | Wolf GPU game streaming server — Moonlight-compatible, multi-user, AMD/NVIDIA |

## Build And Dev Commands

Run all commands from `modules/`.

| Command | Purpose | When to use |
| --- | --- | --- |
| `task fmt` | Format all CUE modules | After editing any `.cue` file |
| `task vet` | Validate all CUE modules | Before committing; to catch schema errors |
| `task vet CONCRETE=true` | Validate with concreteness check (`-c`) | When checking fully-resolved values |
| `task tidy` | Tidy dependencies for all modules | After changing imports or updating deps |
| `task check` | Run `fmt` then `vet` | Pre-commit quality gate |
| `task versions` | Show version and change status | Before publishing |
| `task publish` | Publish all changed modules | When releasing new versions |
| `task publish:one MODULE=<name>` | Publish a single module | When releasing one module |
| `task publish:dry` | Dry run of publish | To preview what would be published |

## CUE Style Guidelines

Follow the CUE style used across the workspace catalog. See `catalog/CLAUDE.md` for the full guidelines. Key points:

- `#` prefixes for definitions: `#Module`, `#ContainerResource`.
- `_` prefixes for hidden fields / scratch bindings.
- `!` for required, `?` for optional fields, `*` for explicit defaults.
- Pin `language: version: "v0.16.0"` in `cue.mod/module.cue`.

## Working Style for Agents

### Adding a new module

Before writing any CUE, read `DESIGN_PATTERNS.md` (if present) — it documents the reusable patterns used across all modules in this directory.

1. Create `modules/<name>/` directory.
2. Write `module.cue` (module metadata + `#config` schema) and `components.cue` (#components).
3. Add `README.md` with architecture overview, quick start, and configuration reference.
4. Add `DEPLOYMENT_NOTES.md` as issues are discovered during deployment.

### Adding a new release

See `releases/CLAUDE.md` for layout, conventions, and step-by-step instructions.
