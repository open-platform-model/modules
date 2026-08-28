## Why

Every module on `main` declares its version in `identity/identity.cue` as a defaulted disjunction, `Version: #VersionType | *"x.y.z"`, the form `opm module init` scaffolds. That is a constraint with a suggested value, not a value. The kernel's loader shape gate (`library/opm/helper/loader/internal/shape`, `requireConcrete`: `IsConcrete()`) refuses it, so `opm module build` fails for all 20 modules with `required field "metadata.version" is not concrete`, and the same gate sits on the registry load path the operator uses at reconcile. Publish did not catch it because the CLI's identity gate reads the field through `String()`, which resolves the default (measured 2026-08-28: all 20 pass `publish --dry-run`, all 20 fail `build`; `library` alpha.17, `cli` built from `main`). The v2 fleet as published is therefore loadable by nothing that goes through the kernel.

Interpolating in `module.cue` (`version: "\(id.Version)"`, the `cli` podinfo fixture's workaround) forces the default to resolve and does make the gate pass, but it fixes the symptom one file downstream and leaves the identity file saying something the system never treats as anything but a value. This change fixes the source: identity is a literal.

## What Changes

One coherent fleet-wide edit (Principle VI) in every module's `identity/identity.cue`: `Version: #VersionType | *"x.y.z"` becomes `Version: "x.y.z"`, and the local `#VersionType` definition and its comment are removed. The local copy was redundant: nothing in the fleet references `id.#VersionType`, and `opm module publish` / `opm module vet` unify the package against `core.#IdentityPackage`, whose `Version!: #VersionType` is the constraint that actually applies. `module.cue` is untouched (`version: id.Version` stays a plain reference). The rule is recorded in `DESIGN_PATTERNS.md`.

This is a one-off shape edit to a file Constitution I reserves for `opm module version set`; it changes no version (every identity agrees with `.release-please-manifest.json`, checked 20/20), and `version set` handles the literal form as its first-class case (`cli/internal/cueedit/cueedit.go` `spliceVersion`, literal branch; idempotent no-op measured). All 20 directories: `apprise`, `cert_manager`, `fileflows`, `gotify`, `intel_gpu_device_plugin`, `intel_gpu_exporter`, `istio_ambient`, `jellyfin`, `jellystat`, `jellyswarrm`, `k8up`, `metallb`, `ntfy`, `nvidia_device_plugin`, `nvidia_gpu_exporter`, `radarr`, `sabnzbd`, `seerr`, `sonarr`, `web_app`.

## Before / After

**Before** (`web_app/identity/identity.cue`)

```cue
package identity

// #VersionType mirrors core.#VersionType (SemVer 2.0), duplicated so this
// package stays import-free.
#VersionType: string & =~"^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"

ModulePath: "opmodel.dev/modules/web_app@v1"

// Version is the module's bare SemVer; its major must agree with ModulePath's.
Version: #VersionType | *"1.0.1"
```

**After**

```cue
package identity

ModulePath: "opmodel.dev/modules/web_app@v1"

// Version is the module's bare SemVer; its major must agree with ModulePath's.
// A concrete literal, never a defaulted disjunction: the kernel's loader gate
// requires a value, and core's #IdentityPackage (which publish unifies this
// package against) supplies the SemVer constraint.
Version: "1.0.1"
```

`module.cue`'s `metadata` block is unchanged. The published value is identical; only its form changes.

## Catalog contract

No catalog or core requirement changes; no `task deps:update`. Pins stay at `core@v2` alpha.6 and `catalogs/opm@v2` alpha.6.

## Impact

- All 20 module directories, `fix:` each (release-please bumps every module the commit touches; `main` publish is dispatch-only, so nothing ships until the cutover). No path major moves. Already-published tags keep the defaulted form and stay unloadable; nothing consumes them.
- Operators: nothing to do; rendered output is byte-identical.
- Unblocks `opm module build` and operator loading for the whole fleet. `opm module build` still needs `--name <dns-label>` (synthetic name defaults to the snake_case module name); that is a `cli` defect, not this change.
- Out of scope, to file separately: `cli` scaffold still emits the defaulted form (`internal/scaffold/repair.go:284`) and the podinfo fixture keeps its interpolation workaround; `catalog_opm` identity files carry the same defaulted form; the `library` gate's `not concrete` message does not say "defaulted disjunction" and pointed at the wrong file; `opm module publish` does not run the loader gate, so publish accepted what load refuses.

## Enhancement

None.
