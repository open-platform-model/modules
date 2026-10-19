## 1. Regenerate the skills

- [ ] 1.1 Run `openspec update --force .`, then delete `.claude/skills/openspec-sync-specs/`.
- [ ] 1.2 Merge the four local edits (archive-change, new-change, propose, verify-change) with `git merge-file` against pristine 1.12.0; resolve the propose step 3 conflict by keeping the repo paragraph.
- [ ] 1.3 `task openspec:check` and `openspec validate --all --no-interactive` green, then commit `chore(openspec): regenerate the OpenSpec skills with 1.14.1`
