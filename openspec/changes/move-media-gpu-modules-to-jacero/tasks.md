## 1. opm-modules/ (new repo skeleton; commits land in opm-modules, design D8)

- [x] 1.1 Clone `git@github.com:emil-jacero/opm-modules.git` to the workspace root as `opm-modules/` (empty, public); create `main`
- [x] 1.2 Copy `Taskfile.yml`, `.gitignore` and `DESIGN_PATTERNS.md` from `modules/`; set `CANONICAL_REGISTRY` to `jacero.se=ghcr.io/emil-jacero,opmodel.dev=ghcr.io/open-platform-model,registry.cue.works` (design D4)
- [x] 1.3 Write `CLAUDE.md` from `modules/CLAUDE.md`: purpose (personal fleet under `jacero.se/modules/<name>@v1`), the registry mapping, the identity and release rules (tooling is the only writer of `identity.cue`), no branch model, no cross-train rule; write a short `README.md`
- [x] 1.4 Copy `.github/workflows/ci.yml` and `release.yml`; apply D4: `OPM_CLI_VERSION` v1.0.0-alpha.19, both registry vars to the D4 mapping, `ORG: emil-jacero`, the probe `base="${ORG}/jacero.se/modules/${repo}"`, delete the cross-train guard step and `OTHER_BRANCH`
- [x] 1.5 Write `release-please-config.json` (twelve packages, same per-package block as here) and `.release-please-manifest.json` with every module at `1.0.0`; leave `bootstrap-sha` empty, section 2 sets it (design D3)
- [x] 1.6 Add the `opm-modules/` routing row to the workspace root `CLAUDE.md` repo table (root is not a git repo: edit only)
- [x] 1.7 In `opm-modules/`: `task check` green on the empty fleet, workflow YAML parses (`actionlint` if installed, else `yq`), then commit `chore: bootstrap the repo skeleton from open-platform-model/modules`

## 2. Migrate the twelve modules (one pattern across modules; commits land in opm-modules)

- [x] 2.1 For each of jellyfin, jellystat, jellyswarrm, seerr, radarr, sonarr, sabnzbd, fileflows, nvidia_device_plugin, intel_gpu_device_plugin, nvidia_gpu_exporter, intel_gpu_exporter: copy `modules/<name>/` to `opm-modules/<name>/` without `CHANGELOG.md`; `grep -rl 'opmodel.dev/modules/<name>' --include=*.cue` must list only `module.cue`; sed that import to `jacero.se/modules/<name>/identity` (design D1)
- [x] 2.2 For each: `opm mod init jacero.se/modules/<name>@v1 --dir ./<name> --yes`, then `opm module version set 1.0.0 ./<name>`, then `cue mod tidy` in the module and verify `cue.mod/module.cue` still pins `catalogs/opm@v4 v4.0.0` and `core@v2 v2.0.0-alpha.6`
- [x] 2.3 For each: replace the cross-train sentence in the `identity/identity.cue` and `module.cue` header comments with the origin note from design D2 (the one hand edit; values untouched)
- [x] 2.4 Set `bootstrap-sha` in `release-please-config.json` to section 1's commit sha
- [x] 2.5 Render parity: for each module, `opm module build` (or `cue export`) with the same values here and in `opm-modules/`; the diff MUST be limited to `modulePath`, `fqn`, `uuid`, `version` and the derived labels
- [x] 2.6 With `OPM_REGISTRY` set to the D4 mapping: `task check` and `opm module publish ./<name> --dry-run` green for all twelve, then commit `chore(fleet): import the twelve modules from open-platform-model/modules at 1.0.0`
- [x] 2.7 Publishing is this change's deliverable (schema exception): push `main`, watch the Release workflow publish twelve `v1.0.0` tags, then from a shell without GHCR credentials `cue mod get jacero.se/modules/jellyfin@v1` resolves and `gh api users/emil-jacero/packages/container/jacero.se%2Fmodules%2F<name> --jq .visibility` reads `public` for all twelve (design D5); fix visibility in the GitHub UI before checking this box

## 3. modules/ (remove the originals; commit lands here)

- [x] 3.1 On a working branch: delete the twelve directories; remove their entries from `release-please-config.json` `packages` and from `.release-please-manifest.json` (design D6)
- [x] 3.2 `README.md` and `CLAUDE.md` § Purpose and § Current modules: `opmodel.dev/modules/*` is business and enterprise only; the media and GPU fleet lives at `github.com/emil-jacero/opm-modules` under `jacero.se/modules/<name>` (durable decision)
- [x] 3.3 `CLAUDE.md` § Registry: a GHCR package holds every train's tags; cleanup deletes versions, never a package another branch still publishes into (durable decision)
- [x] 3.4 `DESIGN_PATTERNS.md` § 13 Module Identity: one paragraph on moving a module between paths (fix the self-import, then `opm mod init <path> --yes` repair, then `version set`) (durable decision)
- [x] 3.5 Write `hack/ghcr-delete-versions.sh` per design D7 (table from proposal.md § Impact, dry-run default, `--apply` to delete, refuses tags outside the table, needs `delete:packages`); run the dry-run: every listed tag resolves to one version id, nothing else is selected
- [x] 3.6 `task check` green and `opm module publish ./<name> --dry-run` green for the eight staying CUE modules (apprise cert_manager gotify istio_ambient k8up metallb ntfy web_app), then commit `chore(fleet): move the media and gpu modules to jacero.se/modules`

## 4. GHCR cleanup (dated; the calendar reminder points here; commit lands here)

- [ ] 4.1 Precondition: the consumer-rewrite change has landed; `grep -rn 'opmodel.dev/modules/\(jellyfin\|jellystat\|jellyswarrm\|fileflows\)@v3\|opmodel.dev/modules/\(seerr\|radarr\|sonarr\|sabnzbd\|nvidia_device_plugin\|intel_gpu_device_plugin\|nvidia_gpu_exporter\|intel_gpu_exporter\)@v2'` across the workspace (excluding `.git`, `openspec/changes/archive`, `enhancements/archive`) returns nothing
- [ ] 4.2 Precondition: the operator's cutover to `jacero.se/modules/<name>@v1` is done and adoption of the existing objects under the new instance uuid was verified in kind first; record here `Cutover: YYYY-MM-DD. Earliest deletion: YYYY-MM-DD (cutover + 10 days).` and do not continue before that date
- [ ] 4.3 `hack/ghcr-delete-versions.sh` dry-run; review the id/tag pairs against proposal.md § Impact
- [ ] 4.4 `hack/ghcr-delete-versions.sh --apply`; verify every listed tag is gone and every kept tag (v1 and v0 trains) still resolves
- [ ] 4.5 Append the run (date, package, tags, version ids) to `hack/ghcr-deletions.md`; `task check` green, then commit `chore(ci): record the GHCR deletion of the migrated modules' main versions`; archive follows this commit
