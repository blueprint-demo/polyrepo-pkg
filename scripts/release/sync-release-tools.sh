#!/usr/bin/env bash
# Bring the release tooling of the open release lines up to main: scripts/, .github/workflows/ and .github/actions/ (RELEASE_DRIFT_PATHS,
# the paths the tooling gate of advance-release.sh compares with origin/main). The sync workflow (sync-release-tools.yml) runs it when
# main changes one of them, and a person can run it by hand. For each line it restores the paths that are behind main to main's content
# in one commit and pushes it to the release branch; the scripts of main do the work, the scripts of the branch may be the old ones.
#
# usage: sync-release-tools.sh [--line X.Y] [--yes] [--dry-run]     without --line every release/vX.Y on origin is looked at
#
# A line is left alone (a skip is a success) when
#   - nothing is open: there is no release branch;
#   - the line was not opened with cut-release.sh (no Release-Train-Base commit), because then what is "its own" cannot be told;
#   - the line has pushed the product commit (chore(<branch>): product vX.Y.Z of merge-back) or its merge-back PR is open. The product tag
#     goes on the last commit of the branch, so one more commit, a sync, would be tagged and released with the product;
#   - every path equals main's.
# A line fails (and the others are still done) when a path has commits of the branch that main does not have, found with
# train_commits_not_on_main per path (by patch and by content, so an earlier sync commit does not count). Those commits are listed.
# Syncing would erase a fix made only on the branch: cherry-pick it to main first, then run this again.
#
# A path is made equal to main's: files that main no longer has are removed, files of main are restored. The commit is made in a
# temporary worktree and pushed to the branch with `git push` (never forced). When the push is refused, because the branch moved
# meanwhile, it fetches the branch and does the whole look and sync once more; a second refusal fails the line.
# It needs the token of the GitHub App (a push with GITHUB_TOKEN starts no workflow, and a change of .github/workflows needs the
# Workflows permission of the App). The checkout it runs in is not changed; it needs origin and, for the PR check, GH_TOKEN.
# No loop of this script sleeps: the single retry is written out, and external_retry waits through scripts/lib/retry.mjs.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

line=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --line) line="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; export ASSUME_YES; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -z "$line" || "$line" =~ ^[0-9]+\.[0-9]+$ ]] || die "--line 需為 X.Y"
target="$(remote_target)"

fetch_all() {
  git fetch -q --prune origin '+refs/heads/main:refs/remotes/origin/main' '+refs/heads/release/*:refs/remotes/origin/release/*' \
    || die "git fetch origin 沒成功，無法判斷發布工具落後多少"
}

wt=""
drop_worktree() {
  [[ -n "$wt" ]] || return 0
  git worktree remove --force "$wt/tree" 2>/dev/null || true
  rm -rf "$wt"
  wt=""
}
# the exit trap of common.sh reports the writes that were declined (no --yes): keep it, with the worktree dropped first
on_exit() {
  local rc=$?
  drop_worktree
  (exit "$rc")
  report_skipped_external
}
trap on_exit EXIT

