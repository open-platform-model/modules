## Gates (supervisor ticks; the worker never ticks these)

Hard-coded targets in this file (core `v2.0.0-beta.1`, catalogs/opm `4.4.4`, catalogs/k8s
`1.0.0-beta.1`): if a gate lands on a different version (burned tag), the recorded gate version
replaces it everywhere (G3, 1.2, 1.4, 4.1, 4.2, 4.3); the module versions in 4.3 and 4.4 do
not change.

Freeze (supervisor): no releasable core merge, and from G3 no releasable `opm/` merge in
catalog_opm, until the post-G3 `task deps:update` patches are saved. A core or catalogs/opm
release in that window would make the SUPERVISOR PATCH pin versions other than the gate
versions, and 1.2 then stops.

- [x] G3 `opmodel.dev/catalogs/opm@v4` `v4.4.4` (tag `opm-v4.4.4`) and `catalogs/k8s`
      `k8s-v1.0.0-beta.1` are on GHCR; implies G1 (`opmodel.dev/core@v2` `v2.0.0-beta.1` on
      GHCR). Unblocks section 1. Recorded: G1 core `v2.0.0-beta.1`, G3 catalogs/opm `v4.4.4`
      (tag `opm-v4.4.4`) and catalogs/k8s `v1.0.0-beta.1` (tag `k8s-v1.0.0-beta.1`); no burned
      tag, the hard-coded targets stand.
- [x] G6 The first cli release whose embedded operator is `v1.0.0-beta.1` is published with
      `opm-linux-amd64.tar.gz` and `checksums.txt` (expected `v1.0.0-beta.2`; the supervisor
      records the real tag here: `v1.0.0-beta.2`). Unblocks 3.1. Recorded: cli
      `v1.0.0-beta.2`, embedding opm-operator `v1.0.0-beta.1`.
- [x] SUPERVISOR PATCH (after G3): root `task deps:update` run on the main checkouts; the
      `modules/` diff saved as a patch file and handed to the worker (path recorded here:
      supervisor scratchpad `patches/run2-modules.patch`, root task run 2); `modules/` main
      checkout restored. Unblocks 1.1.
- [x] SUPERVISOR PR (after G6, merged before this change's PR): root
      `task deps:pins:opm-cli VERSION=<G6 tag>`, `modules/` diff only, as PR
      `ci: pin opm cli <G6 tag>` (squash type `ci`, carrier: no, no footer, merge gate G6, no
      release PR). Unblocks 3.1. Recorded: merged as #52 `ci: pin opm cli v1.0.0-beta.2`.
- [x] Release PR #50 is still open and unmerged, and carries the supervisor's hold comment
      (design.md D-5); it merges only after this change's PR (4.3). If #50 has been merged,
      stop: the expected versions in 4.3 each move up one patch and must be recomputed.

## 1. Fleet re-pin: all 8 `cue.mod/module.cue` files (supervisor patch)

- [x] 1.1 Apply the supervisor patch in the worktree: `git apply --check <patch>`, then
      `git apply <patch>`. Never regenerate or hand-edit the pins.
- [x] 1.2 Verify the diff per design.md D-1: exactly the 8 files `apprise`, `cert_manager`,
      `gotify`, `istio_ambient`, `k8up`, `metallb`, `ntfy`, `web_app` `/cue.mod/module.cue`,
      each changing only core `v2.0.0-alpha.13` -> `v2.0.0-beta.1` and catalogs/opm `v4.4.3`
      -> `v4.4.4`; `grep -rn "alpha" */cue.mod/module.cue` returns nothing. Any other shape:
      stop and report to the supervisor.
- [x] 1.3 `task tidy` leaves the tree unchanged (`git diff --stat` identical before and after).
- [x] 1.4 With the registry env exported on two lines (GHCR mapping): `task check` and
      `task vet CONCRETE=true` green, and `opm module publish ./<m> --dry-run` for all 8
      modules with the cli currently pinned in `.github/workflows/ci.yml` (installed and
      checksum-verified as CI does), each passing or refusing only with "already holds"
      (design.md D-3). Then commit
      `fix(deps): bump core to v2.0.0-beta.1 and catalogs/opm to 4.4.4`.

## 2. Durable decisions: repo docs

- [x] 2.1 `AGENTS.md` Branch model: the `main` row and the "You are on `main`" paragraph state
      that `main` publishes on push after the release PR merges, name `catalogs/opm@v4`, and
      carry the fleet versioning stance on the beta core in full (design.md D-4): a module
      break is `feat!` per Principle I and a new path major by identity major agreement, the
      cross-train rule only forbids colliding with the `v1` train's major, and a
      `task deps:update` crossing a core beta whose CHANGELOG has a `BREAKING CHANGE:` note is
      classified per module under Principle I, never a routine `fix(deps)`. The major
      separation rule names `release.yml`, not `publish.yml`.
- [x] 2.2 `AGENTS.md` Registry: replace "On `main` the publish job is dispatch-only until the
      v2 fleet republish enables it" with the running pipeline (sweep on every push to `main`,
      publishes versions GHCR lacks).
