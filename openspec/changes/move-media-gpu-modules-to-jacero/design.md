## Context

Twelve module directories leave this repo for `opm-modules/` (workspace sibling, git
`github.com/emil-jacero/opm-modules`, empty and public today). See proposal.md for why and
for the exact list. State that shapes the approach:

- Each module is three agreeing copies of one path: `cue.mod/module.cue` `module:`,
  `identity/identity.cue` `ModulePath`, and the `identity` import in `module.cue` (the only
  file that imports it; `components.cue` never does). The publish gates check the three
  agree, and `identity.cue` is written only by tooling (`CLAUDE.md`, `DESIGN_PATTERNS.md`
  § 13 Module Identity).
- `opm mod init <path> --yes` run inside an existing tree is repair mode (cli
  `internal/scaffold/repair.go`): it realigns only the `module:` line of `cue.mod/module.cue`
  (deps untouched) and `ModulePath` in `identity/identity.cue`, and REFUSES while any `.cue`
  file still imports the old path. It never rewrites imports in a tree the author owns.
- `opm module version set` writes only the `Version` value; comments survive byte for byte.
- `release.yml` here publishes whatever `identity.Version` declares when the registry does
  not hold that tag, independent of release-please; release-please only decides the next
  version from conventional commits and the manifest.
- The GHCR package is per registry path, not per branch: `opmodel.dev/modules/jellyfin`
  holds v1.0.x (v0 train), v2.x (v1 train, still publishing on push) and v3.x (`main`).
- `metadata.uuid` derives from the fqn; a `#ModuleInstance`'s uuid derives from the
  major-free `registryPath` plus name and namespace (`core/src/module_instance.cue`), and the
  opm-operator's prune skips live objects whose `module-instance.opmodel.dev/uuid` disagrees.

Files touched here: the twelve directories (deleted), `release-please-config.json`,
`.release-please-manifest.json`, `README.md`, `CLAUDE.md` § Current modules, new
`hack/ghcr-delete-versions.sh` plus its run record. Files created in `opm-modules/`:
`Taskfile.yml`, `.github/workflows/{ci,release}.yml`, `release-please-config.json`,
`.release-please-manifest.json`, `CLAUDE.md`, `DESIGN_PATTERNS.md`, `README.md`,
`.gitignore`, and the twelve module directories. Workspace root `CLAUDE.md`: one routing row.
No `DESIGN_PATTERNS.md` pattern changes; § 13 Module Identity is the pattern in play.

## Goals / Non-Goals

**Goals:**
- Every migrated module publishes `jacero.se/modules/<name>@v1` at `v1.0.0` from
  `opm-modules` CI, rendering byte-for-byte what `main` renders today.
- `main` here is releasable after every section: the fleet that stays is untouched, and
  release-please never sees a package it cannot find.
- The `main`-published GHCR versions of the twelve paths are gone at the end, and nothing
  else on those packages is.

**Non-Goals:**
- Preserving per-module git history in the new repo (it stays here, in `main`'s history and
  on the `v1` branch). A one-line origin note in each identity file replaces it.
- Any change to `#config`, components, rendered objects, or catalog pins.
- Touching the `v1` or `v0_legacy` branches, or any GHCR tag they published.
- Rewriting the org's consumers (opm-kind-demo, operator sample, cli QUICKSTART); that is the
  separate change section 4 waits for.

## Decisions

### D1. Re-identify by copy plus repair, not by re-scaffold from the published donor

Per module, in `opm-modules/`:

```sh
cp -r ../modules/jellyfin ./jellyfin && rm ./jellyfin/CHANGELOG.md
sed -i 's|"opmodel.dev/modules/jellyfin/identity"|"jacero.se/modules/jellyfin/identity"|' jellyfin/module.cue
opm mod init jacero.se/modules/jellyfin@v1 --dir ./jellyfin --yes   # repair: cue.mod module line + identity ModulePath
opm module version set 1.0.0 ./jellyfin
(cd jellyfin && cue mod tidy)                                      # no-op expected; proves the pins survived
opm module publish --dry-run ./jellyfin
```

Result, the only diff against `main`:

```cue
// cue.mod/module.cue
module: "jacero.se/modules/jellyfin@v1"   // deps block unchanged: catalogs/opm@v4 v4.0.0, core@v2 v2.0.0-alpha.6

// identity/identity.cue
ModulePath: "jacero.se/modules/jellyfin@v1"
Version:    "1.0.0"

// module.cue
import id "jacero.se/modules/jellyfin/identity"
```

The sed runs first because repair refuses while the old self-import exists. Alternative:
`opm mod init jacero.se/modules/jellyfin@v1 --from opmodel.dev/modules/jellyfin@v3`, which
clones the published artifact and rewrites imports wholesale. Rejected: it fetches the
artifact instead of the tree we can read, and whether `README.md` and `DEPLOYMENT_NOTES.md`
travel inside the artifact is not something this change should depend on. The working tree
IS the published tree (manifest and identity agree for all twelve), so copying it loses nothing.

