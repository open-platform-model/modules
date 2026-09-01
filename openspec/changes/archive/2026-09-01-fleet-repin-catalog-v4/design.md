## Context

See `proposal.md` for motivation. Current state: all 20 CUE modules pin
`opmodel.dev/catalogs/opm@v2` at `v2.0.0-alpha.7` and `opmodel.dev/core@v2` at `v2.0.0-alpha.6`
in `<module>/cue.mod/module.cue`. Catalog imports in `.cue` sources are major-less
(`opmodel.dev/catalogs/opm/resources/v1beta1` etc.), so the major rides entirely on the dep
entry. `k8up/module.cue` (`#config.extraEnv` doc comment, `debugValues`) and `k8up/README.md`
still describe the v3-removed `#EnvVarSchema.from` / `#SecretK8sRef` form.

Files touched:

- `<module>/cue.mod/module.cue` for all 20 modules: `apprise`, `cert_manager`, `fileflows`,
  `gotify`, `intel_gpu_device_plugin`, `intel_gpu_exporter`, `istio_ambient`, `jellyfin`,
  `jellystat`, `jellyswarrm`, `k8up`, `metallb`, `ntfy`, `nvidia_device_plugin`,
  `nvidia_gpu_exporter`, `radarr`, `sabnzbd`, `seerr`, `sonarr`, `web_app`.
- `k8up/module.cue`, `k8up/README.md`, `k8up/DEPLOYMENT_NOTES.md`.
- `CLAUDE.md` (this repo): durable note on major-crossing dep bumps.

`DESIGN_PATTERNS.md` patterns in play: the `schemas.#Secret` interim rule (string field,
`value:` injection, `// 0013:` marker) established by `2026-08-30-modules-drop-legacy-secrets`.
This change adds no new pattern.

## Goals / Non-Goals

**Goals:**

- Every module resolves `opmodel.dev/catalogs/opm@v4` at `v4.0.0`; no `@v2` catalog dep remains.
- `k8up` vets and dry-run-publishes against v4; its docs stop describing a removed mechanism.
- Rendered-output neutrality is verified, not assumed (0019 D16 residual-rename audit).

**Non-Goals:**

- No core bump (`v2.0.0-alpha.6` is current and is what catalog v4 pins).
- No reintroduction of secret references; that waits for 0013's core-owned `#Secret`.
- No change to root `Taskfile.yml` `deps:update` to support major crossings (workspace-root
  tooling, out of this repo's scope; noted as a possible follow-up).
- No functional change to any module's components or rendered objects.

## Decisions

### D-1: Cross the major with `cue mod get`, not `task deps:update`, not a hand edit

The constitution routes dependency pins through `task deps:update`, but that task re-gets each
dep at the major already declared in `module.cue` (it parses dep paths and runs `cue mod get
<path>`), so it cannot cross `@v2` → `@v4`. The crossing MUST run, per module:

```bash
cue mod get opmodel.dev/catalogs/opm@v4.0.0
cue mod tidy
```

This is the CUE-native pin writer, the same tool `deps:update` wraps; it is not a hand edit.
After the crossing, in-major bumps flow through `task deps:update` again.

**Verification requirement**: `cue mod get` adds the `@v4` entry; whether the stale `@v2` entry
is dropped by `cue mod tidy` (major-less imports resolving to the sole remaining/highest major)
MUST be proven on a pilot module before the fleet pass. If tidy leaves both majors or errors on
ambiguity, the fallback is a scripted removal of the `@v2` block followed by `cue mod tidy`,
applied identically to all 20 files. Either way the end state MUST be verified per module:
exactly one `catalogs/opm` dep, at `@v4` `v4.0.0`.

Alternatives considered: extending root `deps:update` to take a target major (rejected here:
workspace-root tooling change, wrong repo for this change); hand-editing 20 files (rejected:
constitution forbids it and the CUE command exists).

### D-2: k8up narrows by upstream schema, docs follow

`#config.extraEnv` keeps its shape:

```cue
extraEnv?: [Name=string]: res.#EnvVarSchema & {name: Name}
```

On v4, `res.#EnvVarSchema` itself no longer carries `from?:`, so the narrowing is inherited, not
authored; only prose and values change. The doc comment drops the `#SecretK8sRef` /
`#SecretLiteral` paragraphs and gains the `// 0013:` marker per the `DESIGN_PATTERNS.md` interim
rule; `debugValues` moves to a literal:

```cue
extraEnv: BACKUP_GLOBALACCESSKEYID: {
	name:  "BACKUP_GLOBALACCESSKEYID"
	value: "debug-access-key-id"
}
```

`#config` closedness, requiredness and defaults are otherwise untouched. No rendered object
changes kind, name or selector; the `debugValues` env entry renders `value:` instead of
`secretKeyRef` (vet surface only; the legacy path never worked end to end).

### D-3: Rename audit is a verification gate, not an edit

0019 D16 names three residual-rename cases for this fleet slice. Audit findings (2026-08-31):
no component uses `#ResourceNameTrait` (sole grep hit was cert_manager's
`--cluster-resource-namespace` flag string); explicit `metadata.resourceName` exists only in
`istio_ambient` (`istiod`, `istio-cni-node`, `ztunnel`), which is the surviving v4 mechanism;
no authored formula deviates from the `<instance>-<component>` convention. Expected renames:
zero. The gate: `task vet CONCRETE=true` plus `opm module publish ./<name> --dry-run` per module
MUST pass with no name-related diagnostics before the change is considered done.

## Research & Decisions

### Catalog delta between the pinned alpha and v4.0.0

**Context**: The fleet skips four releases in one hop; the breaking surface had to be enumerated.
**Explored**: `catalog_opm` git log `opm-v2.0.0-alpha.7..opm-v4.0.0`, the archived
`catalog-remove-legacy-secrets` (v3) and `catalog-drop-resource-name-trait` (v4) proposals, and
a fleet-wide grep for every removed construct.
**Decision**: Treat the re-pin as mechanical for 19 modules; only `k8up` needs source edits.
**Rationale**: v3's removals hit only `k8up` (`$secretName` / `$dataKey` in `debugValues`; the
seven-module cleanup change never mentions k8up, so it was missed, not excluded). v4's trait
removal has zero fleet users, and its commit records rendered output as byte-identical for
components that render today.

### Why the hop lands as one change

**Context**: The archived secrets cleanup deliberately split usage-removal from the re-pin.
**Explored**: That split existed because `opm-v3.0.0` was not yet on GHCR; the usage removal had
to vet at `alpha.7`. `opm-v4.0.0` is published, so nothing forces sequencing now.
**Decision**: One change: k8up remainder + fleet re-pin (Principle VI: one pattern across
modules, plus the single module edit the pattern forces).
**Rationale**: The k8up edit cannot vet-fail at alpha.7 (it only stops using still-existing
definitions) and is required for the v4 pin to vet; landing them together keeps the fleet on one
catalog version with one PR.

## Durable decisions

- **Major-crossing dep bumps**: `task deps:update` only moves pins within a declared major; a
  major crossing is `cue mod get <path>@vN.0.0` + `cue mod tidy` per module, then `deps:update`
  resumes ownership. Lands in this repo's `CLAUDE.md` (Repository Rules).
- **k8up S3 credential stance**: global S3 credentials via `secretKeyRef` are unsupported until
  enhancement 0013's core-owned `#Secret` ships; `extraEnv` takes literals only. Lands in
  `k8up/DEPLOYMENT_NOTES.md`.
