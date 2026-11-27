#!/usr/bin/env bash
# Tell a workflow step whether the branch it was started for is still on origin, as a line for $GITHUB_OUTPUT:
#   exists=true | exists=false
# A run can start after finalize-release.sh deleted the release branch (a push that queued behind longer runs). The
# steps that read the branch, release-please first, would then fail and leave a red run for a branch that is gone,
# so the job runs this first and skips its other steps on exists=false.
#
# ls-remote exits 2 when origin has no such ref. Any other failure (network, auth) is not "the branch is gone": it
# stops the script with that status, so a run does not skip its work because origin could not be reached.
#
# usage: branch-exists.sh
#   env: BRANCH  the branch to look for (default: GITHUB_REF_NAME)
#   git must be able to read origin. The checkout of the job keeps its token for this step.
set -euo pipefail
branch="${BRANCH:-${GITHUB_REF_NAME:?BRANCH or GITHUB_REF_NAME is required}}"
rc=0
node "$(dirname "$0")/../lib/retry.mjs" read -- git ls-remote -q --exit-code origin "refs/heads/${branch}" >/dev/null || rc=$?
if [[ "$rc" -eq 2 ]]; then
  printf '%s\n' >&2 "::warning::branch-exists: $branch 不存在於 origin（發布已收尾，分支已刪除），這次 run 的其餘步驟略過"
  printf 'exists=false\n'
elif [[ "$rc" -ne 0 ]]; then
  printf '%s\n' >&2 "branch-exists: 讀不到 origin（git ls-remote 結束碼 ${rc}）"
  exit "$rc"
else
  printf '%s\n' >&2 "branch-exists: $branch 存在於 origin"
  printf 'exists=true\n'
fi
