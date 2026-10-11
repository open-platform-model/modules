## Why

The OPM enhancements now live in an OpenSpec store, `opm-enhancements`, with their own ids and requirements. The old way to cite one, a decision number such as `NNNN:Dn`, names nothing a reader can open. A lone id says nothing either. This repo must cite an enhancement only as its id beside a reason in words, and must stop asking agents to write `enhancement.yaml`.

The rules that steer agents sit in patches inside OpenSpec skill files. `openspec update` overwrites those files. The rules move into `openspec/config.yaml`, which `openspec update` does not overwrite.

## What Changes

- `openspec/config.yaml` and `AGENTS.md`: add `references:` to the store, the `Delivers NNNN, task X.Y.` proposal rule, a context line that says how to read an entry, and the comment rule ("an enhancement id only beside a reason in words, never alone, never a decision number"). Remove every rule about `enhancement.yaml` and `task enhancements:delivery:*`. The archive guidance says that a PR on `enhancements` ticks a delivered line.
- `openspec/schemas/module-change/schema.yaml` and `templates/proposal.md`: the Enhancement section asks for `Delivers NNNN, task X.Y.` lines.
- Principle VII (no enhancement reference in module comments) stays. Its text loses the decision-number example.
- Every citation in tracked files becomes an id beside a reason in words: the comments of `.github/workflows/release.yml`, `istio_ambient/DEPLOYMENT_NOTES.md`, and four archived changes. The `enh cite-rewrite` tool did the mechanical part; the sites it only lists were rewritten by hand.
- Three archived `enhancement.yaml` files are deleted. Their proposals already name the entry.
- `move-media-gpu-modules-to-jacero` is an active change and is not edited.

No `#config`, component or rendered object changes. One CI log line loses the text `(D15)`; the workflow logic is the same.

## Before / After

No CUE file changes: Before and After are the same. Only comment and rule text changes.

## Catalog contract

No change. The core and catalog pins stay. `task deps:update` is not needed.

## Impact

- **Module directories touched:** `istio_ambient/` (one line in `DEPLOYMENT_NOTES.md`). Release class: none. Every commit is a `docs` type, which release-please hides, so no module bumps. No path major moves.
- **Operators of modules:** no action.
- **Owner:** the skills `openspec-new-change`, `openspec-propose` and `openspec-archive-change` under `.claude/skills/` carry six `REPO-LOCAL PATCH` blocks. Agents do not write under `.claude/`. The owner runs `openspec update` with the pinned CLI; the report lists each block and the line in `config.yaml` that replaces it.
- **No spec delta:** this workspace has no specs artifact (Principle II). `.openspec.yaml` declares `skip_specs: true`.

## Enhancement

None.
