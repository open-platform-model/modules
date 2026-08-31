## Why

`opmodel.dev/catalogs/opm@v4` shipped as `4.0.0` (tag `opm-v4.0.0`, 2026-08-31). The fleet still
pins `opmodel.dev/catalogs/opm@v2` at `v2.0.0-alpha.7`, a pre-final alpha. This is the re-pin the
archived `2026-08-30-modules-drop-legacy-secrets` change deferred ("own change, once `opm-v3.0.0`
is on GHCR"); v4 released before the fleet re-pinned, so the fleet crosses straight to v4.

The hop absorbs two breaking catalog cuts:

- **v3.0.0** removed the legacy secret mechanism (`res.#Secret`, `$secretName` / `$dataKey`,
  `#EnvVarSchema.from`). Seven modules were cleaned up ahead of time by the archived change;
  `k8up/` was missed and still carries the removed env-`from` form in its `debugValues` and
  `extraEnv` doc comment. This change picks up that remainder.
- **v4.0.0** dropped the resource-name trait (`#ResourceNameTrait` and friends); exact names are
  authored on core's `metadata.resourceName`. No fleet module uses the trait
  (`istio_ambient/` already authors `metadata.resourceName` directly, the blessed mechanism), and
  the v4 cut is byte-identical for components that render today, so this side is pin-only.

`opmodel.dev/core@v2` stays at `v2.0.0-alpha.6`: it is core's newest release and exactly what
catalog v4 depends on. There is no core bump.

## What Changes

One pattern across all 20 CUE modules, plus one module-scoped cleanup:

- **All 20 module directories** (`apprise/` … `web_app/`): `cue.mod/module.cue` dependency
  crosses from `opmodel.dev/catalogs/opm@v2` (`v2.0.0-alpha.7`) to `opmodel.dev/catalogs/opm@v4`
  (`v4.0.0`). Imports are major-less (`opmodel.dev/catalogs/opm/resources/v1beta1`), so no `.cue`
  source changes for the pin itself. Release class: `fix:` (`fix(deps)`) per module.
- **`k8up/`** — **BREAKING**, `feat!:`. `extraEnv` values narrow to literal-only: v3 deleted
  `#EnvVarSchema.from`, so the documented `#SecretK8sRef` use (global S3 credentials wired as a
  `secretKeyRef`) stops existing. The doc comment, `debugValues` and `README.md` move to the
  plain-value shape with the standard `// 0013:` reintroduction marker, following the interim rule
  already in `DESIGN_PATTERNS.md` (`schemas.#Secret` section). `DEPLOYMENT_NOTES.md` records that
  secretKeyRef support returns when enhancement 0013's core-owned `#Secret` ships.

No module's own path major moves; the only major crossing is the catalog dependency, and the
cross-train major separation rule is untouched (registry paths and their majors are unchanged).

## Before / After

**Before** (the pin, identical in all 20 `cue.mod/module.cue` files; and k8up's config surface)

```cue
// <module>/cue.mod/module.cue
deps: {
	"opmodel.dev/catalogs/opm@v2": {
		v: "v2.0.0-alpha.7"
	}
	"opmodel.dev/core@v2": {
		v: "v2.0.0-alpha.6"
	}
}

// k8up/module.cue — #config
// value shape allows a Secret reference and not just a literal
extraEnv?: [Name=string]: res.#EnvVarSchema & {name: Name}

// k8up/module.cue — debugValues
extraEnv: BACKUP_GLOBALACCESSKEYID: {
	name: "BACKUP_GLOBALACCESSKEYID"
	from: {
		$secretName: "global-s3-credentials"
		$dataKey:    "access-key-id"
		secretName:  "global-s3-credentials"
		remoteKey:   "access-key-id"
	}
}
```

**After**

```cue
// <module>/cue.mod/module.cue
deps: {
	"opmodel.dev/catalogs/opm@v4": {
		v: "v4.0.0"
	}
	"opmodel.dev/core@v2": {
		v: "v2.0.0-alpha.6"
	}
}

// k8up/module.cue — #config
// 0013: literal-only until core's #Secret ships; secretKeyRef wiring returns with it.
// On catalogs/opm@v4 #EnvVarSchema has no `from`; values are name/value pairs.
extraEnv?: [Name=string]: res.#EnvVarSchema & {name: Name}

// k8up/module.cue — debugValues
extraEnv: BACKUP_GLOBALACCESSKEYID: {
	name:  "BACKUP_GLOBALACCESSKEYID"
	value: "debug-access-key-id"
}
```

Rendered objects: unchanged for all 20 modules. The v4 catalog cut is byte-identical for
components that render today; k8up's `debugValues` entry renders as a literal `env.value` instead
of a `secretKeyRef`, and the legacy mechanism never worked end to end, so no running instance
depends on the old rendering.

## Catalog contract

- Requires `opmodel.dev/catalogs/opm@v4` at `v4.0.0` and `opmodel.dev/core@v2` at
  `v2.0.0-alpha.6` (already pinned; catalog v4's own dep).
- `task deps:update` (workspace root) can NOT perform this bump: it re-gets each dep at the major
  already declared in `module.cue`, so it would land on `v2.0.0` final, not cross to `@v4`. The
  crossing runs `cue mod get opmodel.dev/catalogs/opm@v4.0.0` + `cue mod tidy` per module
  (mechanics in `design.md`). Subsequent bumps within v4 flow through `task deps:update` again.
- No catalog member this change needs is missing; no `k8s-*` passthrough is introduced.

## Impact

- **19 modules**: `fix(deps)` release each; operators do nothing.
- **`k8up/`**: `feat!:` release. An operator who set `extraEnv.<name>.from` (the mechanism was
  broken end to end, so likely nobody) must switch to a literal `value:` until 0013's replacement
  lands.
- 0019 D16 residual-rename audit for the fleet slice: no component used `#ResourceNameTrait`, the
  only explicit `metadata.resourceName` authors (`istio_ambient/`: `istiod`, `istio-cni-node`,
  `ztunnel`) already use the surviving mechanism, and no authored formula deviates from the
  convention — expected result is zero renames, proven by `task vet` + per-module publish
  dry-runs.

## Enhancement

- `enhancements/0019` D15, D16 — the fleet-consumption side of the transformer naming sweep: the
  re-pin lands the D15 sweep on the fleet, and this change is the `modules-fleet-rename` slice
  D16 names, recording the residual-rename audit (zero renames found).
- `enhancements/0013` D9 — the `k8up/` legacy-secret remainder the seven-module sweep missed
  (delete, do not deprecate).

`enhancement.yaml` in this change directory declares both.
