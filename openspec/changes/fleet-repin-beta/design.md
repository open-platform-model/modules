## Context

See `proposal.md` for motivation. Current state on `main` (`ebf7426`): all 8 CUE modules pin
`opmodel.dev/core@v2` `v2.0.0-alpha.13` and `opmodel.dev/catalogs/opm@v4` `v4.4.3` in
`<module>/cue.mod/module.cue`; `OPM_CLI_VERSION` is `v1.0.0-alpha.27` in
`.github/workflows/ci.yml` and `release.yml`. Release PR #50 (`chore: release main`) is open with
patch bumps for all 8 modules and identity files already advanced on its branch.

Files touched:

- `<module>/cue.mod/module.cue` for `apprise`, `cert_manager`, `gotify`, `istio_ambient`,
  `k8up`, `metallb`, `ntfy`, `web_app` (supervisor patch only).
- `AGENTS.md` (Branch model table, "You are on `main`" paragraph, major separation rule,
  Registry section), `README.md` (branch table row for `main`), `DESIGN_PATTERNS.md`
  (§ Exact object names floor note).

`DESIGN_PATTERNS.md` patterns in play: none are used or changed; the edit there is a version
note only.

Release mechanics this design relies on (`.github/workflows/release.yml`): release-please
(`release-type: simple`, one combined PR) attributes a commit to every package directory it
touches; the advance step writes `identity.Version` with `opm module version set` on the release
branch; the publish sweep runs on every push to `main` and publishes each module whose
`identity.Version` GHCR does not hold. A `fix(deps)` push therefore publishes nothing by itself;
the merge of #50 does.

## Goals / Non-Goals

**Goals:**

- Every module resolves core `v2.0.0-beta.1` and catalogs/opm `v4.4.4`; no alpha core pin
  remains in any `cue.mod/module.cue`.
- Every module passes `task check`, `task vet CONCRETE=true` and every publish gate
  (`opm module publish --dry-run`) under the G6 cli, the CLI CI uses to publish.
- The repo docs describe the publish pipeline that actually runs and the fleet's versioning
  stance on the beta core.

**Non-Goals:**

- No CLI pin change here: `OPM_CLI_VERSION` moves in the supervisor's separate `ci:` PR
  (root `task deps:pins:opm-cli`), which lands first.
- No module goes prerelease: no `Release-As` footer, no `prerelease` key in
  `release-please-config.json`, no hand edit of `.release-please-manifest.json` or
  `identity/identity.cue`.
- No `#config`, component or rendered-object change; no module path major moves.
- No change to `v1`, `v0_legacy`, the `opm-modules` fleet, or the active change
  `move-media-gpu-modules-to-jacero`.

## Decisions

### D-1: The pins come from the supervisor's `task deps:update` patch

The constitution routes dependency pins through the root `task deps:update`. That task writes
every repo's main checkout and never a `.claude/worktrees` checkout, so in the beta cutover only
the supervisor runs it (after G3), keeps the `modules/` diff as a patch file, and restores the
main checkout. This change applies that patch in the worktree with `git apply` and commits it.

The patch MUST touch exactly the 8 `cue.mod/module.cue` files and, in each, exactly the two
`v:` lines shown in the proposal's After block. Anything else (a changed `language.version`, a
dropped or added dep, a `catalogs/opm` or `core` version other than `v4.4.4` /
`v2.0.0-beta.1`) is a stop: report it to the supervisor rather than editing around it. The
task's `|| true` means a failed resolution shows up only as a missing line in the diff.

Alternatives: running `cue mod get` per module in the worktree (rejected: the canon reserves
dependency pin writes to the supervisor's root task run); hand-editing (rejected: the
constitution forbids it).

### D-2: One PR, squashed by the supervisor as a single `fix(deps)` commit, no footer

The branch carries two section commits (`fix(deps)` for the pins, `docs:` for the text) plus the
plan and archive commits. The supervisor squash-merges the PR with the subject
`fix(deps): bump core to v2.0.0-beta.1 and catalogs/opm to 4.4.4 (#N)` and no `Release-As`
footer. The squash touches all 8 module directories, so release-please adds one `fix(deps)`
line to each module's section of #50; the root docs and `openspec/` belong to no package and
release nothing. This PR is not a carrier: the fleet stays on stable SemVer and the supervisor
aborts the merge if the squash body contains `release-as` in any case.

The squash body MUST have no line that starts with an identifier followed by `(` (release-please
drops such a commit) and no bare `@` token (write `opmodel.dev/core@v2`, glued).

### D-3: The G6 cli pin lands first; this PR's CI proves the gates

