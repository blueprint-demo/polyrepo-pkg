#!/usr/bin/env bash
# Merge the Release PR of a release line. This is the one way to merge it: the fact-kit check below is only
# a gate when the merge goes through it, because a private repository on the free plan cannot make a
# check required.
# The pin (step 3) is normally done earlier, by the release-please job after it has written the Release PR
# (scripts/release/pin-release-pr.sh, which calls the same release_pin_open_pr as this script). This script pins too, as the
# fallback for a repository without the GitHub App, and for a pin that job missed or did not finish.
#
# usage: merge-release-pr.sh --line X.Y [--yes] [--dry-run]
#
# Order, on release/vX.Y:
#   1. release-please must have processed the branch (release_please_settled in scripts/lib/release-pr.sh): no run queued or in
#      progress, and no path it watches differs between its newest finished run and the branch tip. When it has not, the
#      script stops after POLL_TRIES looks and merges nothing, on a machine as in a workflow. Then the Release PR's head must stop moving
#   2. the units this merge releases: the manifest on the PR's head against origin/release/vX.Y, the PR's
#      version for each unit that differs. Each version is checked before anything else happens (see below)
#   3. release_pin_open_pr (scripts/lib/release-pr.sh) checks that no commit release-please processes (a releasable commit on a unit path, or a change of the config or
#      manifest) lies between the base of the Release PR and the branch tip, checks the versions once more, then pins. With facts/: for each unit that has a component
#      package (its directory under facts/ is named after the unit),
#      `fact-kit pin --version <v> --cwd facts/<dir>`. Pinned rows are committed on the release branch as
#      `chore(facts)`; the branch is pushed whenever it is ahead of origin, so a run whose push was skipped or
#      failed pushes on the next run. Never on the PR branch, which release-please rewrites with force
#   4. after the push the script stops: the push makes release-please run again and recompute the PR. Run it again once
#      release-please has processed the pin commit; the second run has nothing to pin, checks the versions and merges
#   5. `fact-kit check --train <unit>=<v>` for those units. A row still saying "next" that is not pending
#      fails it, printed as <file>:<line>. This script does not pin again on its own: fix the row (or mark it
#      pending) and run the script again
#   6. `gh pr merge --squash --match-head-commit <sha>`
# A repository without facts/ pins no facts and skips 5, and merges.
#
# Version check (git-release asks for it, and a wrong Release PR was merged without it: sdk-py and sdk-rs went from
# 0.1.0 to 0.2.0-alpha.1). Right after step 2 every unit's PR version is
# compared with what it must be:
#   - a unit with no <component>/v* tag on the remote: the first version of unit_first_version (the same function
#     advance-release.sh and finalize-release.sh write Release-As from), e.g. 0.1.0-beta.1
#   - a unit with a tag: the stage name of its version equals its stage in the branch config (ga once the line is at
#     ga) and is not later than its result stage on the line, which the policy gives and which is never earlier than the
#     stage of the line (1.2.0-alpha.1 → 1.2.0-alpha.2 passes, 0.2.0-alpha.1 for a unit at beta does not)
# release-please may not have recomputed the PR after the latest push, so a mismatch is not final: the PR is read again
# the way release_pr_settle waits (POLL_TRIES times, POLL_SLEEP apart). Only when it still does not match at the end
# the script stops without merging and prints the unit, the PR version and the expected one.
#
# The document package (docs/) is pinned in the same place as the facts, by clarify-kit pin: for each unit this
# merge releases, the "next" of docs/<unit>/**/*.doc.ts becomes the PR's version for that unit, committed as
# `chore(docs)` and pushed together with the `chore(facts)` commit (scripts/lib/docs.sh; the product layer,
# docs/product, was pinned to the product version when cut-release.sh opened the train).
#
# The release line must be checked out, with a clean tree.
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
[[ "$line" =~ ^[0-9]+\.[0-9]+$ ]] || die "--line 需為 X.Y"
branch="release/v$line"

require_clean_tree
[[ "$(current_branch)" == "$branch" ]] || die "請在 $branch 上執行（目前 $(current_branch)）"
train_sync "$branch"

if (( DRY_RUN )); then
  log "[dry-run] 合併 $branch 的 Release PR 的順序："
  info "1. release-please 要處理完（沒有排隊或執行中的 run，最新的 run 之後 release-please 會看的路徑沒有差異），等不到就中止；然後等 Release PR 的 head 穩定"
  if has_facts; then
    info "2. 這次要釘的單元：Release PR 的 manifest 對 origin/$branch 有差異的單元，版號取 PR 的值"
    info "   同時核對每個單元的 PR 版號：沒有 tag 的單元要等於第一版版號，有 tag 的單元階段要對上設定且不晚於它在這條線的結果階段；不符就重讀 PR，等到對上或逾時才停"
    info "3. 逐個 component 套件 fact-kit pin --version <v>，有變動才提交並推送 chore(facts)"
    info "4. 有推送釘版 commit 時中止，印出等 release-please 處理完再觸發；沒有推送才往下"
    info "5. fact-kit check --train <單元>=<v>"
    info "對得到 component 套件的單元："
    facts_components | sed 's/^/    /' | tr '\t' ' '
  else
    info "沒有 facts/：略過 pin 與 check"
  fi
  if has_docs; then
    info "文件套件：對 docs/<單元> 或 docs/<套件> 存在的單元，用 clarify-kit pin 把 *.doc.ts 的 next（since、decision 的 appliesFrom、requirement 的 release）釘成 PR 的版號，pending 不動，有變動才提交 chore(docs)"
  fi
  info "6. gh pr merge --squash --match-head-commit <sha>"
  exit 0
