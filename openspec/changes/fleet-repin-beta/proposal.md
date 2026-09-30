## Why

OPM cuts its first beta: `opmodel.dev/core@v2` releases `v2.0.0-beta.1` (gate G1) and
`opmodel.dev/catalogs/opm@v4` releases `4.4.4` on that core (gate G3). The fleet on `main` still
pins core `v2.0.0-alpha.13` and catalogs/opm `4.4.3`. Until it re-pins, every module published
from `main` is built on the retired alpha line, and the beta has no downstream proof that a
consumer module vets, passes every publish gate and renders on it.

The stated deliverable of this change is a fleet release on the beta core: eight patch
releases, published by CI after the supervisor merges release PR #50. It therefore uses the
schema's sole exception for release work, and tasks.md carries the delivery steps (verify,
archive, PR) that an ordinary module change leaves to the git workflow.

Two docs are wrong today and are fixed on the way: `AGENTS.md` and `README.md` say publishing
from `main` is disabled or dispatch-only, and name the catalog as `catalogs/opm` v2. In fact
`.github/workflows/release.yml` says "PUBLISHING IS ENABLED": the sweep runs on every push to
`main` and publishes every module whose `identity.Version` GHCR does not hold yet. An agent
that believes the stale text skips the release PR. `DESIGN_PATTERNS.md` § Exact object names
quotes a `catalogs/opm >= 2.0.0-alpha.7` floor that no longer means anything on the v4 path.

## What Changes

One pattern across all 8 CUE modules, plus repo docs:

- **All 8 module directories** (`apprise/`, `cert_manager/`, `gotify/`, `istio_ambient/`,
  `k8up/`, `metallb/`, `ntfy/`, `web_app/`): `cue.mod/module.cue` moves `opmodel.dev/core@v2`
  from `v2.0.0-alpha.13` to `v2.0.0-beta.1` and `opmodel.dev/catalogs/opm@v4` from `v4.4.3` to
  `v4.4.4`. The diff is a supervisor patch produced by the root `task deps:update` after G3;
  it is applied with `git apply`, never hand-edited. No `.cue` source, `#config` field,
  component or rendered object changes. Release class per module: `fix:` (`fix(deps)`).
- **`AGENTS.md`, `README.md`** (repo docs, no release): the Branch model row, the "You are on
  `main`" paragraph and the Registry section state that `main` publishes on push after the
  release PR merges; the catalog is `catalogs/opm@v4`; the fleet keeps stable per-module SemVer
  while it depends on the prerelease core line. The `publish.yml` name in the major separation
  rule becomes `release.yml`.
- **`DESIGN_PATTERNS.md`** (no release): the `catalogs/opm >= 2.0.0-alpha.7` floor in § Exact
  object names becomes "every `catalogs/opm@v4` release".

The CLI pin (`OPM_CLI_VERSION` in `.github/workflows/ci.yml` and `release.yml`) is not part of
this change: the supervisor moves it to the G6 cli tag in a separate `ci:` PR that lands on
`main` before this change's PR, so this PR's CI dry-runs every module with that CLI.

No module path major moves; the cross-train major separation rule is untouched.

## Before / After

No `#config` field or component changes. The review surface is the dependency block, identical
in all 8 `cue.mod/module.cue` files (the `module:` line keeps each module's own major).

**Before**

```cue
// <module>/cue.mod/module.cue
language: {
	version: "v0.17.0"
}
deps: {
	"opmodel.dev/catalogs/opm@v4": {
		v: "v4.4.3"
	}
	"opmodel.dev/core@v2": {
		v: "v2.0.0-alpha.13"
	}
}
```

**After**

```cue
// <module>/cue.mod/module.cue
language: {
	version: "v0.17.0"
}
deps: {
	"opmodel.dev/catalogs/opm@v4": {
		v: "v4.4.4"
	}
	"opmodel.dev/core@v2": {
		v: "v2.0.0-beta.1"
	}
}
```

Rendered objects: expected unchanged for all 8 modules. Core `v2.0.0-beta.1` carries the
`v2.0.0-alpha.13` schema content, and catalogs/opm `4.4.4` is a `fix(deps)` re-pin of `4.4.3`
onto it. The fleet-wide `task vet CONCRETE=true` and per-module publish dry-runs prove it.

## Catalog contract

- Requires `opmodel.dev/core@v2` `v2.0.0-beta.1` and `opmodel.dev/catalogs/opm@v4` `v4.4.4`,
  both on GHCR (G3 implies G1). catalogs/opm `4.4.4` itself depends on core `v2.0.0-beta.1`,
  so both pins agree under MVS.
- `task deps:update` from the workspace root MUST run first, after G3, and only the supervisor
  runs it. Core has no stable v2 release, so `cue mod get opmodel.dev/core@v2` resolves the
  highest prerelease (beta sorts above alpha); catalogs/opm@v4 resolves its newest stable. The
  task swallows failures (`|| true`), so the patch MUST be read before it is applied.
- No catalog member is missing; no `k8s-*` passthrough is introduced. `catalogs/k8s` is pinned
  by no module here, so its beta does not reach this repo.

## Impact

- **All 8 modules**: `fix(deps)` patch release each, through release PR #50 (`chore: release
  main`): apprise 3.0.2, cert_manager 2.0.5, gotify 3.0.2, istio_ambient 2.0.5, k8up 4.0.2,
  metallb 3.0.2, ntfy 3.0.2, web_app 1.0.5. #50 already holds these versions for the alpha-era
  `fix(deps)` commits; this change adds one changelog line per module and does not change the
  bump size. Module versions stay stable SemVer: no `Release-As`, no prerelease config.
- No path major moves. Operators do nothing: an instance pinned to the new versions resolves
  core beta from GHCR, and a platform still pinned to core alpha sees the library skew warning
  (default warn), which the operator and cli platform-pin bumps elsewhere in the cutover clear.
- `v1` and `v0_legacy` are untouched. The active change `move-media-gpu-modules-to-jacero` is
  not touched.

## Enhancement

None. The beta cutover implements no enhancement decision, so this change has no
`enhancement.yaml`.
