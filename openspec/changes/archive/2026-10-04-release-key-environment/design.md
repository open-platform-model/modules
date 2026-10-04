## Context

`.github/workflows/release.yml` has two jobs: `release-please` (mints the App token from `RELEASE_APP_PRIVATE_KEY`, runs release-please, checks out with the App token and pushes the identity advance to the release branch) and `publish` (sweeps unpublished module versions to GHCR with `GITHUB_TOKEN`). `ci.yml` is read-only. No `DESIGN_PATTERNS.md` pattern applies.

## Goals / Non-Goals

**Goals:** the key is read only in a job bound to the main-only `release` environment; every job states its token permissions.

**Non-Goals:** moving the secret, editing the environment or repository settings (owner and supervisor); changing how modules publish.

## Decisions

- **`release-please` declares `permissions: {}`.** Every write in the job goes through the App token: release-please takes it as `token`, and the checkout persists it for the `git push` of the identity advance. Granting `GITHUB_TOKEN` writes it never uses only widens what a compromised step could do. Alternative kept the old `contents: write, pull-requests: write`; rejected as unused.
- **Workflow-level `permissions: {}`.** Both jobs already declare their own; the top-level line makes that the rule for any job added later.
- **The App token is scoped.** The token step requests only `contents`, `pull-requests` and `issues` write, so the token never carries more of the installation's grant than release-please and the push use.
- **`publish` checks out without persisted credentials.** Its only later git call fetches the public `v1` branch, which needs no token.
- **`publish` gets no environment.** It does not read the key, and binding it would add a deployment record to every push without guarding anything.

## Risks / Trade-offs

- [The environment's branch policy also blocks a manual dispatch from another branch] → `release-please` runs on push only (`if: github.event_name == 'push'`), and `publish` has no environment, so a dispatch behaves as before.

## Durable decisions

None.
