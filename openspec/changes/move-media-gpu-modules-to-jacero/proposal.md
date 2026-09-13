## Why

`opmodel.dev/modules/*` is the first-party namespace and should carry business and
enterprise modules only. Twelve modules on `main` are a personal media and GPU-transcoding
fleet (the Jellyfin and arr stacks, FileFlows, and the GPU device plugins and exporters that
exist for them). They move to a personal repository, `github.com/emil-jacero/opm-modules`,
and publish under the owner's own domain, `jacero.se/modules/<name>@v1`, where the publish
gates assert nothing about namespace layout. The move is the opportunity to reset every
migrated module to `1.0.0`: a new registry path has no history, so the majors that only
existed to dodge the v1 train (`jellyfin@v3`, `radarr@v2`, ...) disappear with it.

Decided in exploration (2026-09-13): the domain is `jacero.se`, mapped
`jacero.se=ghcr.io/emil-jacero`; the notification modules (`apprise`, `gotify`, `ntfy`)
stay; the target repository is public; the change stays active until the last GHCR version
is deleted, which happens no sooner than 10 days after the operator's own cutover.

## What Changes

**Migrated (12 module directories, removed from this repo after they publish from the new
one):** `jellyfin/`, `jellystat/`, `jellyswarrm/`, `seerr/`, `radarr/`, `sonarr/`,
`sabnzbd/`, `fileflows/`, `nvidia_device_plugin/`, `intel_gpu_device_plugin/`,
`nvidia_gpu_exporter/`, `intel_gpu_exporter/`.

- Each directory is copied to `opm-modules/<name>/` (workspace sibling, its own git repo),
  re-identified to `jacero.se/modules/<name>@v1`, set to version `1.0.0`, and published as
  `ghcr.io/emil-jacero/jacero.se/modules/<name>:v1.0.0` by that repo's CI. `#config`,
  components and rendered objects are byte-for-byte what `main` renders today; only identity
  moves. `CHANGELOG.md` does not travel: the new line starts at 1.0.0.
- **BREAKING** for any consumer pinned to the `opmodel.dev` path: the `main`-published
  versions of these twelve registry paths are deleted from GHCR in the last section. The v1
  train's tags (and v0's) on the same packages are untouched; the packages themselves stay.
- Then the twelve directories are deleted here, together with their entries in
  `release-please-config.json` and `.release-please-manifest.json`, and the fleet lists in
  `README.md` and `CLAUDE.md` § Current modules gain a one-line pointer to the new home.

**Stay (unchanged):** `apprise/`, `gotify/`, `ntfy/`, `cert_manager/`, `istio_ambient/`,
`metallb/`, `k8up/`, `web_app/`, `cdi/`, `snapshot_controller/`.

**Outside this repo (sections 1 and 2 commit there, not here):** `opm-modules/` is
bootstrapped from this repo's skeleton: `Taskfile.yml`, `.github/workflows/ci.yml` and
`release.yml` (minus the cross-train major separation guard, there is one train), a
`release-please` config and manifest seeded at `1.0.0`, `CLAUDE.md`, `DESIGN_PATTERNS.md`
and `.gitignore`. The workspace root `CLAUDE.md` repo table gains a routing row for it.

**Not in this change:** rewriting the org's own consumers of these modules (opm-kind-demo
pins `jellyfin@v2` and `seerr@v1`, the opm-operator sample and cli `QUICKSTART.md` use
`jellyfin@v1`) onto a business example. That is a separate cross-repo change and MUST land
before section 4 deletes anything. Cleaning up the v0-only GHCR packages (`garage`,
`linstor`, `wolf`, ...) is a separate question.

