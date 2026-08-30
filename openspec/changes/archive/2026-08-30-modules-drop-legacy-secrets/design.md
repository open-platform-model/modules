## Context

Files: `{metallb,gotify,apprise,jellystat,fileflows,ntfy,jellyswarrm}/{module,components}.cue`, each module's `README.md`, `DESIGN_PATTERNS.md` (§ `schemas.#Secret`, the summary-table row, the fake-secret note for debug values). Patterns: none new; the change removes the `schemas.#Secret` pattern and the `opm-secrets` component idiom that `jellystat` and `fileflows` document in their headers.

Inventory (grep across the fleet, 2026-08-29):

1. 13 `#config` fields typed `res.#Secret` across seven modules.
2. 12 env entries using `from:`.
3. 2 `opm-secrets` components driven by `res.#AutoSecrets`.
4. 1 volume-mounted secret (`metallb`), built from a hand-authored `secrets:` entry whose data value is a `#Secret`.
5. Every `debugValues` block and README example writes the k8s-ref branch (`$secretName` + `secretName` + `remoteKey`).

Constraints: the catalog at the current pin still defines all of it, so the fleet vets today and after this change. `catalogs/opm@v3` has no `#EnvVarSchema.from`, so env injection of a secret has no catalog expression until 0013. `#SecretsResource` and the inline volume `secret` source survive with string data. No `k8s-*` member is used.

## Goals / Non-Goals

**Goals**

1. No module on `main` references `res.#Secret`, `#AutoSecrets`, `$secretName` / `$dataKey`, `secretName` / `remoteKey`, `env.from`, or a component named `opm-secrets`.
2. Each module vets and renders at the current pin and, after the re-pin, at `@v3`.
3. Reintroduction under 0013 is a grep: every site is marked.

**Non-Goals**

1. Re-pinning to `catalogs/opm@v3` (follow-up, gated on GHCR).
2. Referencing pre-existing cluster Secrets by any interim mechanism.
3. Adopting `core`'s new `#Secret` (no release carries it).

## Decisions

**D-A. Sensitive fields become `string`, injected through `value:`. The reference arm is dropped for the interim.**

```cue
// module.cue
// 0013: becomes c.#Secret when core ships it; plain string until then.
jwtSecret: string

// components.cue
JWT_SECRET: {
	name: "JWT_SECRET"
	// 0013: back to `from:` when the catalog regains an env secret path.
	value: #config.jwtSecret
}
```

Rejected:

1. Delete the fields and env entries until 0013: leaves `jellystat` (JWT and postgres password required), `ntfy` (`auth.users` required) and `gotify` (upstream default password `admin`) non-deployable in staging, for no gain; plaintext-in-render is the posture the legacy literal arm already had.
2. Hand-authored `secrets:` per workload plus `envFrom.secretRef`: needs the rendered name `{instance}-{component}-{name}` inside the module, a second derivation of a name the transformer owns (Principle III).
3. A `{value: string}` wrapper so instance files match 0013's literal arm today: no consumer, a module-local contract (Principle V).

Requiredness and defaults are preserved field for field. The `string | *"gotify"`-style defaults sat on `$secretName`, which disappears; the fields themselves had no value default and get none.

**D-B. `metallb` keeps its hand-authored Secret; the data value is a string by construction.**

```cue
secrets: memberlist: data: secretkey: #config.speaker.memberlistKey   // string
volumes: memberlist: secret: {from: spec.secrets.memberlist, defaultMode: 420}
```

The volume path is the catalog's hand-authored inline source and survives at `@v3`; rendered name (`{instance}-speaker-memberlist`) and manifest are byte-identical. `README.md` loses the "pick a branch" section.

**D-C. `jellystat` and `fileflows` delete `opm-secrets` outright.**

It existed only to feed `env.from` refs with a `{instance}-{name}` object; with `value:` injection nothing reads it, and an unreferenced Secret is surface without a consumer. The header comments about the magic name go with it; README architecture lists drop the component.

**D-D. One `feat!:` commit per module; `DESIGN_PATTERNS.md` rides the first.**

Release-please attributes bumps by touched files; seven modules in one commit is one message for seven changelogs. The pattern doc is fleet-level and lands with whichever module goes first.

## Research & Decisions

### Can the change land before the `@v3` re-pin?
**Context**: ordering against `catalog_opm/catalog-remove-legacy-secrets`.
**Explored**: the current pin (`v2.0.0-alpha.7`) still defines `#Secret`, `#AutoSecrets`, `env.from`; this change only removes uses. `#SecretsResource` `data` accepts `string` at the current pin and at `@v3`.
**Decision**: land first, at the current pin; re-pin separately.
**Rationale**: decouples the fleet edit from GHCR timing; `task check` stays green at every step.

### Inventory of legacy sites
**Context**: 0013 described the fleet as "metallb only".
**Explored**: `grep` for `res.#Secret`, `AutoSecrets`, `opm-secrets`, `from: #config`, `$secretName`, `remoteKey` across `modules/*/*.cue` and `*.md`, 2026-08-29.
**Decision**: seven modules (`jellyswarrm` surfaced last); 13 fields, 12 env sites, 2 components, 1 volume, 7 READMEs, `DESIGN_PATTERNS.md`.
**Rationale**: the proposal's table is the complete list.

## Risks / Trade-offs

1. Plaintext in rendered manifests and instance files for the interim -> accepted for the staging line (publish disabled on `main`); each README states it and points at 0013; the `v1` fleet is untouched.
2. An instance file still in the k8s-ref shape fails to unify with `string` -> intended loud failure; `debugValues` in every module is the rewritten example.
3. Seven `feat!:` bumps at once look like a fleet event -> they are one; commit bodies cite this change.
4. The follow-up re-pin changes the import-path major in every module's `cue.mod/module.cue` -> `task deps:update` handles the version; the path major is a deliberate edit in that change, not this one.

## Durable decisions

1. "Until `core` publishes 0013's `#Secret`, a sensitive `#config` field is typed `string`, injected through `value:`, and carries a `// 0013:` marker; no module references a pre-existing cluster Secret and no module names a component `opm-secrets`" -> `DESIGN_PATTERNS.md`, replacing § `schemas.#Secret` and its summary-table row.
2. "`metallb`'s memberlist key is a hand-authored Secret mounted as a volume; the rendered name is `{instance}-speaker-memberlist`" -> `metallb/DEPLOYMENT_NOTES.md` (create if absent) and the existing component comment.
3. Everything else stays with the change.
