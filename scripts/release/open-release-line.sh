#!/usr/bin/env bash
# Open a release train from a workflow run. open-release-line.yml runs this in the repository that holds the line.
# A member repository gets the Release Plan as a workflow input: the hub passes the product version, the content of
# the plan and this repository's units, so the member reads nothing from the hub and holds no credential for it.
# A repository that holds its own plans (a single-repository product, the hub, a repository of the organization layer)
# needs no content: the plan is committed on main under releases/ and cut-release.sh reads it from there.
#
# usage: open-release-line.sh
#   env: PLAN          the product version, vX.Y.Z
#        PLAN_CONTENT  optional. The content of releases/release-plan-vX.Y.Z.md of the hub. Required in a member repository
#                      (its policy file has product.primary), because the plan is not in this repository. When it is empty
#                      in any other repository, the plan of this repository's releases/ is used.
#        UNITS         comma list of this repository's units in the plan
#        FROM          optional, main (default) or the latest product tag of the line, passed to cut-release.sh --from.
#                      A line that already shipped takes patches only and has to be cut from its latest product tag.
#        STAGES_OVERRIDE  optional. The stages of some units for this release only, a JSON object {"<unit>":["rc","ga"]}, passed to
#                      cut-release.sh --stages-override, which checks the format and stops with the reason when it is wrong. The
#                      override goes into release-policy.json on the new release branch. It is read from the environment and never
#                      interpolated into a command.
# With content it writes it to release-plan-<PLAN>.md in a temporary directory and calls
# cut-release.sh --plan <PLAN> --plan-file <that file> --units <UNITS> --from <FROM> --yes. Without content it calls
# cut-release.sh --plan <PLAN> --units <UNITS> --from <FROM> --yes.
set -euo pipefail
plan="${PLAN:?PLAN is required (vX.Y.Z)}"
units="${UNITS:?UNITS is required (comma list of units)}"
content="${PLAN_CONTENT:-}"
[[ "$plan" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '%s\n' >&2 "✗ PLAN 需為 vX.Y.Z：$plan"; exit 1; }
declare -a extra=()
[[ -z "${STAGES_OVERRIDE:-}" ]] || extra=(--stages-override "$STAGES_OVERRIDE")
if [[ -z "$content" ]]; then
  policy="${RELEASE_POLICY:-$(git rev-parse --show-toplevel)/release-policy.json}"
  [[ -f "$policy" ]] || { printf '%s\n' >&2 "✗ 找不到政策檔 $policy"; exit 1; }
  if [[ -n "$(jq -r '.product.primary // empty' "$policy")" ]]; then
    printf '%s\n' >&2 "✗ 這是成員倉，Release Plan 在 hub，不在這個倉裡。派送時要貼 plan_content（hub 的 releases/release-plan-${plan}.md 的內容）"
    exit 1
  fi
  exec bash "$(dirname "$0")/cut-release.sh" --plan "$plan" --units "$units" --from "${FROM:-main}" "${extra[@]+"${extra[@]}"}" --yes
fi
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
printf '%s\n' "$content" > "$dir/release-plan-$plan.md"
bash "$(dirname "$0")/cut-release.sh" --plan "$plan" --plan-file "$dir/release-plan-$plan.md" --units "$units" --from "${FROM:-main}" "${extra[@]+"${extra[@]}"}" --yes
