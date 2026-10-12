## 1. Check files

- [x] 1.1 Add `.tasks/openspec-check.sh` and `.tasks/openspec-check-test.sh`, adapted to this repo's targets.
- [x] 1.2 `Taskfile.yml`: add `cite-lint` and `openspec:check`, and run `openspec:check` from `check`.
- [x] 1.3 `task check` green, then commit `ci: run the comment rule and the durable-decisions check locally`.

## 2. CI

- [ ] 2.1 `ci.yml`: add the `cite-lint` job calling the `.github` workflow at the pinned commit.
- [ ] 2.2 actionlint and zizmor clean on the changed lines, then commit `ci: call the shared cite-lint workflow`.

## 3. Docs

- [ ] 3.1 `AGENTS.md`: list `task cite-lint`, `task openspec:check` and the CI job.
- [ ] 3.2 `task check` green, then commit `docs: list the cite-lint and openspec:check checks`.
