## Why

Agents and the owner use loose words for the same concept in this repo: module, package, app and chart; version, line and train. A glossary gives each concept one word and lists the words to avoid. The design and refactoring skills read a root `GLOSSARY.md` and treat its terms as domain terms.

## What Changes

- `GLOSSARY.md` (new): the domain terms of this repo, with a definition and the words to avoid.
- `AGENTS.md`: one line in the layout block for `GLOSSARY.md`.
- `CONTEXT.md`: one router row that sends naming and definition tasks to `GLOSSARY.md`.

## Before / After

No CUE file changes: Before and After are the same. Only documentation files change.

**Before**

```cue
```

**After**

```cue
```

## Catalog contract

No change. The core and catalog pins stay. `task deps:update` is not needed.

## Impact

- **Module directories touched:** none. Every commit is `docs`, which release-please hides in this repo. No path major moves.
- **Operators of modules:** no action.

## Enhancement

None.
