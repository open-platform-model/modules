## Context

The repo-local skills in `.claude/skills/` are output of `openspec update`. Four carry a local edit: archive-change, new-change, propose, verify-change. `openspec update` overwrites every file, so each edit is merged back by hand.

## Goals / Non-Goals

**Goals:**
- Every generated skill is at `generatedBy: "1.14.1"`.
- Every local edit survives.
- `openspec-sync-specs` does not exist.

**Non-Goals:**
- A change to `openspec/config.yaml`, to the schema, or to any pin.

## Decisions

- Merge base is pristine 1.12.0, taken from `openspec init --tools claude` of the cached 1.12.0 package in an empty scratch directory. Merge is `git merge-file` per edited file, with the 1.14.1 output as the other side.
- Propose step 3 conflicts. The human ruled to keep the repo paragraph ("This repo's default is the project-local `module-change` schema ... Never select `spec-driven` here ...") and drop the 1.14.1 workflow-selection text in that step. Every other 1.14.1 change in the file stays.
- No spec delta: `.openspec.yaml` carries `skip_specs: true`.

## Research & Decisions

None.

## Risks / Trade-offs

- A merge can drop a local edit silently -> compare each merged file with pristine 1.14.1 and check that every local line is present.
- Package integrity of the 1.14.1 CLI is not verified (no network).

## Durable decisions

None.

## Open Questions

None.
