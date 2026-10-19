## Why

OpenSpec moves to 1.14.1 in every repo of the workspace. In 1.14.1 the over-500-character requirement check is a WARNING, and `--strict` fails on it. This repo has no specs, so for it the move is the generated skills only. The skills are at 1.12.0 today.

## What Changes

- `.claude/skills/openspec-*`: regenerate the skills from the pristine 1.14.1 output of `openspec init --tools claude`. Keep the four local edits (archive-change, new-change, propose, verify-change), merged by a 3-way merge against pristine 1.12.0. In propose, keep the repo paragraph on the fixed `module-change` schema and drop the new workflow-selection text of step 3.
- Keep `openspec-sync-specs` absent: this tree has none, and the result has none (`references/openspec-workflow.md`).
- No pin, no gate line, no `openspec/config.yaml` change. The repo pins no OpenSpec CLI.

## Before / After

No CUE file changes: Before and After are the same. Only skill files change.

**Before**

```cue
```

**After**

```cue
```

## Catalog contract

No change. The core and catalog pins stay. `task deps:update` is not needed.

## Impact

- **Module directories touched:** none. Every commit is `chore`, which release-please does not release. No path major moves.
- **Operators of modules:** no action.
- **Reviewer:** read the propose skill, step 3, and the three other merged skills first.

## Enhancement

None.
