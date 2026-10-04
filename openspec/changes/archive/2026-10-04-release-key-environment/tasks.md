## 1. .github/

- [x] 1.1 `release.yml`: workflow-level `permissions: {}`; `release-please` declares `environment: release` and `permissions: {}`
- [x] 1.2 Add `.github/CODEOWNERS` (`/.github/`, `/Taskfile*.yml`, `/release-please-config.json`, `/.release-please-manifest.json`) and `.github/dependabot.yml` (weekly `github-actions`, `ci` prefix)
- [x] 1.3 `actionlint` and `task check` green, then commit `ci: read the release key only in the main-only release environment`