The CI dry-run step (`.github/workflows/ci.yml`, "Publish gates dry-run") installs
`OPM_CLI_VERSION` and runs `opm module publish --dry-run` per module, accepting only an
"already holds" refusal. Ordering the supervisor's `ci:` pin PR before this one means the PR
runs every gate with the CLI that will publish the fleet after #50 merges. The worker brings
the branch up to date with `git merge origin/main` once that PR has landed, and runs the same
dry-run locally with the same CLI tag (installed from the cli GitHub release into a scratch
directory, checksum-verified as CI does).

A dry-run on this branch may refuse with "already holds": the module's `identity.Version` on
`main` (e.g. apprise 3.0.1) is already on GHCR, and the new versions exist only on #50's
branch. That is the one acceptable refusal, as in CI. Every other refusal is a stop.

### D-4: Docs state the running pipeline and the fleet's beta stance

`AGENTS.md` and `README.md` are corrected to what `release.yml` does. Replacement text (grammar
adapted to each file):

> `main` publishes: the release workflow's publish sweep runs on every push to `main` and pushes
> each module whose `identity.Version` GHCR does not hold yet, so a module ships when the
> release-please PR that advances its version merges. The fleet depends on the prerelease
> `opmodel.dev/core@v2` line (beta) and stable `opmodel.dev/catalogs/opm@v4`; module versions
> stay stable SemVer, and a break in a module is still a new path major under the cross-train
> major separation rule.

The `DESIGN_PATTERNS.md` floor note reads "(every `catalogs/opm@v4` release)" in place of
"(`catalogs/opm` >= 2.0.0-alpha.7, enhancement 0019 D15)".

## Research & Decisions

### Does `deps:update` land core on the beta?

**Context**: `cue mod get <path>@vN` picks the latest version in the major; the pin must move
off the alpha without an explicit version.
**Explored**: cutover research (`cmd/cue/cmd/modget.go` and `internal/mod/modload/query.go` at
cue v0.17.1): prereleases are ignored only when a stable version of the major exists.
**Decision**: Rely on `deps:update` for both pins, and verify the patch (D-1).
**Rationale**: core@v2 has no stable release, so the highest prerelease wins and `beta.1` sorts
above `alpha.13`; catalogs/opm@v4 has stables, so it lands on `4.4.4`.

### Which CLI can publish modules pinned to core beta?

**Context**: The publish gates load the module with its own `cue.mod` deps and check identity
against the CLI's embedded core schema.
**Explored**: `cli/internal/cmdutil/publish.go` (identity schema from the CLI's library),
`cli/internal/publish/kernel_gate.go` (loads the module's own deps); `opm-modules` CI today
passes modules pinned to core alpha.13 with a CLI embedding core alpha.7.
**Decision**: Use the G6 cli (library `v1.0.0-beta.1`, core beta schema), pinned first.
**Rationale**: Any working CLI would likely pass, but the G6 cli is the one that publishes the
fleet, so the PR's gates should be its gates.

### Merge #50 before or after the bump?

**Context**: #50 holds alpha-era patch bumps for all 8 modules.
**Decision**: Leave #50 open; the supervisor merges it after this PR, so the fleet publishes
once, pinned to beta.
**Rationale**: GHCR tags are immutable; merging first would publish 8 alpha-pinned versions that
the next release immediately supersedes.

## Risks / Trade-offs

- [The patch resolves a different version (core beta.2 already out, catalogs/opm 4.4.5)] ->
  D-1 stop rule; the supervisor decides whether the newer pin is acceptable and regenerates.
- [A module fails vet or a publish gate on the beta core] -> the section does not commit; the
  worker reports the diagnostic. A real schema break is a core or catalog defect, not a module
  workaround (Principle III).
- [#50 is merged before this PR by mistake] -> 8 alpha-pinned versions publish, and this PR
  yields a second patch release per module. Only the supervisor merges; the gate list says so.
- [Squash body picks up an inner commit's text with a `word(` line or a bare `@`] -> the
  supervisor writes the squash message (D-2) and scans it before merging.
- [Platform pins still on core alpha when instances render these modules] -> skew warning only
  (default warn); cleared by the operator and cli platform-pin changes in the same cutover.

## Durable decisions

- **`main` publishes on release-PR merge**: the publish sweep runs on every push to `main` and
  ships each module whose declared version GHCR lacks. Lands in `AGENTS.md` (Branch model,
  Registry) and `README.md` (branch table).
- **Fleet versioning on the beta core**: modules keep stable SemVer while depending on the
  prerelease `core@v2` line; a module break is still a new path major. Lands in `AGENTS.md`
  (Branch model).
