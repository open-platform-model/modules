## Context

Files: `<module>/identity/identity.cue` for all 20 modules (two declarations each) and `DESIGN_PATTERNS.md`. `module.cue` is untouched. Pattern in play: none existing; this change adds one.

Two checks read the version, and they ask different questions:

| Step | Where | Asks | `#VersionType \| *"1.0.1"` |
| --- | --- | --- | --- |
| publish / vet | `cli/internal/publish/identity.go` (`#IdentityPackage` unify, then `String()`) | does the default resolve to a valid SemVer | passes, "concrete (default)" |
| load | `library/opm/helper/loader/internal/shape/shape.go:135` (`IsConcrete()`) | is this a value | refused |

The load gate runs on every kernel entry: `opm module build` (disk), the registry loader (`loader/registry/module.go:139`, ahead of `verifyModuleIdentity`, whose comment relies on the gate having guaranteed concreteness), and the operator's instance load (`opm-operator/internal/render/kernel_package_renderer.go:60`). Measured in Go against `cuelang.org/go v0.17.1` (the version `library` pins): `IsConcrete()` is false and `String()` returns `"1.0.1"` on the same value.

## Goals / Non-Goals

**Goals:**
- Every module's identity `Version` is a concrete literal; the kernel gate passes without any downstream workaround.
- The form is documented where a new module's author looks first.

**Non-Goals:**
- Changing how the version is released (`identity.cue` stays the writer's target; `version set` keeps owning it).
- Loosening the kernel gate to apply `Default()` first. Rejected: consumers already read through `String()`, so the gate is the one check that distinguishes a value from a constraint, and SPEC §3.6 rationale already holds that a default which renders while wrong is worse than none.
- The `cli` scaffold, podinfo fixture, `catalog_opm` identity files, the gate's diagnostic wording, and publish not running the loader gate. Each is a change in its own repo; this proposal names them so they are filed, not forgotten.
- The `cli` synthetic-instance-name defect (`istio_ambient-debug` is not a DNS label).

## Decisions

**D-A. Literal in `identity.cue`, not interpolation in `module.cue`.** `version: "\(id.Version)"` also passes the gate (measured), but it fixes the symptom downstream and leaves the identity file declaring a constraint where the whole system (publish tristate, `verifyModuleIdentity`, release workflow) treats it as a value. The literal fixes the cause; `module.cue` keeps `version: id.Version` and needs no comment explaining a workaround.

**D-B. Drop the local `#VersionType`.** It exists only because the scaffold emits it and `cueedit.ResetIdentityVersion` (scaffold-only) looks for it to rebuild the defaulted form. No fleet file references `id.#VersionType`. The constraint that applies is `core.#IdentityPackage.Version!: #VersionType`, enforced at publish; a malformed literal is also refused at load because `core.#Module` types `metadata.version`. Keeping a duplicate regex that nothing reads is surface without a consumer (Principle V).

**D-C. Hand-edit `identity.cue` once, and say so.** Constitution I: written only by `version set`. This is a shape edit, not a version edit; no value changes, and `version set` remains the sole writer afterwards. The commit message states this explicitly.

## Research & Decisions

### Why publish accepted what load refuses
**Context**: all 20 modules pass `opm module publish --dry-run` (only refusal: already-published) yet fail `opm module build`.
**Explored**: read both gates; Go probe of `IsConcrete()` vs `String()` vs `Default()` on the exact identity shape; scratch `web_app` with a plain literal and the original `version: id.Version` through `build`, `vet`, `publish --dry-run`, `version set` (same value: untouched; new value: literal rewritten in place), and a malformed literal (`"banana"`: refused by the `#VersionType` regex at load).
**Decision**: fix the identity form; leave both gates alone.
**Rationale**: the loader is the component that was right; the producers wrote a form it correctly refuses.

### Why the defaulted form existed
**Explored**: enhancements 0010/0011 decisions, SPEC §5.2, `cueedit` writer contract.
**Finding**: no decision requires `| *`. The writer supports literal, `&` chain and defaulted disjunction because it preserves whatever shape it finds. The form is what the scaffold emitted and everyone copied (fleet, podinfo fixture, `catalog_opm`).

## Risks / Trade-offs

- A `sed` across 20 files misses a variant -> the 20 `Version:` lines are byte-identical apart from the literal; verify with `grep -L '^Version: "' */identity/identity.cue` returning nothing and `grep -l '#VersionType' */identity/identity.cue` returning nothing.
- `opm module init` still produces the old form until the `cli` scaffold change lands -> a new module copies a neighbour (`DESIGN_PATTERNS.md` §13) or fixes the line by hand; the `cli` follow-up closes it.
- release-please bumps every module -> intended (`fix:`); `main` publish is disabled, so no artifact ships from this commit.

## Durable decisions

- "`identity.Version` MUST be a concrete string literal (`Version: "x.y.z"`), never `#VersionType | *"x.y.z"` and never an open constraint: the kernel's loader gate requires a value (`IsConcrete()`), and publish's `#IdentityPackage` unify already supplies the SemVer constraint, so a local `#VersionType` is redundant" -> `DESIGN_PATTERNS.md`, new section "13. Module identity", also covering `metadata: modulePath: id.ModulePath, version: id.Version` as plain references and that `identity.cue` is written only by `opm module version set` after this one-off shape edit.
