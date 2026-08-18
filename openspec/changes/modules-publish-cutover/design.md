# Design — modules-publish-cutover

## Overview

```
push to main
   │
   ├─► release-please (20 packages, one combined PR)
   │      writes CHANGELOGs + .release-please-manifest.json  ← decides versions
   │      advance step, on the release branch:
   │        for each path where manifest ≠ declared identity Version:
   │          opm module version set <ver> ./<path>     ← the ONLY writer (D15)
   │        commit as github-actions[bot], push to the release branch
   │
   └─► (merge the release PR → per-module tags + GitHub releases)

workflow_dispatch          ← publish stays off the push path until the republish
   │
   └─► publish sweep, per module:
          version = declared Version (cue eval ./identity)
          published(repo, v$version)?  ── yes ─► skip (caller-side filter, D15)
                                        └─ no ─► opm module publish ./<module>
```

The whole shape is `catalog_opm`'s, fanned out. Nothing in the CLI changes; nothing about coordinates changes (D13).

## Research & Decisions

### The sweep filters by registry lookup, not by release-please output

**Context**: publish never skips — an already-published tag is always a refusal (D15), so the caller must filter. Two candidate filters: release-please's `paths_released` output, or a registry probe per module.
**Decision**: the registry probe, ported from the existing workflow's `version_published` and matching `cli/.github/scripts/publish-templates.sh` (the same fleet-sweep pattern, already in production for the template modules).
**Rationale**: it is D15's own wording — *"The filter is a registry lookup, so nothing is predicted and no ledger is consulted"* — and it is the only filter that also serves the initial fleet republish, where release-please has released nothing (all 20 declared versions are already correct and simply unpublished). One mechanism covers both the steady state and the one-time sweep. `paths_released` would have needed a second, divergent path for the republish.
**Keep the existing probe verbatim.** Its comment records a measured trap: GHCR's `/v2/` API rejects HTTP Basic auth, so `curl -u` always 401s, which a naive implementation reads as *unpublished* and republishes everything. It exchanges the token properly and fails the run on any status that is neither 200 nor 404.

### The advance step loops the manifest

**Context**: the catalog's advance step reads a single-key manifest (`jq -r '."."'`) on a branch named `release-please--branches--main--components--catalog_opm`. With 20 packages and one combined PR, the branch is `release-please--branches--main` and the manifest has 20 keys.
**Decision**: fetch the release branch (missing branch → clean `exit 0`); for each manifest key, compare the manifest version against the module's declared `Version`; where they differ, `opm module version set <version> ./<path>`; commit once if anything changed (`git diff --quiet` is the no-commit path), push to the release branch.
**Rationale**: `version set` is idempotent and offline by design, so looping it over 20 modules is cheap and the diff-empty guard makes reruns free. One commit for the whole advance keeps the release PR readable. The comment must carry the reason release-please does not write `identity.cue` itself (D15: a second writer beside `version set` is exactly the drift this design removes).

### Publish disabled on push; enablement is one condition

**Decision**: `on: push: [main]` drives the release-please job only. The publish job is `if: github.event_name == 'workflow_dispatch'`, carrying a comment naming `modules-fleet-republish` as the change that widens it.
**Rationale**: the plan's branch model says publish-on-push is disabled on `main` "until the v2 fleet exists (a deliberate enablement step)". Landing the pipeline complete-but-dispatch-only means the republish is a single reviewed line rather than a new workflow, and the release-please half starts working immediately without publishing anything.

### Manifest seeding and tags

Seed `.release-please-manifest.json` from the declared versions, which the exploration verified agree with `versions.yml` and with each module's `cue.mod` path major for all 20 — nothing to reconcile. Set `bootstrap-sha` to the fleet-port commit so changelog generation does not scan the pre-v2 history.

**Tag format is a known, accepted divergence.** Existing tags are `modules/<name>/vX.Y.Z`, created by the machinery being deleted. release-please's monorepo tags are `<component>-vX.Y.Z`; a `component` of `modules/<name>` plus a `/` tag separator would reproduce the old shape exactly, and the implementation should try that first. If it does not hold, accept release-please's native format for new tags: git tags here are navigation, the registry is the record, and historical tags are untouched either way.

### The two guards stay; one goes

The cross-train major separation guard and the `language.version` train check exist because `v1` and `v0_legacy` publish the same registry paths from other branches. Those branches survive this change, and the guard gets *more* load-bearing at republish time — the first moment two trains publish into overlapping paths — so both stay, and retire with the branches later. The path-major/version-major check goes: `opm module publish` refuses that condition natively (0011 D18), and a bash re-implementation of a shipped refusal is exactly the redundancy the cutover exists to remove.

Repointing `OTHER_BRANCH` from `v0_legacy` to `v1` is a bug fix, not a scope addition: `main`'s majors were chosen to dodge the live v1 train (hence `jellyfin@v3`, `k8up@v3`), which is the comparison the guard is meant to make and currently does not.

### CI on pull requests

The repo validates nothing on a PR today. `ci.yml` runs `task check` and then, per module, `opm module publish --dry-run`, treating a lone already-published refusal as acceptable (the version may legitimately be live on a PR) and every other refusal as a failure — the tolerance pattern from `catalog_opm/.github/workflows/ci.yml` and `publish-templates.sh`, both of which grep the CLI's own `already holds` + refusal-count strings.

## Technical Notes

- **CLI provisioning**: the catalog's checksum-verified tarball block (download `opm-linux-amd64.tar.gz` + `checksums.txt` from the pinned cli release, `sha256sum -c`, install to `/usr/local/bin`), with `OPM_CLI_VERSION` pinned at workflow level and bumped deliberately.
- **`OPM_REGISTRY` is required and currently absent.** `opm` resolves `--registry > OPM_REGISTRY > ~/.opm/config.cue` and **never** reads `CUE_REGISTRY`; with only `CUE_REGISTRY` set it silently falls through to the runner's (empty) personal config. Both get set, as `publish-templates.sh` documents.
- **Credentials**: `docker login ghcr.io` with `GITHUB_TOKEN` — `opm`'s push reads the docker credential chain (`opm registry login` is interactive-only by design).
- **release-please action**: pin the same action and SHA `catalog_opm` uses, since this mirrors its flow. (The workspace currently runs two pins — catalog on v4.4.1, cli and opm-operator on v5.0.0; noted as a cleanup candidate, not resolved here.)
- **Excluded directories**: `cdi/` and `snapshot_controller/` have no `cue.mod` and no CUE — every loop already skips them; the release-please config must not list them.
- **Deletions ripple into docs**: `README.md`'s `versions.yml` bullets and branch table row, `CLAUDE.md`'s Registry section, module table, and Build-commands table.