### D2. Stale train comments are rewritten by hand, once

`identity/identity.cue` and the `module.cue` header of every migrated module explain their
major with the cross-train rule ("Major v3: the v1 train already publishes ... at v2"). That
sentence is false at the new path. `version set` preserves comments, so the comment is the one
hand edit in the identity file, replaced by:

```cue
// ModulePath is the module's complete CUE module path, major suffix included
// — byte-identical to cue.mod's `module:` field. Migrated 2026-09 from
// opmodel.dev/modules/jellyfin@v3 (open-platform-model/modules, v3.0.3);
// this path starts its own line at v1.
ModulePath: "jacero.se/modules/jellyfin@v1"
```

The new repo's `CLAUDE.md` keeps the rule that tooling is the only writer of the values.

### D3. Version reset lands through the existing publish sweep, no release-please round trip

`.release-please-manifest.json` in `opm-modules` is seeded with `"<name>": "1.0.0"` for all
twelve, and `identity.Version` is `1.0.0`. On the first push to `main` the publish job finds
no `v1.0.0` tag and publishes it; release-please, seeing the manifest already at 1.0.0 and a
`feat` commit, opens its first PR for 1.1.0 only when a later commit warrants it. The
`bootstrap-sha` is the repo's first commit so release-please never scans an empty history.
Alternative: seed the manifest at `0.0.0` and let release-please cut 1.0.0. Rejected: it
needs a `feat!` and a merged release PR before anything is consumable, and `1.0.0` is what the
user asked to start from.

### D4. `opm-modules` CI is this repo's CI with three edits

Copy `ci.yml` and `release.yml`, then:

```yaml
OPM_CLI_VERSION: 'v1.0.0-alpha.19'                     # newest cli release, not alpha.14
OPM_REGISTRY: 'jacero.se=ghcr.io/emil-jacero,opmodel.dev=ghcr.io/open-platform-model,registry.cue.works'
CUE_REGISTRY: (same value)
# release.yml only:
ORG: 'emil-jacero'
# version_published(): base="${ORG}/jacero.se/modules/${repo}"
# delete the "Cross-train major separation guard" step and OTHER_BRANCH: one train.
```

The publish sweep's registry probe is the one place the namespace is spelled out, so the
`opmodel.dev` literal in `base=` must change or every run republishes nothing and reports
success. `docker login ghcr.io` with `GITHUB_TOKEN` stays; the token can push to the repo
owner's packages. `Taskfile.yml` gets the same mapping in `CANONICAL_REGISTRY`, dropping the
`testing.opmodel.dev=localhost:5000` entry that belongs to org fixtures.

### D5. Package visibility is verified, not assumed

A package first published by a workflow with `GITHUB_TOKEN` is linked to the repo and takes
its visibility, which is public. That is a platform behaviour, not something the pipeline
enforces, so section 2 closes with an anonymous pull (`cue mod get jacero.se/modules/jellyfin@v1`
from a shell with no GHCR login) and each package's visibility read back from the API.

### D6. Removal here is one `chore(fleet)` commit that also drops release-please entries

Deleting a directory while it is still in `release-please-config.json` makes the next release
run fail on a missing package. The directories, both release-please files, `README.md` and
`CLAUDE.md` § Current modules move in one commit, `chore` so nothing releases (a removal is
not a bump of anything that still exists). `bootstrap-sha` is untouched.

### D7. GHCR cleanup deletes versions by id, never packages

