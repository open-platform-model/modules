# Modules: where do I go?

Router only. Facts and rules are in `AGENTS.md`.

| Task | Read first | Then |
| --- | --- | --- |
| Add a module | `references/new-module.md` | `DESIGN_PATTERNS.md` |
| Edit CUE of an existing module (`#config`, components, README) | `DESIGN_PATTERNS.md` | `openspec/config.yaml` |
| Propose, design, apply or archive a change; edit `openspec/` or the repo skills; deliver an enhancement task | `references/openspec-workflow.md` | `openspec/config.yaml` |
| Choose a branch, a version, a path major or a commit type for a release; bump a pin; clean up GHCR versions | `references/branches-and-versioning.md` | `AGENTS.md` |
| Run fmt, vet or the pre-commit gate; fix a failing check | `Taskfile.yml` | `AGENTS.md` |
| Fix a module on the live v1 line | `references/branches-and-versioning.md` | `AGENTS.md` |
| Publish, tag or release | `AGENTS.md` | `../references/releases.md` |
