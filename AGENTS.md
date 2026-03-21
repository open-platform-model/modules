# modules/ AGENTS.md

## Purpose

This directory contains workspace-level OPM module definitions. Unlike the submodule
repos (`cli/`, `catalog/`, etc.), files here live directly in the workspace root git
repository.

## Layout

```text
modules/
  <module-name>/          — OPM module definition
    module.cue            — Module metadata and #config schema
    components.cue        — Workload/resource component definitions
    README.md             — Usage, architecture, quick start
    DEPLOYMENT_NOTES.md   — Issues and fixes encountered during deployment
```

## Current Modules

| Module | Description |
| --- | --- |
| `wolf/` | Wolf GPU game streaming server — Moonlight-compatible, multi-user, AMD/NVIDIA |

## Conventions

- Follow CUE style from `catalog/`: `#` definitions, `_` hidden fields, `*` defaults, `?` optional fields.
- Validate with: `cue vet -c ./modules/<name>/...`
- Do not put build artifacts, binaries, or generated Kubernetes YAML here — those belong in the cluster or CI.

## Adding a New Module

1. Create `modules/<name>/` directory.
2. Write `module.cue` (module metadata + `#config` schema) and `components.cue` (#components).
3. Add `README.md` with architecture overview, quick start, and configuration reference.
4. Add `DEPLOYMENT_NOTES.md` as issues are discovered during deployment.

## Adding a New Release

See `releases/AGENTS.md` for layout, conventions, and step-by-step instructions.