# sync_line <branch> → 0: done or left alone, 1: the branch has fixes of its own, 2: the push was refused
sync_line() {
  local branch="$1" open product c commit p files ahead_msg="" pr
  local -a paths=() behind=() ahead=()
  git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null || { info "⊘ origin 上沒有 ${branch}，不做事"; return 0; }
  open="$(git log -1 --format=%H -E --grep='^Release-Train-Base: [0-9a-f]{7,40}$' "origin/$branch")"
  [[ -n "$open" ]] || { info "⊘ $branch 沒有 Release-Train-Base 的開線 commit（不是用 cut-release.sh 開的），分不出哪些是它自己的修正，不同步"; return 0; }
  product="$(git log -1 --format=%h -E --grep="^chore\\(${branch//./\\.}\\): product v[0-9]" "$open..origin/$branch")"
  if [[ -n "$product" ]]; then
    info "⊘ $branch 已推了產品 commit ${product}，產品 tag 會打在它的最後一個 commit，不再同步"
    return 0
  fi
  pr="$(gh pr list --base main --head "${branch}--to-main" --state open --json number --jq '.[0].number // empty')" \
    || die "gh pr list 沒成功，無法判斷 ${branch} 的合回 PR 是不是開著"
  if [[ -n "$pr" ]]; then
    info "⊘ ${branch} 的合回 PR #${pr} 開著，產品 tag 會打在發布分支的最後一個 commit，不再同步"
    return 0
  fi
  mapfile -t paths < <(main_existing_paths "${RELEASE_DRIFT_PATHS[@]}")
  for p in ${paths[@]+"${paths[@]}"}; do
    git diff --quiet "origin/main" "origin/$branch" -- "$p" && continue
    c="$(train_commits_not_on_main "origin/$branch" -- "$p")"
    if [[ -z "$c" ]]; then behind+=("$p"); continue; fi
    ahead+=("$p")
    while IFS= read -r commit; do
      [[ -n "$commit" ]] || continue
      files="$(git diff-tree --no-commit-id --name-only -r --no-renames "${commit%% *}" -- "$p" | paste -sd ',' - | sed 's/,/, /g')"
      ahead_msg+="  ${commit}（${files}）"$'\n'
    done <<<"$c"
  done
  if (( ${#ahead[@]} )); then
    printf '%s' "$ahead_msg" >&2
    warn "$branch 有 main 還沒有的發布工具修正（${ahead[*]}），不覆蓋。先把上面的 commit cherry-pick 到 main 並合進去，再重跑同步。沒有推送"
    return 1
  fi
  if (( ${#behind[@]} == 0 )); then info "⊘ $branch 的發布工具已和 main 相同"; return 0; fi
  log "$branch 的發布工具落後 main（${behind[*]}），同步"
  if (( DRY_RUN )); then info "[dry-run] 還原 ${behind[*]} 成 main 的內容，commit 並推到 $branch"; return 0; fi
  wt="$(mktemp -d)"
  # this function runs on the left of ||, where set -e is off, so each step that must not fail says so
  git worktree add -q --detach "$wt/tree" "origin/$branch" || die "git worktree add 沒成功"
  # make each path equal to main's: files main dropped go, files of main come back
  git -C "$wt/tree" rm -rq --ignore-unmatch -- "${behind[@]}" || die "git rm ${behind[*]} 沒成功"
  git -C "$wt/tree" restore --source=origin/main --staged --worktree -- "${behind[@]}" || die "git restore --source=origin/main 沒成功"
  if git -C "$wt/tree" diff --cached --quiet; then info "⊘ 還原之後沒有差異，不提交"; drop_worktree; return 0; fi
  git -C "$wt/tree" commit -q -m "chore($branch): sync release tooling from main" -m "git restore --source=origin/main -- ${behind[*]}" || die "git commit 沒成功"
  if external_retry push "$target" git -C "$wt/tree" push origin "HEAD:refs/heads/$branch"; then
    info "已同步 ${branch}（${behind[*]}），commit $(git -C "$wt/tree" rev-parse --short HEAD)"
    drop_worktree
    return 0
  fi
  drop_worktree
  return 2
}

fetch_all
declare -a lines=()
if [[ -n "$line" ]]; then lines=("release/v$line")
else while IFS= read -r b; do [[ "$b" =~ ^release/v[0-9]+\.[0-9]+$ ]] && lines+=("$b"); done < <(release_branches); fi
if (( ${#lines[@]} == 0 )); then info "⊘ 沒有開著的發布線，不做事"; exit 0; fi

declare -a failed=()
for b in "${lines[@]}"; do
  log "$b"
  for attempt in 1 2; do
    status=0
    sync_line "$b" || status=$?
    (( status == 2 )) || break
    if (( attempt == 2 )); then warn "推送 $b 被拒兩次，不再重試"; break; fi
    warn "推送 $b 被拒，取回最新的分支再看一次"
    fetch_all
  done
  (( status == 0 )) || failed+=("$b")
done
(( ${#failed[@]} == 0 )) || die "這些發布線沒有同步：${failed[*]}"
