#!/usr/bin/env bash
# Waiting for and merging a release-please Release PR, shared by scripts/release/merge-release-pr.sh and the
# scenario scripts (examples/lib/scenario.sh). Source it through common.sh; do not execute.
# 輪詢間隔決定「事情做完後多久才被發現」，次數乘間隔決定「多久才放棄」。兩者要分開調：間隔縮短時
# 若沿用原本的 40 次，上限會跟著縮短（原本 15 秒乘 40 次是 10 分鐘，3 秒乘 40 次只剩 2 分鐘），
# 比現在更容易把「還在排隊」誤判成失敗（實測 release-please 曾排隊逾 10 分鐘）。目前是 3 秒乘 180 次，
# 每個等待迴圈的睡眠時間上限是 9 分鐘（不含每輪 gh 呼叫本身的耗時）。release_pr_settle 依序有
# 好幾個迴圈，每個各自有這個上限。
POLL_TRIES="${POLL_TRIES:-180}" POLL_SLEEP="${POLL_SLEEP:-3}"

# wait_release_pr <base-branch> → prints PR number.
# Identify the Release PR by its head branch, not by the "autorelease: pending" label: release-please
# opens the PR first and labels it afterwards, so a run that fails in between leaves a real, usable
# Release PR with no label at all (observed 2026-09-07).
wait_release_pr() {
  local base="$1" n="" i
  for ((i=1; i<=POLL_TRIES; i++)); do
    n="$(gh pr list --base "$base" --head "release-please--branches--$base" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [[ -z "$n" ]] && n="$(gh pr list --base "$base" --label 'autorelease: pending' --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [[ -n "$n" ]] && { printf '%s\n' "$n"; return 0; }
    sleep "$POLL_SLEEP"
  done
  return 1
}

# release_please_paths → the paths release-please.yml filters its push trigger by (on.push.paths), one per line, "dir/**"
# written as "dir" because that is how git's pathspec reads it. Reads RELEASE_PLEASE_WORKFLOW (default
# .github/workflows/release-please.yml). Fails when the file is missing or lists no path, so a caller never mistakes
# "could not read the filter" for "nothing to look at".
release_please_paths() {
  local file="${RELEASE_PLEASE_WORKFLOW:-.github/workflows/release-please.yml}" out
  [[ -f "$file" ]] || return 1
  out="$(awk '
    /^    paths:[[:space:]]*$/ { in_paths = 1; next }
    in_paths && /^[[:space:]]*#/ { next }
    in_paths && /^      -[[:space:]]/ { v = $0; sub(/^      -[[:space:]]+/, "", v); gsub(/["\047]/, "", v); sub(/[[:space:]]+#.*$/, "", v); sub(/\/\*\*$/, "", v); print v; next }
    in_paths { exit }
  ' "$file")"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# release_please_settled <branch> [<sha>] → looks once, never waits. Returns 0 when release-please has processed the branch,
# otherwise 1 with RELEASE_PLEASE_WAITING set to what it is still waiting for. Both of these have to hold:
#   1. no release-please run on <branch> is queued or in progress
#   2. the newest finished run's commit and the tip of origin/<branch> differ in none of the paths release-please.yml
#      filters by. "The tip has a finished run" would not do: a commit that only touches tooling starts no run at all.
# The newest finished run must also have concluded success: after a failed or cancelled run the versions were not recomputed,
# and the message names the conclusion and the link of that run.
# With <sha>, the commit this script just pushed, the newest finished run must be the run of <sha> itself: right after a push
# the run for that commit may not have started yet, and the finished runs of older commits make the branch look settled.
# A branch with no run at all counts as settled; the caller goes on to look for the Release PR, which does not exist yet then.
# Fetch origin/<branch> first: the comparison reads it. Call it in the shell itself, not in $(...), to keep the variable.
RELEASE_PLEASE_WAITING=""
release_please_settled() {
  local branch="$1" sha="${2:-}" runs open latest conclusion paths
  RELEASE_PLEASE_WAITING=""
  # a failed gh call is not "no runs": it leaves the branch unsettled and the caller asks again
  if ! runs="$(gh run list --workflow release-please.yml --branch "$branch" --limit 20 --json status,headSha,conclusion,url --jq '.[] | "\(.status) \(.headSha) \(.conclusion // "-") \(.url // "-")"' 2>/dev/null)"; then
    RELEASE_PLEASE_WAITING="release-please 的 run 清單查不到（gh run list 失敗）"
    return 1
  fi
  open="$(grep -v '^completed ' <<<"$runs" || true)"
  if [[ -n "$open" ]]; then
    RELEASE_PLEASE_WAITING="release-please 仍在執行或排隊（$(head -1 <<<"$open" | cut -d' ' -f1)）"
    return 1
  fi
  latest="$(head -1 <<<"$runs" | cut -d' ' -f2)"
  # the newest finished run did not succeed: the versions were not recomputed, whatever the paths say
  conclusion="$(head -1 <<<"$runs" | cut -d' ' -f3)"
  if [[ -n "$latest" && "$conclusion" != success ]]; then
    RELEASE_PLEASE_WAITING="release-please 最新一筆 run 的結論是 ${conclusion}（$(head -1 <<<"$runs" | cut -d' ' -f4)），版號沒有算完。處理後再觸發"
    return 1
  fi
  if [[ -n "$sha" ]]; then
    grep -q "^completed ${sha} " <<<"$runs" && return 0
    RELEASE_PLEASE_WAITING="release-please 仍在執行：還沒有 ${sha:0:7} 的 run 跑完"
    return 1
  fi
  [[ -n "$latest" ]] || return 0
  if ! paths="$(release_please_paths)"; then
    RELEASE_PLEASE_WAITING="讀不到 release-please.yml 的 on.push.paths，無法判斷 run 之後有沒有新的變更"
    return 1
  fi
  if ! git cat-file -e "${latest}^{commit}" 2>/dev/null; then
    RELEASE_PLEASE_WAITING="release-please 仍在處理：最新的 run 的 commit ${latest:0:7} 不在本機"
    return 1
  fi
  local -a specs=()
  mapfile -t specs <<<"$paths"
  if ! git diff --quiet "$latest" "origin/$branch" -- "${specs[@]}"; then
    RELEASE_PLEASE_WAITING="release-please 仍在處理：最新的 run（${latest:0:7}）之後，分支上 release-please 會看的路徑還有變更"
    return 1
  fi
  return 0
}

# wait_release_please_idle <branch> [<sha>]
# Ask release_please_settled up to POLL_TRIES times, POLL_SLEEP apart. A Release PR that predates the commit we just pushed
# would release the wrong version (observed 2026-09-07: merged a stale PR). Returns 1 when it is still not settled after the
# last round, with the reason printed: a caller must not merge on a Release PR release-please has not recomputed. It does
# not go on with a warning, on a machine as little as in a workflow.
wait_release_please_idle() {
  local branch="$1" sha="${2:-}" i
  for ((i=1; i<=POLL_TRIES; i++)); do
    git fetch -q origin "$branch" 2>/dev/null || true
    release_please_settled "$branch" "$sha" && return 0
    sleep "$POLL_SLEEP"
  done
  warn "$RELEASE_PLEASE_WAITING"
  return 1
}

# manifest as it stands on the Release PR's head branch, i.e. the content a merge would land
release_pr_manifest() { # release_pr_manifest <base-branch>
  local head="release-please--branches--$1"
  git fetch -q origin "$head" 2>/dev/null || return 1
  git show "FETCH_HEAD:$MANIFEST" 2>/dev/null
}

# release_pr_units <base-branch> → "<unit> <version>" per line: the units whose manifest version on the
# Release PR's head differs from origin/<base-branch>'s, with the PR's version. This is the set a merge
# of that PR releases. Fetch <base-branch> first; the comparison reads origin/<base-branch>.
release_pr_units() {
  local base="$1" mf p v
  mf="$(release_pr_manifest "$base")" || return 1
  while read -r p v; do
    [[ -n "$p" ]] && printf '%s %s\n' "$(unit_component "$p")" "$v"
  done < <(jq -r -s '.[0] as $cur | .[1] | to_entries[] | select(.value != $cur[.key]) | "\(.key) \(.value)"' \
    <(git show "origin/$base:$MANIFEST") <(printf '%s\n' "$mf"))
}

# release_pr_settle <base-branch> [--optional] [--expect-stable] [--sha <commit>]
# Sets RELEASE_PR_NUMBER and RELEASE_PR_SHA once the Release PR's head has stopped moving.
# --optional：沒有 Release PR 時回傳 1 而不中止。切自產品 tag 的修補發布在 hotfix 合入前本來就無版可發。
# --expect-stable：GA 用。只在 PR 內容已無 prerelease 版號時才算穩定。
# --sha：剛推送到 <base-branch> 的 commit。release-please 對這個 commit 的 run 跑完才算閒置，
#   不然推送後 run 還沒開始時，舊 commit 的 run 都已完成，會被當成已經停下（wait_release_please_idle）。
#
# 「現在沒有執行中的 run」不足以判定 PR 是最新的：release-please 每跑一次就重寫該 PR，閒置檢查通過
# 之後才啟動的 run 會把內容換掉，於是合併到的是舊版本（實測 2026-09-08：GA 合併到仍帶預發布版號的
# PR，發布分支因此停在 prerelease）。改為等 head SHA 在一次重查後仍相同，必要時再核對內容。
release_pr_settle() {
  local base="$1" n optional=0 expect_stable=0 i sha prev="" mf pushed=""
  RELEASE_PR_NUMBER="" RELEASE_PR_SHA=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --optional) optional=1 ;;
      --expect-stable) expect_stable=1 ;;
      --sha) pushed="${2:-}"; [[ -n "$pushed" ]] || die "release_pr_settle: --sha 需要一個 commit"; shift ;;
    esac
    shift
  done
  log "等待 $base 上的 release-please 執行完畢（避免合併過期的 Release PR）…"
  wait_release_please_idle "$base" "$pushed" || die "release-please 還沒處理完 ${base}，不繼續。等它處理完再重跑"
  log "等待 release-please 在 $base 開 Release PR…"
  if ! n="$(wait_release_pr "$base")"; then
    (( optional )) && { info "$base 目前沒有可發版的變更，略過"; return 1; }
    die "逾時：$base 上沒有 Release PR（查 gh run list --workflow release-please.yml）"
  fi
  for ((i=1; i<=POLL_TRIES; i++)); do
    wait_release_please_idle "$base" "$pushed" || die "release-please 還沒處理完 ${base}，不繼續。等它處理完再重跑"
    sha="$(gh pr view "$n" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
    if [[ -n "$sha" && "$sha" == "$prev" ]]; then
      (( expect_stable )) || break
      mf="$(release_pr_manifest "$base" || true)"
      if [[ -n "$mf" ]] && ! printf '%s\n' "$mf" | jq -e 'any(.[]; test("-"))' >/dev/null 2>&1; then break; fi
      warn "Release PR #$n 仍帶 prerelease 版號，等 release-please 重新產生"
    fi
    (( i == POLL_TRIES )) && die "逾時：Release PR #$n 內容未收斂"
    prev="$sha"; sleep "$POLL_SLEEP"
  done
  RELEASE_PR_NUMBER="$n" RELEASE_PR_SHA="$sha"
  info "Release PR #${n}：$(gh pr view "$n" --json title --jq .title)"
}

# --- version check and pin, shared by scripts/release/merge-release-pr.sh and scripts/release/pin-release-pr.sh ---

# release_pr_open_number <branch> → the number of the open Release PR of <branch>, empty when there is none. Looks once.
# Found by its head branch, as wait_release_pr does. A failed gh call stops the script: it is not "no PR".
release_pr_open_number() {
  local base="$1" out
  out="$(gh pr list --base "$base" --head "release-please--branches--$base" --state open --json number --jq '.[0].number // empty')" \
    || die "查不到 ${base} 的 Release PR（gh pr list 失敗）"
  printf '%s\n' "$out"
}

# release_pr_check_unit_version <unit> <pr version> <line> <branch> → adds a line to version_problems when the version is not
# what it must be (the rules are in the header of scripts/release/merge-release-pr.sh).
# Runs in the shell itself, not in $(...), because unit_released stops the script when it cannot read the tags.
declare -a version_problems=()
release_pr_check_unit_version() {
  local u="$1" v="$2" line="$3" branch="$4" p type base stage vs line_stage latest cur want
  p="$(jq -r --arg u "$u" '.packages | to_entries[] | select((.value.component // (.key | split("/") | last)) == $u) | .key' "$CONFIG" | head -1)"
  [[ -n "$p" ]] || return 0
  stage="$(config_unit_stage "$p")"
  # once the line is at ga the Release PR carries final versions, while the config of a unit still says its last prerelease
  # stage until the merge-back restores it
  [[ "$(train_stage)" != ga ]] || stage=ga
  if unit_released "$u"; then
    if ! vs="$(version_stage "$v")"; then
      version_problems+=("${u} PR 版號 ${v}，預期階段 ${stage} 的版號（X.Y.Z 或 X.Y.Z-<階段>.N）")
      return 0
    fi
    # a unit that only walks ga ships its final version at once, so on an early line its own stage (ga) is the latest
    # one it may be in; any other unit may not be later than the line
    line_stage="$(train_stage)"
    latest="$line_stage"
    if policy_unit_exists "$u"; then
      latest="$(unit_stage_at "$u" "$line_stage")"
      [[ -n "$latest" ]] || latest="$line_stage"
      (( $(stage_index "$latest") >= $(stage_index "$line_stage") )) || latest="$line_stage"
    fi
    if [[ "$vs" != "$stage" ]] || (( $(stage_index "$vs") > $(stage_index "$latest") )); then
      version_problems+=("${u} PR 版號 ${v}，預期階段 ${stage}（設定裡的階段，且不晚於 ${latest}）")
    fi
    return 0
  fi
  type="$(unit_release_type "$p")"
  base="$(unit_main_base_version "$p" "$line")"
  cur="$(git show "origin/$branch:$MANIFEST" | jq -r --arg p "$p" '.[$p] // empty')"
  want="$(unit_first_version "$type" "$base" "$stage" "$line" "$cur")"
  [[ "$v" == "$want" ]] || version_problems+=("${u} PR 版號 ${v}，預期 ${want}（沒有 tag，第一版）")
  return 0
}

# release_pr_check_versions <line> <branch> "<unit> <version>"... → one round over the units; version_problems is empty when
# every version is what it must be
release_pr_check_versions() {
  local line="$1" branch="$2" pair; shift 2
  version_problems=()
  for pair in "$@"; do release_pr_check_unit_version "${pair% *}" "${pair#* }" "$line" "$branch"; done
  return 0
}

# release_pin_open_pr <branch> <line> → pins the "next" of facts/ and docs/ to the versions the open Release PR of <branch> gives,
# commits (chore(facts), chore(docs)) and pushes. The one pin, for merge-release-pr.sh and for the release-please job. It
# stops short, with success, whenever one of its conditions does not hold, because a pin made on a Release PR that release-please
# is about to recompute is a pin to the old version and cannot be fixed afterwards. In this order:
#   1. an open Release PR; none → RELEASE_PIN_RESULT=no-pr (a re-run of the job that merged it, for one)
#   2. the local branch is not behind origin/<branch>
#   3. the paths release-please watches (release_please_paths) do not differ between the base of the Release PR (the parent of
#      its head, the branch tip of the run that wrote it) and the tip of origin/<branch>; else the branch moved after the run,
#      and the run for the newer commit will write the PR again → RELEASE_PIN_RESULT=skipped
#   4. verify one round of the versions of the units the PR releases (release_pr_check_unit_version) → skipped on a mismatch
# Then it pins and commits. It pushes whenever the local branch is ahead of origin, not only when it just committed: an earlier
# run may have made the commit and failed to push. RELEASE_PIN_RESULT is one of:
#   no-pr | skipped (RELEASE_PIN_REASON says why) | unchanged (nothing to pin, nothing to push) | pinned (pushed; release-please
#   runs again and the PR is recomputed) | push-skipped (the push was not confirmed) | push-failed (returns 1)
# Fetches origin itself. The working tree must be clean and on <branch>. Call it in the shell itself, not in $(...), to keep
# the variables.
RELEASE_PIN_RESULT="" RELEASE_PIN_REASON=""
# shellcheck disable=SC2034 # RELEASE_PIN_RESULT is read by pin-release-pr.sh and merge-release-pr.sh, which source this file
release_pin_open_pr() {
  local branch="$1" line="$2" n head_ref pr_sha base paths out row pair u v comps
  local -a specs=() pr_units=() pinned=() docs_pinned=()
  RELEASE_PIN_RESULT="" RELEASE_PIN_REASON=""
  n="$(release_pr_open_number "$branch")"
  if [[ -z "$n" ]]; then
    RELEASE_PIN_RESULT=no-pr
    info "⊘ ${branch} 沒有開著的 Release PR，不釘版"
    return 0
  fi
  head_ref="release-please--branches--$branch"
  git fetch -q origin "$branch" || die "git fetch origin $branch 沒成功"
  git fetch -q origin "$head_ref" || die "git fetch origin $head_ref 沒成功"
  pr_sha="$(git rev-parse FETCH_HEAD)"
  if ! git merge-base --is-ancestor "origin/$branch" HEAD; then
    RELEASE_PIN_RESULT=skipped RELEASE_PIN_REASON="本機的 ${branch} 落後遠端，留給下一次 run"
    warn "$RELEASE_PIN_REASON"; return 0
  fi
  if ! paths="$(release_please_paths)"; then
    RELEASE_PIN_RESULT=skipped RELEASE_PIN_REASON="讀不到 release-please.yml 的 on.push.paths，無法確認 Release PR 的基底"
    warn "$RELEASE_PIN_REASON"; return 0
  fi
  base="$(git rev-parse -q --verify "${pr_sha}^" || true)"
  if [[ -z "$base" ]]; then
    RELEASE_PIN_RESULT=skipped RELEASE_PIN_REASON="Release PR #${n} 的 head 沒有父 commit，無法確認它的基底"
    warn "$RELEASE_PIN_REASON"; return 0
  fi
  mapfile -t specs <<<"$paths"
  if ! git diff --quiet "$base" "origin/$branch" -- "${specs[@]}"; then
    RELEASE_PIN_RESULT=skipped RELEASE_PIN_REASON="Release PR #${n} 的基底（${base:0:7}）之後，${branch} 上 release-please 會看的路徑又有變更，Release PR 還會被重算"
    info "⊘ ${RELEASE_PIN_REASON}，不釘版"; return 0
  fi
  out="$(release_pr_units "$branch")" || die "取 manifest 失敗：讀不到 Release PR 或 origin/${branch} 的 manifest，不是「沒有差異」"
  while IFS= read -r row; do [[ -n "$row" ]] && pr_units+=("$row"); done < <(sort <<<"$out")
  if (( ${#pr_units[@]} == 0 )); then
    RELEASE_PIN_RESULT=skipped RELEASE_PIN_REASON="Release PR #${n} 對 origin/${branch} 的 manifest 沒有差異，沒有版號可釘"
    info "⊘ ${RELEASE_PIN_REASON}"; return 0
  fi
  release_pr_check_versions "$line" "$branch" "${pr_units[@]}"
  if (( ${#version_problems[@]} )); then
    RELEASE_PIN_RESULT=skipped RELEASE_PIN_REASON="Release PR #${n} 的版號不符：${version_problems[*]}"
    warn "${RELEASE_PIN_REASON}。不釘版，等 release-please 重算"; return 0
  fi

  if has_facts; then
    declare -A comp_units=()
    comps="$(facts_components)"
    while IFS=$'\t' read -r _ u; do [[ -n "$u" ]] && comp_units[$u]=1; done <<<"$comps"
    for pair in "${pr_units[@]}"; do
      u="${pair% *}" v="${pair#* }"
      [[ -n "${comp_units[$u]:-}" ]] || continue
      facts_pin "$u" "$v"
      pinned+=("$u@$v")
    done
    if [[ -n "$(git status --porcelain -- facts)" ]]; then
      git add -- facts
      run git commit -q -m "chore(facts): 釘 next 為 ${pinned[*]}" \
        -m "合併 Release PR #${n} 之前，把這次要發的單元的 next 釘成 PR 的版號。釘在發布分支，不放 Release PR 分支，因為 release-please 重算時會強制改寫它。"
    else
      info "⊘ 沒有要釘的 next，不加新的 commit"
    fi
  fi

  # 文件套件：和 facts 同一個位置釘，用 clarify-kit pin。docs/<單元> 存在的單元，才釘成 PR 給它的版號
  if has_docs; then
    for pair in "${pr_units[@]}"; do
      u="${pair% *}" v="${pair#* }"
      docs_unit_dir "$u" >/dev/null || continue
      docs_pin_unit "$u" "$v"
      docs_pinned+=("$u@$v")
    done
    if [[ -n "$(git status --porcelain -- docs)" ]]; then
      git add -- docs
      run git commit -q -m "chore(docs): 釘 next 為 ${docs_pinned[*]}" \
        -m "合併 Release PR #${n} 之前，把這次要發的單元的文件 next 釘成 PR 的版號。釘在發布分支，不放 Release PR 分支，因為 release-please 重算時會強制改寫它。"
    else
      info "⊘ 文件套件沒有要釘的 next，不加新的 commit"
    fi
  fi

  # 看本機是否領先遠端，不看這次有沒有新變動：上一次可能建好 commit 卻沒推出去（答 n、沒帶 --yes、推送失敗），
  # 重跑時 facts 已乾淨，只看變動會跳過推送，check 讀本機工作樹通過，釘版卻沒到遠端
  RELEASE_PIN_RESULT=unchanged
  if (( $(git rev-list --count "origin/$branch..HEAD") > 0 )); then
    if ! external_retry push "$(remote_target)" git push origin "$branch"; then
      RELEASE_PIN_RESULT=push-failed RELEASE_PIN_REASON="推送 ${branch} 沒成功"
      return 1
    fi
    if (( ${#SKIPPED_EXTERNAL[@]} )); then RELEASE_PIN_RESULT=push-skipped; return 0; fi
    RELEASE_PIN_RESULT=pinned
  fi
  return 0
}

# release_pr_squash <number> <head-sha>: squash-merge only if the PR head is still <head-sha>, so a PR
# that release-please rewrote after the checks is refused instead of merged
release_pr_squash() {
  external_retry merge "$(remote_target)" gh pr merge "$1" --squash --match-head-commit "$2"
}

# merge_release_pr <base-branch> [--optional] [--expect-stable]
# Wait for a settled Release PR and squash-merge it. No pin and no fact-kit check: those belong to
# scripts/release/merge-release-pr.sh, which a person uses on a real release line.
merge_release_pr() {
  if (( DRY_RUN )); then info "[dry-run] 等待並合併 $1 上的 Release PR"; return 0; fi
  release_pr_settle "$@" || return 1
  release_pr_squash "$RELEASE_PR_NUMBER" "$RELEASE_PR_SHA"
}
