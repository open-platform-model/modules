# GHCR deletion record

Every run of `hack/ghcr-delete-versions.sh --apply` is appended here: date, package, tags
and the version ids it deleted. Deletions are irreversible, so this file is the audit trail.
A package is never deleted, only versions (see `CLAUDE.md` § Registry).
