# OpenSpec workflow for module changes

Covers how non-trivial module work is proposed, executed and archived here, and how a change
delivers a task of a cross-repo enhancement. The constitution is `openspec/config.yaml`.

## The workflow

- Non-trivial module work is an OpenSpec change. Scaffold it with the `openspec-new-change` or
  `openspec-propose` skill. `openspec/config.yaml` holds the rules each artifact must meet.
- The schema is the project-local `module-change` schema in `openspec/schemas/`: proposal, design,
  tasks. It has no specs artifact by design. A module's contract is its `module.cue`, README and
  rendered manifests, and a prose spec would be a copy that no gate keeps honest. There is no
  `openspec/specs/` content and never a `specs/` directory inside a change. The Before and After CUE
  block of the proposal is where the intended behaviour is reviewed.
- `openspec validate` still asks for spec deltas unless the change's `.openspec.yaml` says
  `skip_specs: true`. Write that marker when you create the change. If a change lacks it, add it.
- Apply the mergeable-sections gate before you start. A section is one module, or one pattern applied
  across modules, and each closes with its own commit. Split a request that does not cut into a
  handful of such sections, using the phrasing in `openspec/config.yaml`.

## Durable decisions

The design of a change declares each decision that a future module author or operator needs, and
where it lands: `DESIGN_PATTERNS.md`, a module's `DEPLOYMENT_NOTES.md`, `AGENTS.md` or a file in
`references/`. `task openspec:check` checks that each active change names a target and that the
target file exists. A test in `.tasks/` pins that check.

## Delivering an enhancement task

The design of a cross-cutting enhancement lives in the OpenSpec store `opm-enhancements`. Its tasks
say which repo still has work, and the execution is a change here. Read an entry with
`openspec show <id>-<slug> --store opm-enhancements`.

- A change that delivers a task line of an entry puts `## Enhancement` in its proposal with one line
  `Delivers NNNN, task X.Y.` per task. Otherwise the section says `None.`.
- The PR body names the delivered task. After the PR merges, a PR on `enhancements` ticks the line.
- Cite an enhancement by id only beside a reason in words, never alone and never with a decision
  number.
- If OpenSpec warns that the store is not registered, report the warning and go on. The human runs
  `task enhancements:register`.

## The repo-local skills

The `openspec-*` skills in `.claude/skills/` are output of `openspec init` and
`openspec update --tools claude`. No skill file keeps a local patch: the repo rules live in
`openspec/config.yaml`, which `openspec update` does not overwrite. Both commands re-create
`openspec-sync-specs` whenever the global profile selects the `sync` workflow. There are no specs to
sync, so delete it again after either command. `openspec init --force` also deletes any change
directory that lacks `.openspec.yaml`, so check `git status` after it and restore from git.

## Pitfalls

- A `specs/` directory in a change, or a change without `skip_specs: true`.
- A decision left only in an archived change.
- Ticking the enhancement task in the delivering PR.
- Leaving `openspec-sync-specs` in place after `openspec update`.

## Check before you finish

- [ ] `.openspec.yaml` carries `skip_specs: true`.
- [ ] The proposal says `Delivers NNNN, task X.Y.` or `None.`.
- [ ] Every durable decision names a target that exists.
- [ ] Each section of tasks ends with its commit task.
- [ ] `task check` passes.
