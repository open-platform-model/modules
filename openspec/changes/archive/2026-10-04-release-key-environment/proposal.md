## Why

`RELEASE_APP_PRIVATE_KEY` is an org secret with no environment, so a workflow run on any branch of this repository can read it on a push event and act as the release App. The owner decided (release-cascade security pass, 2026-10-04) to move the key, unrotated, into a main-only `release` environment in every repository that reads it; the environment already exists here with a `main` branch policy. The same audit found that `release.yml` declares no workflow-level permissions, so its jobs would inherit whatever the repository default grants, and no file names code owners for CI and release config.

## What Changes

No module directory changes. Repository CI and config only:

- **`.github/workflows/release.yml`**: workflow-level `permissions: {}`. The `release-please` job, the only reader of the key, runs in `environment: release` and declares `permissions: {}`: release-please, the checkout and the identity-advance push all use the App token, minted with only `contents`, `pull-requests` and `issues` write. The `publish` job keeps `contents: read` and `packages: write`, and its checkout sets `persist-credentials: false`.
- **`.github/CODEOWNERS`**: the owners review `.github/`, `Taskfile.yml`, `release-please-config.json` and `.release-please-manifest.json`. Review is required only once the main ruleset turns on code-owner review; the file's header says so.
- **`.github/dependabot.yml`**: weekly GitHub Actions updates with the `ci` prefix; `open-platform-model/.github*` is ignored, since it moves by the pin procedure only.
- `ci.yml` already declares `contents: read` and `packages: read`. No workflow restores an Actions cache (the publish job installs CUE with `go install` and no `setup-go`), so nothing changes there.

## Before / After

```yaml
# Before: release.yml
jobs:
  release-please:
    permissions: {contents: write, pull-requests: write}
    # reads secrets.RELEASE_APP_PRIVATE_KEY on any branch's push run
# After
permissions: {}
jobs:
  release-please:
    environment: release   # deployment branch policy: main only
    permissions: {}
```

## Catalog contract

None. No `cue.mod` changes; `task deps:update` is not needed.

## Impact

- Module directories touched: none, so release-please bumps no module. Commits are `ci`.
- No path major moves. Operators have nothing to do.
- Risk: until the owner stores the key in the environment, the job reads the org secret as before, so this merges safely first. A wrong `permissions: {}` would show on the next push to `main` as a failed release-please step; the `publish` job is independent of it.
