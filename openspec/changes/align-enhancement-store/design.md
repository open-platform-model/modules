## Context

The repo is a fleet of CUE modules. Only comments, rule text, archived text and one CI log string cite an enhancement. Files touched: `openspec/config.yaml`, `AGENTS.md`, `openspec/schemas/module-change/{schema.yaml,templates/proposal.md}`, `.github/workflows/release.yml`, `istio_ambient/DEPLOYMENT_NOTES.md`, four archived changes. `DESIGN_PATTERNS.md` is not edited.

## Goals / Non-Goals

**Goals:** every citation is an id beside a reason; the repo rules live in `config.yaml`; `enh cite-lint` and `enh cite-rewrite --dry-run` report nothing.

**Non-Goals:** the `// 0013:` interim markers in module comments stay (see Decisions). No `.claude/**` edit. No lint task or CI call (a later task).

## Decisions

### The `// 0013:` markers stay

**Context**: eight module CUE files carry `// 0013: <reason>`, the interim marker of `DESIGN_PATTERNS.md` that makes the sites findable by grep.
**Decision**: leave them. Each marker is an id followed by its reason in words and holds no decision number. The lint accepts them.
**Rationale**: a rewrite would change a repo convention and eight module files for no gain.

### The tool's long titles are shortened in prose

**Decision**: the tool writes the full decision title after the id. Where that made a sentence hard to read, a short reason replaced it by hand.

### The N11 check is not built here

**Decision**: this repo has no `openspec:check` task and `task check` runs only `fmt` and `vet`. The advisory archive guidance about durable decisions stays. A check needs a decision from the owner (see the report).

## Research & Decisions

None beyond the above; the counts come from the swarm's recount of this repo (16 matches in 6 places).

## Risks / Trade-offs

- A wrong hand edit changes the meaning of an archived sentence -> two reviewers read each edited line.
- Until the owner runs `openspec update`, the old skill patches still ask for `enhancement.yaml` -> the PR body names the action.

## Durable decisions

None.
