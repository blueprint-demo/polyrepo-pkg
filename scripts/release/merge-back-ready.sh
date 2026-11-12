#!/usr/bin/env bash
# Whether the merge-back of the release line on the current branch can be opened: the line stage is ga and every final tag the
# train needs exists. Prints GitHub Actions outputs on stdout (append to $GITHUB_OUTPUT) and the reason on stderr. It looks once
# and always exits 0, because a condition that does not hold yet is the normal case for most runs of release-please.
#
# usage: merge-back-ready.sh
#   ready=true|false
#
# The decision is train_merge_back_ready (scripts/lib/release-stages.sh), the same check finalize-release.sh --phase merge-back
# stops on. Fetches the tags first: release-please makes the tags of the GA Release PR in the run that asks.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

branch="$(current_branch)"
if ! [[ "$branch" =~ ^release/v[0-9]+\.[0-9]+$ ]]; then
  warn "${branch:-（detached）} 不是發布線，不合回"
  echo "ready=false"
  exit 0
fi
read_retry git fetch -q --tags origin main "$branch" || die "git fetch origin 沒成功，無法判斷最終 tag 齊了沒"
if train_merge_back_ready; then
  echo "ready=true"
else
  warn "$TRAIN_MERGE_BACK_WAITING"
  echo "ready=false"
fi
