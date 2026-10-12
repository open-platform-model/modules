## Context

`Taskfile.yml` has `fmt`, `vet`, `tidy`, `check`. `.github/workflows/ci.yml` runs `task check` and the publish dry run. Files touched: `Taskfile.yml`, `.github/workflows/ci.yml`, `.tasks/`, `AGENTS.md`. The repo has Go nowhere, but `go run` of the tool needs the Go toolchain on the developer machine; the reusable workflow sets up Go itself.

## Goals / Non-Goals

**Goals:**
- The same comment rule locally and in CI, at the same tool commit.
- Durable-decisions check for active changes.

**Non-Goals:**
- Rewriting a citation; making the check org-required.

## Decisions

- No excludes. Measured: `enh cite-lint --root .` reports 45 files checked, 0 findings.
- The tool commit `e0335b2e` is a variable `CITE_LINT_REF` in `Taskfile.yml`. It equals the `enh-ref` default of `cite-lint.yml` at `.github` `2b66da51`. A comment says to compare them at each pin move. No exclude list exists, so there is one place to keep in sync later: a new exclude goes into the task and the CI call, each with a reason.
- The CI call is a job with only `name`, `permissions` (`contents: read`) and `uses`, pinned to the full `.github` SHA, with no secret.
- `openspec:check` runs as a CI step in the `check` job (it needs only bash). It also runs from `task check`, so the existing `Format, vet, tidy check` step covers it too; the separate step is therefore not added.

## Research & Decisions

None.

## Risks / Trade-offs

- The tool pin and the workflow default can drift -> comment plus review at each `.github` pin move.
- `go run` needs network and Go locally -> same as catalog_opm.

## Durable decisions

None.

## Open Questions

None.
