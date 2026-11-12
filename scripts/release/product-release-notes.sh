#!/usr/bin/env bash
# Put the Snapshot on the GitHub Release of a product tag: create the Release with the Snapshot as its notes, or
# replace the notes of the Release that already exists.
#
# The deploy-prod workflow (publish-bundle.sh) creates the Release of the same tag when it attaches the bundles,
# with the notes "bundles of <tag>", and it can win the race by a few seconds. So the notes are set with edit
# whenever the Release exists, which keeps its title and its assets. A create that fails while no Release exists
# (a missing permission, a tag that is not on the remote) fails the script, instead of reporting a Release that
# was never made.
#
# usage: product-release-notes.sh <tag> <snapshot.md>
#   env: GH_TOKEN  a token that can write Releases of this repository
set -euo pipefail
tag="${1:?usage: product-release-notes.sh <tag> <snapshot.md>}"
notes="${2:?missing snapshot file}"
[[ -f "$notes" ]] || { printf '%s\n' >&2 "找不到 Snapshot 檔：$notes"; exit 1; }
repo="${GITHUB_REPOSITORY:-$(node "$(dirname "$0")/../lib/retry.mjs" read -- gh repo view --json nameWithOwner --jq .nameWithOwner)}"
if ! node "$(dirname "$0")/../lib/retry.mjs" read -- gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  rc=0
  gh release create "$tag" --repo "$repo" --title "$tag" --notes-file "$notes" || rc=$?
  if (( rc == 0 )); then
    printf '%s\n' "[product-release-notes] ${tag}：已建立 Release，內文是 Snapshot"
    exit 0
  fi
  node "$(dirname "$0")/../lib/retry.mjs" read -- gh release view "$tag" --repo "$repo" >/dev/null 2>&1 || exit "$rc"
fi
gh release edit "$tag" --repo "$repo" --notes-file "$notes"
printf '%s\n' "[product-release-notes] ${tag}：Release 已存在，內文改成 Snapshot"
