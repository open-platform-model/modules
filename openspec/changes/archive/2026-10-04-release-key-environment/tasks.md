## 1. .github/

- [x] 1.1 `release.yml`: workflow-level `permissions: {}`; `release-please` declares `environment: release` and `permissions: {}`
- [x] 1.2 Add `.github/CODEOWNERS` (`/.github/`, `/Taskfile*.yml`, `/release-please-config.json`, `/.release-please-manifest.json`) and `.github/dependabot.yml` (weekly `github-actions`, `ci` prefix)
- [x] 1.3 `actionlint` and `task check` green, then commit `ci: read the release key only in the main-only release environment`

## 2. Review follow-ups (PR 55)

- [x] 2.1 App token step requests only `permission-contents`, `permission-pull-requests` and `permission-issues` write; `publish` checkout sets `persist-credentials: false`; CODEOWNERS header states review is enforced only by the ruleset; dependabot ignores `open-platform-model/.github*`. Verify: `actionlint` and `task check` green.
