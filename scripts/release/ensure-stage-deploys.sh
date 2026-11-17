#!/usr/bin/env bash
# Dispatch deploy-prerelease for every prerelease the train has released but never deployed.
#
# The dispatch normally happens in release-please.yml right after the release step. If that run
# fails after the release (and its tag) was created (observed 2026-09-09 as a transient GitHub
# GraphQL error) the dispatch step is skipped, and nothing retries: tags created with GITHUB_TOKEN
# raise no push event. This script is idempotent, so release-please.yml runs it after every run,
# including failed ones: it reads the manifest on the current branch, and for each app or service unit with a
# prerelease version whose tag exists, looks at the newest deploy-prerelease run of the tag. No run, or a run that
# failed while the run before it did not, dispatches one again. Two failed runs in a row are not dispatched again:
# the script prints ✗ with both run ids and ends 1 after it went through every unit, so the failure is seen and a
# persistent one is not retried on every run. A run that is still going, or succeeded, counts as dispatched, and
# so does the run a retry started. A tag with nothing to
# deploy at its stage (no environment declared for the unit, scripts/deploy/route-tag.sh) is skipped, not
# dispatched. A repository without apps/ or services/ units has nothing to look at, so it never reaches route-tag.sh.
#
# The reads of the remote (the tag, the runs) are asked again after a transient error (read_retry of scripts/lib/common.sh). A read
# that still fails stops the script with the error of git or gh: a failed read is not "no tag" or "no run", because reading it as
# one dispatches a deploy that may already exist, or skips one that is missing.
#
# usage: ensure-stage-deploys.sh   (env: GH_TOKEN)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$(git rev-parse --show-toplevel)"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
# unit 名稱一律取設定的 component，設定沒有時才退回資料夾名稱（ADR-004 第 36 項）
units="$(jq -r --slurpfile cfg release-please-config.json '
  ($cfg[0].packages) as $pkgs
  | to_entries[]
  | select(.key | startswith("apps/") or startswith("services/"))
  | select(.value | test("-"))
  | "\($pkgs[.key].component // (.key | split("/")[1])) \(.value)"
' .release-please-manifest.json)"
rc=0
while read -r unit ver; do
  [[ -n "$unit" ]] || continue
  tag="$unit/v$ver"
  # stderr goes to a file: a retried read prints its failed rounds on stderr, and any text on stdout means the tag exists
  found="$(read_retry git ls-remote --tags origin "refs/tags/$tag" 2>"$err")" \
    || die "讀不到 $tag 有沒有建立（git ls-remote --tags origin），沒有派送：$(cat "$err")"
  if [[ -z "$found" ]]; then printf '%s\n' "  ⊘ $tag 尚未建立，略過"; continue; fi
  route="$(bash scripts/deploy/route-tag.sh "$tag")"
  if [[ "$(sed -n 's/^skip=//p' <<<"$route")" == true ]]; then
    printf '%s\n' "  ⊘ $tag 無需部署：$(sed -n 's/^reason=//p' <<<"$route")"; continue
  fi
  # a run dispatched with --ref <tag> carries the tag as its head branch. The two newest runs, newest first: one
  # failed run is dispatched again, two in a row are not. A tag with no run gives [] and exit 0; a query that fails stops here.
  runs="$(read_retry gh run list --workflow deploy-prerelease.yml --branch "$tag" --limit 2 --json status,conclusion,databaseId 2>"$err")" \
    || die "讀不到 $tag 的 deploy-prerelease run（gh run list），沒有派送：$(cat "$err")"
  verdict="$(jq -r 'def bad: .status == "completed" and .conclusion != "success";
    if length == 0 then "none"
    elif (.[0] | bad) then (if length > 1 and (.[1] | bad) then "failed2 \(.[0].databaseId) \(.[1].databaseId)" else "failed1 \(.[0].databaseId) \(.[0].conclusion)" end)
    else "ok" end' <<<"$runs")"
  read -r kind id1 id2 <<<"$verdict"
  case "$kind" in
    ok) printf '%s\n' "  ✓ $tag 已有 deploy-prerelease run" ;;
    failed2)
      printf '%s\n' "  ✗ $tag 最近兩次 deploy-prerelease 都失敗（run ${id1}、${id2}），不再重派；修好部署後手動派送"
      rc=1 ;;
    *)
      if [[ "$kind" == failed1 ]]; then why="上一次 run ${id1} 結論為 ${id2}，重派"; else why="補派送"; fi
      printf '%s\n' "  → $why deploy-prerelease（$(sed -n 's/^env=//p' <<<"$route")）：$tag"
      gh workflow run deploy-prerelease.yml --ref "$tag" -f tag="$tag" ;;
  esac
done <<<"$units"
exit "$rc"