`hack/ghcr-delete-versions.sh` takes the package/tag table from proposal.md § Impact,
resolves each tag to a version id through
`GET /orgs/open-platform-model/packages/container/opmodel.dev%2Fmodules%2F<name>/versions`,
and issues `DELETE .../versions/<id>`. Dry-run by default (`--apply` to delete), refuses any
tag outside the table, prints the id/tag pairs it acted on, and requires the `delete:packages`
scope (the author's `gh` token has it). Alternative: `DELETE /orgs/.../packages/container/<name>`.
Rejected: it removes the v1 and v0 train tags too, and the `v1` branch still publishes there.
The script stays in `hack/` after archive; the v0-only package cleanup can reuse it.

### D8. Sections 1 and 2 commit in `opm-modules`, and the change says so

The schema scopes a section's commit to a module directory here. The deliverable of this
change is a publishing operation across two repos, which is the schema's stated exception,
and pretending sections 1 and 2 are local would hide where the work lands. The root
`CLAUDE.md` routing row is part of section 1 so a later session finds the repo.

## Research & Decisions

### Repair mode as the rename tool
**Context**: No `opm` command renames a module path; hand-editing identity is forbidden here.
**Explored**: cli `internal/cmd/module/init.go` and `internal/scaffold/repair.go`. Repair
realigns `cue.mod` `module:` and identity `ModulePath` to the path argument, keeps the deps
block, sources nothing it is not given, and refuses while self-imports of the old path exist
(`cueedit.ListSelfImports`). `--yes` skips the second confirmation; a non-TTY without it refuses.
**Decision**: D1.
**Rationale**: The repair path is the tool-supported rename; the only manual step it demands
(the import) is a single line per module.

### What the GHCR packages hold
**Context**: "Remove the original packages" could mean packages or versions.
**Explored**: `gh api orgs/open-platform-model/packages/container/<pkg>/versions` for all
twelve, cross-checked in section 3 against each module's `main` CHANGELOG and the `v1`
branch's `cue.mod` majors. Every package carries tags from two or three trains. `main`'s are
v3.0.1 to v3.0.3 for jellyfin (the `v1` branch owns its v2.x), v2.0.1, v2.0.2 and v3.0.0 for
jellystat, jellyswarrm and fileflows (released from `main` before their major bump; the `v1`
branch owns their v1.x), and v2.0.1 to v2.0.3 for the other eight (`v1` owns v1.x, `v0_legacy`
the v0.0.x and untagged versions). The `v1` branch still publishes on push into the same
packages. The proposal's first table listed only v3.0.0 for the three; corrected in section 3.
**Decision**: D7.
**Rationale**: Deleting packages would delete the live v1 line.

### Domain and registry mapping
**Context**: The new path needs a domain nobody else can claim and a registry to resolve from.
**Explored**: `jacero.se` has nameservers (Cloudflare); `jacero.io` has none. cli
`internal/publish/gates.go` `gateNamespace` is silent outside `opmodel.dev` and
`community.opmodel.dev`. Unmapped domains fall through to `registry.cue.works` in the cli
config, the operator's `--registry` default, and this repo's Taskfile.
**Decision**: `jacero.se/modules/<name>@v1`, mapped `jacero.se=ghcr.io/emil-jacero`
(confirmed by the user 2026-09-13).
**Rationale**: Mirrors the `opmodel.dev` layout, package names stay readable
(`ghcr.io/emil-jacero/jacero.se/modules/jellyfin`), and the gates impose nothing.

### Instance identity across the path change
**Context**: Whether re-pointing a running ModuleInstance is safe.
**Explored**: `core/src/module_instance.cue` (uuid from `registryPath:name:namespace`),
`opm-operator/internal/apply/prune.go` (uuid mismatch skips the delete).
**Decision**: Treat adoption as an operator-side precondition of the cutover, verified in
kind before any real instance moves; the 10-day deletion clock starts at that cutover.
**Rationale**: Prune cannot destroy data across the change, but adoption on apply was not
verified and this change cannot verify it without the operator's cluster.

## Risks / Trade-offs

- [Repair refuses on a module whose `components.cue` grows a self-import later] -> the sed in
  D1 targets `module.cue` only because inspection showed it is the sole importer today; the
  task greps all `.cue` files before running repair.
- [First publish creates a private package] -> D5 verification; fix visibility in the GitHub
  UI before section 2 closes.
- [`bootstrap-sha` left at this repo's value in the copied config] -> section 1 sets it to
  the new repo's first commit explicitly; a wrong sha makes release-please walk the wrong history.
- [Registry probe still spelled `opmodel.dev` in the copied `release.yml`] -> D4 names the
  line; section 1's dry-run dispatch shows "already published" for nothing, which is the tell.
- [A consumer in this workspace still pins a deleted version when section 4 runs] -> section 4
  starts with a grep across the workspace for `opmodel.dev/modules/<name>@v<main-major>` and
  refuses to proceed on a hit; the consumer-rewrite change is the fix.
- [The operator's cutover re-labels resources under a new instance uuid and apply refuses to
  adopt] -> the cutover checks it in kind first (above); prune cannot delete across it.
- [10-day wait spans sessions] -> the change stays active; section 4's first task is a dated
  precondition the calendar reminder points at.

## Durable decisions

- `opmodel.dev/modules/*` is business and enterprise only; personal modules live at
  `github.com/emil-jacero/opm-modules` under `jacero.se/modules/<name>` -> `CLAUDE.md` § Purpose
  and § Current modules here, and `README.md`.
- `opm-modules/` is a workspace repo -> one row in the workspace root `CLAUDE.md` repo table.
- The identity, release and registry rules travel with the modules -> `opm-modules/CLAUDE.md`
  (copied from here, branch model and cross-train rule removed).
- GHCR cleanup deletes versions, never packages, while any branch still publishes into the
  package -> `hack/ghcr-delete-versions.sh` header comment and `CLAUDE.md` § Registry here.
- Repair mode (`opm mod init <path> --yes` after fixing the self-import) is the way to move a
  module between paths -> `DESIGN_PATTERNS.md` § 13 Module Identity, one paragraph.

## Open Questions

- Does the `v1` branch fleet still run anywhere? It changes nothing here (D7 keeps its tags)
  but decides whether the v0/v1 package cleanup is ever safe.
