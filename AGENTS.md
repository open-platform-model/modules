# Modules repository guide

OPM module definitions, one pure-CUE module per directory, published as `opmodel.dev/modules/<name>`
at its major. A module consumes `opmodel.dev/core@v2` and `opmodel.dev/catalogs/opm@v4`; it defines
no core construct and no catalog member. This is its own git repo, a sibling of `cli/`,
`catalog_opm/` and the others.

`opmodel.dev/modules/*` is business and enterprise only. Personal modules do not land here. The
media and GPU fleet moved to `github.com/emil-jacero/opm-modules` (workspace sibling
`opm-modules/`), where it publishes as `jacero.se/modules/<name>@v1`. Their `v1`-train versions stay
on the `v1` branch here.

## Branch model

The lines cannot share one CUE toolchain or catalog. The old catalog schemas use CUE features
removed in v0.17, the v1 catalog needs v0.17 or later, and the v2 line re-keys module identity.
One branch per line gives each a single toolchain. A shared branch forced
every tool to special-case per-module CUE binaries and made "publish all changed" ambiguous.

| Branch | Line | Purpose |
| --- | --- | --- |
| `main` | OPM v2 | CUE `v0.17.0`, `opmodel.dev/core@v2` and `opmodel.dev/catalogs/opm@v4`. Publishes on push. v2-line module work lands here. |
| `v1` | OPM v1 | Protected live maintenance line. CUE `v0.17.0`, stable `opmodel.dev/core@v1` and `opmodel.dev/catalogs/opm@v1`. Publishes on push with checksum-driven patch bumps. Fixes for the published v1 fleet, and new v1 modules, land here. |
| `v0_legacy` | OPM v0 | Frozen. CUE `v0.16.0`, the deprecated `opmodel.dev/opm/v1alpha1` catalog. Maintenance only; never add a module. |

- **Never merge `main` into `v1`.**
- Check the branch before you scaffold a change. A change for the v1 fleet is a `v1` change and
  never comes through `main`.
- There is no publish task. CI publishes: release-please sets each module's version from its
  conventional commits, the release workflow writes it with `opm module version set`, and
  `opm module publish` pushes the committed tree to GHCR. On `main` the sweep runs on every push and
  ships each module whose version GHCR does not hold yet, so a module ships when the release-please
  PR that advances it merges.
- `fmt`, `vet`, `tidy` and `check` read deps from GHCR. No local registry is needed.
- A GHCR package holds the tags of every train. Cleaning up a retired line deletes versions, never
  the package: deleting the package removes every branch's tags at once.
- A path major may exist on several trains, but two trains never share a major for one path. A
  guard in the release workflow enforces it.

## Repository rules

- Module versions are stable SemVer while the fleet depends on the prerelease core line. A module
  break (a removed or renamed `#config` field, a changed default an operator relies on, a rendered
  object that changes kind or name) is `feat!`. It is a new version major, and also a new path
  major, because the major of the version must agree with the major of the module path.
- `identity/identity.cue` is written only by `opm module version set`. Never hand-write it.
- A `task deps:update` that crosses a core release with a `BREAKING CHANGE:` note is not a routine
  `fix(deps)`. Patch versions are immutable on GHCR, so a break shipped as `fix(deps)` cannot be
  withdrawn.
- A comment in a module cites no enhancement. Authors and operators of a module cannot open the
  enhancements store, so state the rule itself.
- A decision that a future module author or operator needs lands in `DESIGN_PATTERNS.md`, the
  module's `DEPLOYMENT_NOTES.md` or a file in `references/` before its change is archived. An archived change is
  never the only home of an authoring rule.
- Put no build artifact, binary or generated Kubernetes YAML here. Those belong in the cluster or CI.
- Commits are conventional commits scoped to the module directory. release-please attributes a bump
  by the files a commit touches, and a commit that spans several module directories bumps each.

## Layout

```text
<module>/                 one OPM module (cue.mod/, identity/, module.cue, components.cue, README.md, DEPLOYMENT_NOTES.md)
openspec/                 OpenSpec workspace: config.yaml (constitution), schemas/module-change/, changes/
references/               detail files per topic
hack/                     GHCR version cleanup tool and its deletion record
.tasks/                   scripts behind the Taskfile (the durable-decision check and its test)
.claude/skills/           repo-local openspec-* skills
DESIGN_PATTERNS.md        reusable CUE patterns across the fleet
```

A directory with no `cue.mod/` is a design-only module.

## Commands

Run from this folder. `Taskfile.yml` wins over this table on how commands run.

| Command | What it does | When |
| --- | --- | --- |
| `task fmt` | Formats all CUE modules | After editing a `.cue` file |
| `task vet` | Validates all CUE modules | Before committing |
| `task vet CONCRETE=true` | Validates with the concreteness check | To check fully resolved values |
| `task tidy` | Tidies deps for all modules | After changing imports or deps |
| `task cite-lint` | Fails on a decision number or a lone enhancement id in a CUE comment (needs network and Go) | Before committing a comment that names an enhancement |
| `task openspec:check` | Checks that each active change declares its durable decisions and that each target file exists | After editing a change's design |
| `task check` | Runs `fmt`, `vet` and `openspec:check` | Pre-commit gate |
| `opm module publish ./<name> --dry-run` | Runs every publish gate without pushing | Before opening a PR |

## Style

Follow the CUE style of `catalog_opm/`: `#` for definitions, `_` for hidden fields, `!` for required
fields, `?` for optional fields, `*` for defaults. Pin `language: version: "v0.17.0"` in
`cue.mod/module.cue` on `main`.

`openspec/config.yaml` is the normative constitution. This repo has no `CONSTITUTION.md`.

@CONTEXT.md
