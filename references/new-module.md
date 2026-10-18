# Adding a new module

Covers the steps to add a module on `main`. The module layout and the release rules are in
`AGENTS.md`.

A new module is delivered as an OpenSpec change. Before you write CUE, read `DESIGN_PATTERNS.md`.
It documents the patterns used across the fleet.

## Steps

1. Create `<name>/`. The directory name is the module's snake_case name and equals the leaf of the
   module path.
2. Scaffold with `opm mod init opmodel.dev/modules/<name>@v2`. It writes `cue.mod/module.cue` and
   the `identity/` package (`ModulePath` and a defaulted `Version`).
3. Write `module.cue` (metadata and the `#config` schema, deriving the module path and version from
   the identity package) and `components.cue`.
4. Add `README.md` with the architecture, a quick start and the configuration reference. Add
   `DEPLOYMENT_NOTES.md` as issues surface.
5. Register the module in `release-please-config.json` (`packages`) and seed
   `.release-please-manifest.json` with its starting version. A module absent from both is never
   released.
6. Run `task check` and `opm module publish ./<name> --dry-run`, then open the PR. Commit as
   `feat(<name>): ...`. release-please attributes bumps by the files a commit touches.

## Pitfalls

- A directory name that differs from the path leaf.
- A `#config` field nothing configures: every field is a support obligation to each operator.
- A constraint written in README prose: put it in `#config` where CUE checks it.
- A module in neither release-please file.
- A comment that cites an enhancement.

## Check before you finish

- [ ] `task check` passes.
- [ ] The dry-run publish passes.
- [ ] The module is in both release-please files.
- [ ] A new shape used by more than one module is in `DESIGN_PATTERNS.md`.
