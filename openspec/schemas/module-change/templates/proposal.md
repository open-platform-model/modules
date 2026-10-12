## Why

<!-- Explain the motivation for this change. What problem does this solve? Why now? -->

## What Changes

<!-- Group by module directory. Be specific about new modules, #config fields, components,
     rendered objects, or removals. Mark breaking changes with **BREAKING**; a break that
     crosses the module's path major names the new major. -->

## Before / After

<!-- The CUE shape of every #config field and component this change touches, as CUE, not
     prose. "Before" is "none" for a new module. Add the rendered object's shape where rendering
     changes. Keep it to what changes. This block is the review surface. -->

**Before**

```cue
```

**After**

```cue
```

## Catalog contract

<!-- core / catalogs/* versions required; whether `task deps:update` (workspace root) must run
     first; any catalog member this change needs that does not exist yet (that is a catalog_opm
     change, not a k8s-* passthrough here). -->

## Impact

<!-- Module directories touched and release class per module (feat: / fix: / feat!:); whether
     any path major moves; what an operator running the module has to do. -->

## Enhancement

<!-- If this delivers a line of an enhancement's tasks.md, write one line per task:
     "Delivers NNNN, task X.Y." Otherwise write "None." Cite an enhancement only as its id beside
     a reason in words: never an id alone, never a decision number (no NNNN:Dn, NNNN Dn, NNNN:OQn). -->