Delivery: one PR per section (section 4's GHCR deletion waits at least 10 days after the
operator's cutover that follows section 3; the change stays active on `main` in between).

## Before / After

No `#config` field, component or rendered object changes. Identity is the whole diff, shown
for `jellyfin`; the other eleven are identical in shape.

**Before**

```cue
// jellyfin/cue.mod/module.cue
module: "opmodel.dev/modules/jellyfin@v3"

// jellyfin/identity/identity.cue
ModulePath: "opmodel.dev/modules/jellyfin@v3"
Version:    "3.0.3"

// jellyfin/module.cue
import id "opmodel.dev/modules/jellyfin/identity"
metadata: {
	name:       "jellyfin"
	modulePath: id.ModulePath // fqn "opmodel.dev/modules/jellyfin@v3"
	version:    id.Version
}
```

**After**

```cue
// opm-modules/jellyfin/cue.mod/module.cue
module: "jacero.se/modules/jellyfin@v1"

// opm-modules/jellyfin/identity/identity.cue
ModulePath: "jacero.se/modules/jellyfin@v1"
Version:    "1.0.0"

// opm-modules/jellyfin/module.cue
import id "jacero.se/modules/jellyfin/identity"
metadata: {
	name:       "jellyfin"
	modulePath: id.ModulePath // fqn "jacero.se/modules/jellyfin@v1"
	version:    id.Version
}

// modules/jellyfin/  -> deleted
```

Derived identity moves with the path: `metadata.uuid` is a function of the fqn, and a
`#ModuleInstance`'s uuid is a function of the major-free `registryPath` plus name and
namespace. An instance re-pointed from `opmodel.dev/modules/jellyfin` to
`jacero.se/modules/jellyfin` therefore gets a new instance uuid; see Impact.

## Catalog contract

Unchanged: `opmodel.dev/core@v2` at `v2.0.0-alpha.6` and `opmodel.dev/catalogs/opm@v4` at
`v4.0.0`, exactly the pins the twelve modules carry today. No `task deps:update`. The
re-identify step rewrites `cue.mod/module.cue`, so `cue mod tidy` restores the same pins from
GHCR in the new repo; the new repo's CI maps `opmodel.dev=ghcr.io/open-platform-model` for
reads and `jacero.se=ghcr.io/emil-jacero` for its own publishes. No catalog member is needed
that does not exist.

## Impact

| Directory | Release class here | Path major |
| --- | --- | --- |
| the 12 migrated directories | none: removed in a `chore(fleet)` commit that also drops them from release-please, so nothing bumps or releases | moves to a new path, `jacero.se/modules/<name>@v1`, in another repo; the cross-train rule does not apply because nothing on any branch here publishes `jacero.se` |
| `README.md`, `CLAUDE.md`, `release-please-config.json`, `.release-please-manifest.json` | same `chore(fleet)` commit | n/a |
| `hack/` (new: the GHCR deletion script in section 3, its run record in section 4) | `chore(fleet)` in section 3, `chore(ci)` in section 4 | n/a |

GHCR versions deleted in section 4, per package under `ghcr.io/open-platform-model/opmodel.dev/modules/`:

| Package | Delete (published from `main`) | Keep (v1 and v0 trains) |
| --- | --- | --- |
| jellyfin | v3.0.1 v3.0.2 v3.0.3 | v1.0.x, v2.0.2 to v2.5.1 |
| jellystat, jellyswarrm, fileflows | v2.0.1 v2.0.2 v3.0.0 (all three were released from `main`: the `v1` branch publishes these paths at major v1) | v1.x |
| seerr, radarr, sonarr, sabnzbd | v2.0.1 v2.0.2 v2.0.3 | v0.x, v1.x |
| nvidia_device_plugin, intel_gpu_device_plugin, nvidia_gpu_exporter, intel_gpu_exporter | v2.0.1 v2.0.2 v2.0.3 | v0.x, v1.x |

**What an operator has to do** (the module author is the only operator of these twelve):

1. Add `jacero.se=ghcr.io/emil-jacero` to the registry mapping of every consumer: the
   opm-operator `--registry` flag or `OPM_REGISTRY`, and `~/.opm/config.cue`. Unmapped
   domains fall through to `registry.cue.works`, which does not serve them.
2. Re-pin each ModuleInstance from `opmodel.dev/modules/<name>@vN` to
   `jacero.se/modules/<name>@v1` at `v1.0.0`. The instance uuid changes with the
   registryPath. Prune skips live objects whose uuid label disagrees, so nothing is deleted,
   but whether apply adopts the existing StatefulSet and PVC under the new label MUST be
   verified in the kind cluster before a real Jellyfin is re-pointed.
3. Nothing pinned to the deleted `main` versions survives section 4. The v1-train pins
   (`jellyfin@v2` v2.x etc.) keep resolving.

## Enhancement

None.
