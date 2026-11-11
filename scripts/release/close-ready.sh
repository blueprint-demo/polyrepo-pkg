#!/usr/bin/env bash
# Whether the merge-back PR of a release line can be closed now (merged, product tag, branches deleted), read from GitHub. The close
# workflow (close-release.yml) runs it first and goes on only when it says ready=true. It looks once, reads only, and exits 0 for
# any answer, because a PR that is not ready yet is the normal case for most events (ci and pr-message finish one after the other).
#
# usage: close-ready.sh (--pr <number> | --line X.Y) [--head-sha <sha>] [--strict]
#   --pr         the PR of the event (github.event.workflow_run.pull_requests[0].number)
#   --line       a person started the run: the open PR of release/vX.Y--to-main is the one
#   --head-sha   the head_sha of the event (github.event.workflow_run.head_sha), the commit the finished ci or pr-message ran for.
#                A PR whose head is another commit is not closed: the checks of its new head start this again.
#                Leave it out when a person started the run; the head the checks were read for is then the head of the PR.
#   --strict     exit 1 when it is not ready (a person started the run and wants to see the failure), instead of 0
# stdout, to append to $GITHUB_OUTPUT: ready=true|false, reason=<one line>, and when ready: pr=, sha=, line=
# env: GH_TOKEN (read access to pull requests, checks and statuses), GH_REPO when the checkout has no remote of the repository,
#      MERGE_CONFIG (default scripts/merge/merge-config.json, the file auto-merge reads for the required checks)
#
# The decision is scripts/release/close-ready.mjs, over the required checks of scripts/merge/decide.mjs (requiredCheckProblems), the
# same ones auto-merge reads. The order of the reads is the one of auto-merge: the head first, the checks, the PR last, so a commit
# pushed in between shows as a different head and the decision skips.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

pr="" line="" head_sha="" strict=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) pr="$2"; shift 2 ;;
    --line) line="$2"; shift 2 ;;
    --head-sha) head_sha="$2"; shift 2 ;;
    --strict) strict=1; shift ;;
    -h|--help) sed -n '2,${/^#/!q; p;}' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
config="${MERGE_CONFIG:-scripts/merge/merge-config.json}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

not_ready() { # not_ready <reason>
  warn "$1"
  printf '%s\n' "ready=false" "reason=${1//$'\n'/ }"
  (( strict == 0 )) || exit 1
  exit 0
}

if [[ -z "$pr" ]]; then
  [[ "$line" =~ ^[0-9]+\.[0-9]+$ ]] || die "--pr 或 --line X.Y 要給一個"
  pr="$(gh pr list --base main --head "release/v${line}--to-main" --state open --json number --jq '.[0].number // empty')"
  [[ -n "$pr" ]] || not_ready "release/v${line}--to-main 沒有開著的合回 PR：先開合回 PR（merge-back），或它已經合併了"
fi
[[ "$pr" =~ ^[0-9]+$ ]] || not_ready "沒有 PR 編號（${pr}）"

checked_sha="$(gh pr view "$pr" --json headRefOid --jq .headRefOid)"
# gh pr checks exits 1 for a failed check and 8 for a pending one, and the decision reads both from the output
rc=0; gh pr checks "$pr" --json name,bucket > "$out/checks.json" 2> "$out/checks.err" || rc=$?
cat "$out/checks.err" >&2
# a PR without any check yet: exit 1, nothing on stdout, "no checks reported" on stderr; the decision reads that as "has not run"
if (( rc == 1 )) && [[ ! -s "$out/checks.json" ]] && grep -q 'no checks reported on the' "$out/checks.err"; then printf '[]\n' > "$out/checks.json"; fi
(( rc == 0 || rc == 1 || rc == 8 )) || die "gh pr checks 結束碼 $rc"
# an empty or non-array output means the checks could not be read; it must not reach the decision as "no check ran"
jq -e 'type == "array"' "$out/checks.json" > /dev/null || die "gh pr checks 結束碼 ${rc}，也沒有印出 checks 的 JSON 陣列"
gh pr diff "$pr" --name-only | jq -R . | jq -s . > "$out/files.json"
gh pr view "$pr" --json number,state,isDraft,headRefOid,headRefName,baseRefName,isCrossRepository \
  | jq --arg sha "$checked_sha" --arg event "$head_sha" --slurpfile checks "$out/checks.json" --slurpfile files "$out/files.json" \
      '{pr: ., checkedSha: $sha, eventHeadSha: (if $event == "" then null else $event end), checks: $checks[0], changedFiles: $files[0]}' > "$out/input.json"
node "$(dirname "$0")/close-ready.mjs" --input "$out/input.json" --config "$config" > "$out/decision.json"
reason="$(jq -r .reason "$out/decision.json")"
if [[ "$(jq -r .action "$out/decision.json")" != close ]]; then not_ready "$reason"; fi
info "可以收尾 PR #${pr}：${reason}" >&2
printf '%s\n' "ready=true" "reason=$reason" "pr=$(jq -r .pr "$out/decision.json")" "sha=$(jq -r .sha "$out/decision.json")" "line=$(jq -r .line "$out/decision.json")"
