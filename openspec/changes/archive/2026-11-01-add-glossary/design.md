## Context

The repo has `AGENTS.md` for facts, `CONTEXT.md` as a router and `DESIGN_PATTERNS.md` for CUE patterns. None of them fixes the words. Terms come from `AGENTS.md`, `DESIGN_PATTERNS.md`, `openspec/config.yaml`, `references/` and the module directories. Files touched: `GLOSSARY.md`, `AGENTS.md`, `CONTEXT.md`. No module directory and no `DESIGN_PATTERNS.md` pattern is involved.

## Goals / Non-Goals

**Goals:**
- One word for each domain concept, with the loose words listed under `_Avoid_`.
- Each OPM schema term (`#Module`, `#Resource`, `#Trait`, `#Blueprint`) defined as this repo uses it.
- Only terms specific to this repo. Each term has a backing file in the repo.

**Non-Goals:**
- A change to any module, rule or pin.
- Terms of the core or catalog repos that no file here uses.

## Decisions

- One root `GLOSSARY.md`, because the repo is a single context.
- `AGENTS.md` names the file in its layout block. `CONTEXT.md` gets one row. The docs-form rule of the workspace allows the root name.
- Line and train are two terms: a line is a branch generation, a train is its published series. The major separation rule uses the word train.

## Risks / Trade-offs

- A definition drifts from the repo rules -> each term cites its rules only in words, and the owner reviews it with the PR.

## Durable decisions

None.
