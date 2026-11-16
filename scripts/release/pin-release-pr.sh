#!/usr/bin/env bash
# Pin the "next" of facts/ and docs/ to the versions of the open Release PR of a release line, commit and push. The step the
# release-please job runs after release-please has written the Release PR (the pin the merge workflow does too, as its fallback).
#
# usage: pin-release-pr.sh --line X.Y [--yes]
#
# What it does is release_pin_open_pr (scripts/lib/release-pr.sh): no open Release PR, a branch that moved after the Release PR
# was written, or a version that is not what the policy gives each end in "nothing pinned, success", because the same event
# comes many times and most of them are not the time to pin. The next run of release-please writes the PR again and asks again.
#
# The push is refused when the branch moved between the fetch and the push. Then the pin commits it made are dropped, the branch
# is brought to origin, and the whole check and pin runs once more (the second look finds the PR stale and pins nothing, or
# pins again on the new tip). A commit that is not a pin commit is never dropped.
# The release branch must be checked out, with a clean tree.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

line=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --line) line="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; export ASSUME_YES; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$line" =~ ^[0-9]+\.[0-9]+$ ]] || { info "⊘ --line 不是 X.Y（${line:-沒給}），這不是發布線，不釘版"; exit 0; }
branch="release/v$line"

require_clean_tree
[[ "$(current_branch)" == "$branch" ]] || die "請在 $branch 上執行（目前 $(current_branch)）"
train_sync "$branch"

for attempt in 1 2; do
  status=0
  release_pin_open_pr "$branch" "$line" || status=$?
  case "$RELEASE_PIN_RESULT" in
    pinned) info "已釘版並推送 ${branch}（$(git rev-parse --short HEAD)）。release-please 會再跑一次，第二次沒有變動就停" ;;
    push-skipped) warn "推送沒有執行" ;;
    push-failed) ;;
    *) info "沒有釘版（${RELEASE_PIN_RESULT}）${RELEASE_PIN_REASON:+：$RELEASE_PIN_REASON}" ;;
  esac
  (( status != 0 )) || exit 0
  (( attempt == 1 )) || die "推送 ${branch} 被拒兩次，不再重試。等下一次 run"
  warn "推送 ${branch} 被拒，取回最新的分支再試一次"
  read_retry git fetch -q origin "$branch" || die "git fetch origin $branch 沒成功"
  while IFS= read -r subject; do
    [[ "$subject" == "chore(facts): "* || "$subject" == "chore(docs): "* ]] \
      || die "本機領先遠端的 commit 不全是釘版 commit（${subject}），不丟掉它們"
  done < <(git log --format=%s "origin/$branch..HEAD")
  git reset -q --hard "origin/$branch"
done