fi

# GA 的 Release PR 一律是正式版號，所以階段是 ga 時等 PR 內容收斂到沒有 prerelease
declare -a settle_opts=()
[[ "$(train_stage)" == ga ]] && settle_opts+=(--expect-stable)
release_pr_settle "$branch" ${settle_opts[@]+"${settle_opts[@]}"}
n="$RELEASE_PR_NUMBER" sha="$RELEASE_PR_SHA"

declare -a units=()
read_units() {
  units=()
  local out row
  git fetch -q origin "$branch" || die "取 manifest 失敗：git fetch origin $branch 沒成功"
  out="$(release_pr_units "$branch")" || die "取 manifest 失敗：讀不到 Release PR 或 origin/${branch} 的 manifest，不是「沒有差異」"
  while IFS= read -r row; do [[ -z "$row" ]] || units+=("$row"); done < <(sort <<<"$out")
}
read_units
(( ${#units[@]} )) || die "Release PR #${n} 對 origin/${branch} 的 manifest 沒有差異，沒有可合併的版號"

# verify_versions: check every unit; on a mismatch read the PR again and check again, up to POLL_TRIES times
# shellcheck disable=SC2154 # version_problems is set by release_pr_check_versions in release-pr.sh
verify_versions() {
  local i
  for ((i=1; i<=POLL_TRIES; i++)); do
    release_pr_check_versions "$line" "$branch" "${units[@]}"
    (( ${#version_problems[@]} )) || return 0
    if (( i == POLL_TRIES )); then
      printf '✗ Release PR #%s 的版號不符，不合併：\n' "$n" >&2
      printf '    %s\n' "${version_problems[@]}" >&2
      exit 1
    fi
    warn "Release PR #${n} 的版號和預期不符，等 release-please 重算（${i}/${POLL_TRIES}）：${version_problems[*]}"
    sleep "$POLL_SLEEP"
    release_pr_settle "$branch" ${settle_opts[@]+"${settle_opts[@]}"}
    n="$RELEASE_PR_NUMBER" sha="$RELEASE_PR_SHA"
    read_units
    (( ${#units[@]} )) || die "Release PR #${n} 對 origin/${branch} 的 manifest 沒有差異，沒有可合併的版號"
  done
}
verify_versions
info "這次合併會發：${units[*]}"

# 釘版：和 release-please 的 job 共用同一個函式（release_pin_open_pr，scripts/lib/release-pr.sh）。它先確認 Release PR 的基底
# 到發布分支尖端之間沒有差異、再核對一輪版號，才釘 facts 與文件套件的 next、提交並推送。上面已經等到 release-please 處理完
# 並核對過版號，這裡再核對一輪是因為釘版前的最後一道關：這之間 Release PR 若被重算，函式不釘，這裡也不合併。
release_pin_open_pr "$branch" "$line" || die "釘版後推送 ${branch} 沒成功，沒有合併"
case "$RELEASE_PIN_RESULT" in
  unchanged) ;;
  push-skipped)
    warn "推送沒有執行，停在這裡：確認後帶 --yes 重跑"
    exit 0 ;;
  pinned)
    # 推送會讓 release-please 再跑一次，Release PR 之後會被重算。這裡不等，因為 workflow 的 job 不能空等，
    # 本機也一樣：釘完推送就停，等 release-please 處理完這個 commit 再重跑，重跑時沒有東西要釘，直接核對並合併。
    die "已釘版並推送 ${branch}（$(git rev-parse --short HEAD)），沒有合併。等 release-please 處理完這個 commit 之後再觸發一次（merge-release-pr.sh --line ${line}），重跑時沒有要釘的，會核對版號後合併" ;;
  *) die "沒有釘版，也沒有合併（${RELEASE_PIN_RESULT}）：${RELEASE_PIN_REASON:-Release PR 已不存在}。等 release-please 處理完再觸發一次" ;;
esac

if has_facts; then
  # 等待期間可能又有修補合進發布分支。check 要讀合併時發布分支的內容，所以先同步到遠端最新
  train_sync "$branch"
  declare -a train=()
  for pair in "${units[@]}"; do train+=("${pair% *}=${pair#* }"); done
  facts_train_check "${train[@]}" \
    || die "fact-kit check --train 未通過（上面列出 <檔案>:<行>）。修正後重跑 merge-release-pr.sh --line ${line}，不會自動重釘"
else
  info "⊘ 沒有 facts/，略過 pin 與 fact-kit check"
fi

release_pr_squash "$n" "$sha"
printf '\n'
info "已合併 Release PR #${n}。下一步見該階段的說明：advance-release.sh 或 finalize-release.sh --phase ga|merge-back"
