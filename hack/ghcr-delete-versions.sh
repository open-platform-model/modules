#!/usr/bin/env bash
# Delete the GHCR VERSIONS that `main` published for the module paths that moved
# to jacero.se/modules/<name> in 2026-09 (OpenSpec change
# move-media-gpu-modules-to-jacero, section 4).
#
# A GHCR package is per registry path and holds every train's tags: the
# package opmodel.dev/modules/jellyfin carries the v0_legacy versions, the v1
# branch's versions (still publishing on push) and main's side by side.
# Deleting the PACKAGE would remove every branch's tags at once, so this script
# only ever deletes versions, resolved tag by tag to their version ids, and only
# the tags in the table below. A tag that is not in the table is never touched.
#
# Usage:
#   hack/ghcr-delete-versions.sh            # dry-run: print id/tag pairs, delete nothing
#   hack/ghcr-delete-versions.sh --apply    # delete them, then re-list every package
#
# Needs `gh` logged in with the delete:packages scope for --apply
# (`gh auth refresh -s delete:packages`); read:packages is enough for the dry-run.
# Every run belongs in hack/ghcr-deletions.md.
set -euo pipefail

ORG="open-platform-model"
PREFIX="opmodel.dev/modules"

# package  tags published from main (space separated). Keep tags are everything else.
TABLE=$(cat <<'TBL'
jellyfin                v3.0.1 v3.0.2 v3.0.3
jellystat               v2.0.1 v2.0.2 v3.0.0
jellyswarrm             v2.0.1 v2.0.2 v3.0.0
fileflows               v2.0.1 v2.0.2 v3.0.0
seerr                   v2.0.1 v2.0.2 v2.0.3
radarr                  v2.0.1 v2.0.2 v2.0.3
sonarr                  v2.0.1 v2.0.2 v2.0.3
sabnzbd                 v2.0.1 v2.0.2 v2.0.3
nvidia_device_plugin    v2.0.1 v2.0.2 v2.0.3
intel_gpu_device_plugin v2.0.1 v2.0.2 v2.0.3
nvidia_gpu_exporter     v2.0.1 v2.0.2 v2.0.3
intel_gpu_exporter      v2.0.1 v2.0.2 v2.0.3
TBL
)

apply=false
case "${1:-}" in
  "") ;;
  --apply) apply=true ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

if $apply; then
  scopes=$(gh api -i /user 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p')
  case " ${scopes//,/ } " in
    *" delete:packages "*) ;;
    *) echo "refusing --apply: the gh token lacks the delete:packages scope (has: ${scopes:-none})" >&2; exit 2 ;;
  esac
fi

pkg_path() { printf '%s' "orgs/${ORG}/packages/container/${PREFIX//\//%2F}%2F$1"; }

# list_versions <package> -> lines "id<TAB>tag" (one line per tag; untagged versions omitted)
list_versions() {
  # shellcheck disable=SC2016  # $id is a jq variable, not a shell one
  gh api --paginate "$(pkg_path "$1")/versions" \
    --jq '.[] | .id as $id | .metadata.container.tags[] | "\($id)\t\(.)"'
}

failed=0
selected=()   # "pkg id tag"
while read -r pkg tags; do
  [ -n "$pkg" ] || continue
  listing=$(list_versions "$pkg")
  for tag in $tags; do
    ids=$(printf '%s\n' "$listing" | awk -F'\t' -v t="$tag" '$2==t {print $1}')
    n=$(printf '%s' "$ids" | grep -c . || true)
    if [ "$n" -ne 1 ]; then
      echo "ERROR ${pkg}:${tag}: expected exactly one version id, found ${n}" >&2
      failed=1
      continue
    fi
    selected+=("${pkg} ${ids} ${tag}")
  done
done <<< "$TABLE"

[ "$failed" -eq 0 ] || { echo "refusing: the table does not match the registry" >&2; exit 2; }

echo "selected ${#selected[@]} versions:"
printf '  %s\n' "${selected[@]}"

if ! $apply; then
  echo "dry-run: nothing deleted (pass --apply to delete)"
  exit 0
fi

for entry in "${selected[@]}"; do
  read -r pkg id tag <<< "$entry"
  gh api -X DELETE "$(pkg_path "$pkg")/versions/${id}" >/dev/null
  echo "deleted ${pkg} ${id} ${tag}"
done

echo "remaining tags per package:"
while read -r pkg tags; do
  [ -n "$pkg" ] || continue
  remaining=$(list_versions "$pkg" | cut -f2 | sort -V | tr '\n' ' ')
  for tag in $tags; do
    case " ${remaining} " in
      *" ${tag} "*) echo "ERROR ${pkg}:${tag} still present" >&2; failed=1 ;;
    esac
  done
  echo "  ${pkg}: ${remaining:-<none>}"
done <<< "$TABLE"
[ "$failed" -eq 0 ]
