# Branches, versioning and GHCR

Covers how a change picks its branch, how a module version and path major are chosen, how pins
move, and how GHCR versions are cleaned up. The branch table and the never-merge rule are in
`AGENTS.md`.

## Pick the branch

- A change for the live v1 fleet is a `v1` change. Check the branch before you scaffold anything.
- The legacy tree publishes `opmodel.dev/modules/jellyfin@v1` from a directory with a version
  suffix, and the v1 train's directory of the same module publishes `@v2`. Directory names differ,
  the registry path is the same.

## Major separation

When you promote a module from an older train, bump its path major past that train's line. A guard
in the release workflow (`.github/workflows/`) enforces the rule. `main`'s majors were chosen to dodge the
live v1 train, so some modules sit at a higher major than their history suggests. The rule retires
with the `v1` branch.

A proposal that moves a path major states it and says it obeys this rule.

## Fleet versioning on the beta core

The fleet depends on the prerelease `opmodel.dev/core@v2` line and the stable
`opmodel.dev/catalogs/opm@v4`. Module versions stay stable SemVer.

- A new path major must not collide with a major the `v1` train publishes.
- While core is on beta, core may break on the same path as a `feat!` that advances the beta
  number, and `cue mod get` takes the highest prerelease. A `task deps:update` that crosses a core
  release whose changelog carries a `BREAKING CHANGE:` note needs this: read the note, re-render the
  affected modules and classify each one before you choose the commit type.

## Pins

`task deps:update` moves pins only within the major a dep already declares. A major-crossing bump
(for example `catalogs/opm` v2 to v4) is `cue mod get <path>@vN.0.0` and then `cue mod tidy` in each
module. That is the same pin writer the task wraps, not a hand edit. If tidy leaves the stale entry
of the old major (major-less imports are ambiguous with two majors present), remove that dep block
and rerun `cue mod tidy`. Check that exactly one entry for the path remains. After the crossing,
`task deps:update` owns in-major bumps again.

## GHCR cleanup

A GHCR package is per registry path. The package for a module carries the `v0_legacy` versions, the
`v1` versions and the `main` versions side by side, and `v1` keeps publishing into it. Delete
versions by id, tag by tag.

The tool is in `hack/`. It is a dry run by default, `--apply` deletes, and it deletes only the tags
in its table. Append every applied run to the deletion record in `hack/`: date, package, tags and
version ids. Deletions are irreversible, so that record is the audit trail.

## Pitfalls

- Choosing `fix(deps)` for a dep bump that crosses a breaking core release.
- Deleting a GHCR package to retire a train. Delete versions.

## Check before you finish

- [ ] The change targets the branch of the line it fixes.
- [ ] A path major that moves does not collide with a major of the other train.
- [ ] Each applied GHCR deletion is recorded in `hack/`.
