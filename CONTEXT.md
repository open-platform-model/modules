# Modules: where do I go?

Router only. Facts and rules are in `AGENTS.md`.

| Task | Read first | Then |
| --- | --- | --- |
| Create a new module directory from scratch | `references/new-module.md` | `DESIGN_PATTERNS.md` |
| Move, rename, split or retire existing modules; any change that needs a proposal, design or archive; edit `openspec/` or the repo skills; deliver an enhancement task | `references/openspec-workflow.md` | `openspec/config.yaml` |
| Edit the CUE, README or notes of an existing module (a `#config` field, a component) | `DESIGN_PATTERNS.md` | `openspec/config.yaml` |
| Choose a branch, a version, a path major or a release commit type; bump a pin; fix the live v1 fleet; clean up GHCR versions | `references/branches-and-versioning.md` | `AGENTS.md` |
| Run fmt, vet or the pre-commit gate; fix a failing check | `Taskfile.yml` | `AGENTS.md` |
| Edit CI: a workflow, an action pin or the opm version CI installs | `.github/workflows/` | `Taskfile.yml` |
| Publish, tag or release | `AGENTS.md` | `../references/releases.md` |