- [x] 2.3 `README.md` branch table, `main` row: `opmodel.dev/catalogs/opm@v4`, and the publish
      text matches 2.1 (no "publish-on-push is disabled").
- [x] 2.4 `DESIGN_PATTERNS.md` § Exact object names: the `catalogs/opm >= 2.0.0-alpha.7,
      enhancement 0019 D15` floor note becomes "every `catalogs/opm@v4` release". Module
      directories are not edited (proposal: separate docs change).
- [x] 2.5 `grep -n "dispatch-only\|still disabled\|publish-on-push is disabled\|Nothing publishes from here" AGENTS.md README.md`
      returns nothing; `task check` green and `opm module publish ./<m> --dry-run` for all 8
      modules as in 1.4, then commit
      `docs: describe publish on main and the fleet's beta-core stance`.

## 3. Gates under the G6 cli, then archive

- [x] 3.1 After the SUPERVISOR PR has merged: `git fetch origin && git merge origin/main`
      (never rebase); `.github/workflows/ci.yml` and `release.yml` now show
      `OPM_CLI_VERSION: '<G6 tag>'`. Done: both show `v1.0.0-beta.2`.
- [x] 3.2 Install the G6 cli into the scratchpad the way CI does (download
      `opm-linux-amd64.tar.gz` and `checksums.txt` from the cli release, `sha256sum -c`),
      and confirm `opm version` reports `<G6 tag>`. Done: checksum OK, `opm version`
      reports `1.0.0-beta.2`.
- [x] 3.3 `task check` and `task vet CONCRETE=true` green on the merged tree.
- [x] 3.4 `opm module publish ./<m> --dry-run` with the G6 cli for all 8 modules; each passes,
      or its only refusal is "already holds" (design.md D-3). Any other refusal is a stop:
      report it; a fix is a new module section with its own release class, never an
      amendment of the `fix(deps)` commit. Done: kernel loader accepted all 8; each refused
      only with "already holds" (the versions on `main`: 3.0.1, 2.0.4, 3.0.1, 2.0.4, 4.0.1,
      3.0.1, 3.0.1, 1.0.4).
- [x] 3.5 `openspec validate fleet-repin-beta --strict` passes.
- [x] 3.6 Verify the implementation against the artifacts (`openspec-verify-change` skill /
      `opsx:verify` pointed at this worktree); no CRITICAL finding remains. Done: the only
      open tasks are 4.2 to 4.4, supervisor steps that run after this PR merges by design.
- [x] 3.7 Confirm both durable decisions in design.md are landed (section 2), then
      `openspec archive fleet-repin-beta --skip-specs --yes`; no `openspec/specs/` directory
      is created; no `enhancement.yaml`, so no delivery logging.
- [x] 3.8 Commit `chore(openspec): archive fleet-repin-beta`.

## 4. Release delivery (worker opens the PR; supervisor merges)

- [x] 4.1 `git push -u origin beta/fleet-repin-beta`; open one PR titled
      `fix(deps): bump core to v2.0.0-beta.1 and catalogs/opm to 4.4.4`. Body at most 250
      words of prose, no commit list, no scope section, no test-plan list, every `@` inside
      backticks; it names the reviewer action: merge only after the SUPERVISOR PR, then merge
      #50 per design.md D-5. Done: opened as #51.
- [ ] 4.2 SUPERVISOR MERGE: squash type `fix(deps)`, carrier: NO, footer: none (abort if the
      squash body matches `release-as` in any case; no body line starts with `word(`; no bare
      `@`; the default `COMMIT_MESSAGES` body is replaced, design.md D-2). Squash subject
      `fix(deps): bump core to v2.0.0-beta.1 and catalogs/opm to 4.4.4 (#N)`. Merge gate: G3,
      G6, SUPERVISOR PR merged, branch up to date with `main`, `Validate modules` and
      `mention-guard` green.
- [ ] 4.3 SUPERVISOR: expected release PR is #50 `chore: release main` (title unchanged), now
      listing the new `bump core to v2.0.0-beta.1 and catalogs/opm to 4.4.4` line for all 8
      modules. Merge #50 only when all hold (design.md D-5): (a) its head commit is
      `chore: advance identity.Version to the released versions`, pushed after 4.2's merge;
      (b) on that head each `*/identity/identity.cue` Version is apprise 3.0.2, cert_manager
      2.0.5, gotify 3.0.2, istio_ambient 2.0.5, k8up 4.0.2, metallb 3.0.2, ntfy 3.0.2,
      web_app 1.0.5; (c) `Validate modules` is green on that SHA. Merge with
      `gh pr merge 50 --squash --match-head-commit <advance sha>`.
- [ ] 4.4 SUPERVISOR: watch the Release workflow's publish job and confirm GHCR holds all 8
      tags (v3.0.2, v2.0.5, v3.0.2, v2.0.5, v4.0.2, v3.0.2, v3.0.2, v1.0.5 for the modules in
      4.3's order). An "already published" skip line for any of them is a failure.
