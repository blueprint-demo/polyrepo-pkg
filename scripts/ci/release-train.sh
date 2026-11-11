#!/usr/bin/env bash
# The versions the open Release PR of a release branch is about to release, as a line for $GITHUB_ENV:
#   FACT_KIT_TRAIN=--train <component>=<version> --train <component>=<version> ...
# On a release branch the facts are pinned to those versions before the Release PR merges (by the release-please
# job once it has written the Release PR, and by merge-release-pr.sh as the fallback), while `describes`
# still reads the old version from .release-please-manifest.json. `fact-kit check --train` lets since be as new as
# the train. Prints nothing when the branch has no Release PR. That includes a branch that no longer exists on origin:
# a CI run can start after the release was finalized and the branch deleted, so there is nothing to fetch and no Release PR.
#
# The set is release_pr_units (scripts/lib/release-pr.sh): the units whose manifest version on the Release PR's
# head differs from the release branch's, with the PR's version. Only units that have a component package in
# facts/ are kept (facts_components), because the others have no package for --train to check.
#
# usage: release-train.sh
#   env: BRANCH  the release branch, e.g. release/v1.2 (for a pull request, its base branch)
#   git must be able to fetch origin. The checkout keeps no token, so the CI step passes the read-only token to
#   git through GIT_CONFIG_* in its own environment (.github/workflows/ci.yml, job facts).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
cd "$REPO_ROOT"
branch="${BRANCH:?BRANCH is not set}"

# ls-remote exits 2 when origin has no such ref; any other failure (network, auth) stops the script.
# The branch is asked about before the fetch and again when the fetch fails: close can delete it between the two (the CI run of the
# last push to the branch is still going when the merge-back PR merges), and a branch deleted then is the same finalized release.
gone_or_stop() {
  local rc=0
  git ls-remote -q --exit-code origin "refs/heads/${branch}" >/dev/null || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    warn "release-train: $branch 已不存在於 origin（發布已收尾），沒有開著的 Release PR，不帶 --train"
    exit 0
  elif [[ "$rc" -ne 0 ]]; then
    exit "$rc"
  fi
}
gone_or_stop
if ! git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"; then
  gone_or_stop
  die "release-train: git fetch $branch 失敗，而 $branch 仍在 origin"
fi
if ! units="$(release_pr_units "$branch")" || [[ -z "$units" ]]; then
  warn "release-train: $branch 沒有開著的 Release PR（或它沒有單元的版號變動），不帶 --train"
  exit 0
fi

comps="$(facts_components | cut -f2)"
line=""
while read -r unit version; do
  [[ -n "$unit" ]] || continue
  if grep -qxF "$unit" <<<"$comps"; then
    line+="${line:+ }--train ${unit}=${version}"
  else
    warn "release-train: $unit 沒有 component 套件，不帶 --train"
  fi
done <<<"$units"
[[ -n "$line" ]] || exit 0
warn "release-train: $line"
printf 'FACT_KIT_TRAIN=%s\n' "$line"
