## 1. The rewrite

- [x] 1.1 Run `enh cite-rewrite --write` once (15 edits in 10 files, 3 `enhancement.yaml` deleted) and commit the result in two commits: archived text, then the rest.
- [x] 1.2 Clear the worklist by hand (6 rows) and rewrite the sites the tool lists as unsafe; shorten the tool's long titles where the sentence broke.
- [x] 1.3 `task check` green, then commit `docs: cite enhancements by id and reason`.

## 2. The rules

- [x] 2.1 `openspec/config.yaml`: add `references:`, the `Delivers` proposal rule, the context line, the comment rule; remove the `enhancement.yaml` and `delivery:log` rules; add the archive guidance line.
- [x] 2.2 `AGENTS.md`, `schema.yaml` and `templates/proposal.md` say the same.
- [x] 2.3 `task check` green, then commit `docs: point modules at the enhancements store`.

## 3. Verify

- [x] 3.1 `enh cite-lint` reports 0 findings and `enh cite-rewrite --dry-run` reports 0 edits; no `0030:` or `0031:` remains.
- [x] 3.2 `openspec validate align-enhancement-store --strict` passes; `task check` is green.
