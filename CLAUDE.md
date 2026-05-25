# Modules repository guide

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
