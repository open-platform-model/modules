# Tasks — modules-publish-cutover

> Mirrors `catalog_opm`'s landed cutover, fanned out to 20 modules. Groups land independently; the ledger deletion (group 4) goes last so the old path stays available until the new one is proven by a dry run. Commit messages: glue majors to paths (bare-`@` ban), plain co-author trailer only.

## 1. release-please configuration

- [x] 1.1 `release-please-config.json`: 20 packages (every directory with a `cue.mod` — exclude `cdi/`, `snapshot_controller/`), each `release-type: simple` with its own `component` and `changelog-path`; repo-level `bootstrap-sha` at the fleet-port commit; changelog sections matching the catalog's.
- [x] 1.2 `.release-please-manifest.json` seeded from each module's declared identity `Version` (jellyfin 3.0.0, k8up 3.0.0, web_app 1.0.0, the other 17 at 2.0.0) — verify each against `cue eval ./identity -e Version` rather than transcribing.
- [x] 1.3 Attempt the `modules/<name>/vX.Y.Z` tag shape via `component` + tag separator; if unattainable, accept the native format and record the divergence in the design.

## 2. `release.yml`

- [x] 2.1 Workflow skeleton: `on: push [main]` + `workflow_dispatch` (input: `dry_run`); `permissions: contents: write, packages: write`; env with pinned `OPM_CLI_VERSION`, **both** `OPM_REGISTRY` and `CUE_REGISTRY`; keep the existing concurrency group.
- [x] 2.2 `release-please` job (push only): the action pinned to the catalog's SHA, with config + manifest files.
- [x] 2.3 Advance step: fetch `release-please--branches--main` (absent → `exit 0`); loop manifest keys; `opm module version set <ver> ./<path>` where the declared version lags; single commit as `github-actions[bot]`; push. Comment carries D15's no-second-writer rationale.
- [x] 2.4 `publish` job, `workflow_dispatch` only (comment naming `modules-fleet-republish` as the change that widens it): install opm (checksum-verified tarball), `docker login ghcr.io`, then the sweep — per module resolve the declared version, `version_published` probe (ported verbatim, comment intact), skip when published, else `opm module publish ./<module>`; collect per-module failures and fail the job at the end.
- [x] 2.5 Delete the old `publish.yml` steps that the sweep replaces: discovery's publish-decision half, the yq/versions.yml version source, the path-major vs version-major check, the per-module `cue mod publish` loop, the `modules/<name>/<ver>` tagging, the `release/<date>` tag, release-notes rendering, and the GitHub Release creation.
- [x] 2.6 Keep and carry forward: `version_published`, the cross-train major separation guard (**repointed to `OTHER_BRANCH: v1`**), the `language.version` train check.

## 3. `ci.yml` (new — the repo validates nothing on PRs today)

- [x] 3.1 `on: pull_request` + `push [main]` + `workflow_dispatch`: checkout, CUE toolchain, `task check`.
- [x] 3.2 Install opm; per module `opm module publish --dry-run`, tolerating a lone already-published refusal (grep the CLI's `already holds` + refusal-count strings) and failing on any other.

## 4. Delete the ledger

- [x] 4.1 `Taskfile.yml`: remove `publish`, `publish:one`, `publish:dry`, `versions`, both `compute_checksum`, both `bump_version`, the `LOCAL_PUBLISH_REGISTRY`/`VERSION_FILE` vars and the local-registry forcing stanzas. `fmt`/`vet`/`tidy`/`check` untouched.
- [x] 4.2 Delete `versions.yml`.
- [x] 4.3 Verify no remaining reference: `grep -rn 'versions.yml\|compute_checksum\|bump_version' .` is clean outside `openspec/`.

## 5. Docs

- [x] 5.1 `CLAUDE.md`: Registry section (drop the stale "publishes on push to main" claim; state release-please + `opm module publish`, and that a local publish means pointing `OPM_REGISTRY` deliberately), Build-commands table (publish tasks gone), the stale nine-row module table, and the "Adding a new module" recipe (must name `identity/identity.cue` and the conventional-commit scope that drives its version).
- [x] 5.2 `README.md`: drop the `versions.yml` bullets; branch-table row for `main` describes the release-please flow.

## 6. Verify

- [ ] 6.1 **Post-merge** — `workflow_dispatch` is only available once the workflow is on the default branch, so the dry-run proof cannot precede the merge as originally sequenced. After merging: dispatch with `dry_run: true` and confirm the sweep resolves 20 declared versions and reports all 20 unpublished (the republish's expected input state). A failure here is fixed forward; the old path is gone by then, which is the accepted cost of doing this in one change.
- [ ] 6.2 **Post-merge** — a trivial conventional commit on one module opens a release PR, the advance step writes only that module's `identity.cue`, and CI's dry-run passes on the release branch.
- [x] 6.3 `task check` green.

## 7. Record

- [ ] 7.1 `enhancements/0011/`: slice → `done`, `openspec_ref: "modules/modules-publish-cutover"`, history event recording: release-please adopted for modules as a choice D15 permits (not requires); the manifest replaces `versions.yml` but only feeds forward; `OTHER_BRANCH` staleness fixed; both branch-model guards deliberately retained; no module-side post-publish verification exists (`registry check` is catalog-only); publish remains disabled on push, enablement is `modules-fleet-republish`.
