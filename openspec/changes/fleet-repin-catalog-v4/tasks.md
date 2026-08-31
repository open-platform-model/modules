## 1. k8up/ — legacy-secret remainder (must precede or accompany the re-pin)

- [x] 1.1 `k8up/module.cue`: rewrite the `extraEnv` doc comment to the literal-only stance with a
      `// 0013:` reintroduction marker (design.md D-2); drop the `#SecretK8sRef` /
      `#SecretLiteral` paragraphs.
- [x] 1.2 `k8up/module.cue` `debugValues`: replace the `from: {$secretName, $dataKey, ...}`
      entry with `{name: "BACKUP_GLOBALACCESSKEYID", value: "debug-access-key-id"}`.
- [x] 1.3 `k8up/README.md`: move the global S3 credentials section to the plain-value shape and
      note the 0013 follow-up.

## 2. Fleet re-pin — one pattern, all 20 cue.mod/module.cue files

- [x] 2.1 Pilot on `apprise/`: `cue mod get opmodel.dev/catalogs/opm@v4.0.0` + `cue mod tidy`;
      verify the end state per design.md D-1 (exactly one `catalogs/opm` dep, `@v4` at
      `v4.0.0`, `core@v2` untouched at `v2.0.0-alpha.6`) and `cue vet ./...` passes. If tidy
      leaves the stale `@v2` entry, switch to the scripted-removal fallback (D-1) for the fleet
      pass.
- [x] 2.2 Apply the proven mechanism to the remaining 19 modules; `task tidy` from `modules/`.
- [x] 2.3 Confirm no `catalogs/opm@v2` entry survives anywhere:
      `grep -rn "catalogs/opm@v2" */cue.mod/module.cue` returns nothing.

## 3. Durable decisions

- [x] 3.1 `CLAUDE.md` (this repo, Repository Rules): major-crossing dep bumps are
      `cue mod get <path>@vN.0.0` + `cue mod tidy` per module; `task deps:update` owns in-major
      bumps only.
- [x] 3.2 `k8up/DEPLOYMENT_NOTES.md`: secretKeyRef-based global S3 credentials unsupported until
      0013's core-owned `#Secret` ships; `extraEnv` takes literals only.

## 4. Verification

- [x] 4.1 `task check` (fmt + vet) from `modules/`; then `task vet CONCRETE=true`.
- [x] 4.2 `opm module publish ./<module> --dry-run` for all 20 modules; zero name-related
      diagnostics (0019 D16 rename audit gate, design.md D-3).
