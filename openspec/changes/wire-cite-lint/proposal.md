## Why

The comment rule of the enhancements store (an enhancement id only beside a reason in words, never a decision number) is checked in other repos by the shared `enh cite-lint` tool. This repo has no such check, so a bad citation can land unseen. Active changes also have no check that their design declares durable decisions.

## What Changes

- `Taskfile.yml`: new task `cite-lint` (the tool at one pinned commit, no excludes) and new task `openspec:check`; both run from `task check`.
- `.github/workflows/ci.yml`: a `cite-lint` job that calls the reusable workflow of the `.github` repo at a pinned commit, and a step that runs `task openspec:check`.
- `.tasks/openspec-check.sh` and `.tasks/openspec-check-test.sh`: the durable-decisions check, adapted from catalog_opm. Targets here are `DESIGN_PATTERNS.md`, `<module>/DEPLOYMENT_NOTES.md`, `AGENTS.md` or "stays with the change".
- `AGENTS.md`: lists the new task and CI checks.
- The repo pins no OpenSpec CLI, so no pin moves.

## Before / After

No CUE file changes: Before and After are the same. Only CI and task files change.

**Before**

```cue
```

**After**

```cue
```

## Catalog contract

No change. The core and catalog pins stay. `task deps:update` is not needed.

## Impact

- **Module directories touched:** none. Every commit is `ci`, `build`, `docs` or `chore`, which release-please does not release. No path major moves.
- **Operators of modules:** no action.
- **Reviewer:** the new CI call needs the `.github` reusable workflow to run on this repo; check the `Cite lint` job on the PR.

## Enhancement

None.
