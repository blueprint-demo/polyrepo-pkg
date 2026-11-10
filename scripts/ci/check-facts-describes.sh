#!/usr/bin/env bash
# The shape of `describes` in every component package: the source says `describes: describesOf(...)` or
# `describes: {}`, and the built dist/<entry>/index.json holds {"<component>": <version>} or {}. A literal object in
# index.ts is the error this catches, because a version written by hand falls behind the version actually released.
# The version itself is not compared: describesOf reads it from the version file in the directory of the unit
# the component describes, so the file is the source and a second copy here would only restate it. A unit that has
# not released yet gives {}, which passes. Neither release-please's manifest nor its config is read; that the
# directory an index.ts names is the path of the unit in the config is checked on the release side
# (scripts/ci/check-release-policy.sh).
#
# A component package is a package an aggregate lists (facts/fact-kit.config.json, or the one of another
# aggregate package under facts/), or a single-layer package published on its own (facts_components); its
# component is the directory name under facts/, or the name of the shared aggregate directory for the packages
# of another aggregate. A package may have several
# entries, one dist/<entry>/index.json each, and the entry name need not equal the component; every entry is
# checked, with its source at <package>/facts/<entry>/index.ts. A package with no dist/*/index.json at all fails,
# and so does an entry with no index.ts. A spec package describes no unit, so its index.ts says `describes: {}`
# and it passes. Builds the packages first.
#
# usage: check-facts-describes.sh
# Exit status: 0 every entry has the shape, 1 at least one does not (component, entry and the offending line are printed).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
cd "$REPO_ROOT"
has_facts || { info "⊘ 沒有 facts/，略過 describes 檢查"; exit 0; }

comps="$(facts_components)"   # builds the packages the aggregates list

failed=0 count=0
while IFS=$'\t' read -r dir comp; do
  [[ -n "$dir" ]] || continue
  entries=0
  for idx in "$dir"/dist/*/index.json; do
    [[ -f "$idx" ]] || continue
    entry="${idx%/index.json}"; entry="${entry##*/}"
    entries=$((entries + 1))
    count=$((count + 1))
    src="$dir/facts/${entry}/index.ts"
    if [[ ! -f "$src" ]]; then
      failed=$((failed + 1))
      warn "找不到 ${src#"$REPO_ROOT"/}（component=${comp} entry=${entry}）"
      continue
    fi
    # the value of the `describes:` property: a describesOf( call or {}
    line="$(grep -E '^[[:space:]]*describes:' "$src" | head -n 1 || true)"
    if [[ -z "$line" ]]; then
      failed=$((failed + 1))
      warn "index.ts 沒有 describes：component=${comp} entry=${entry}（${src#"$REPO_ROOT"/}）"
    elif ! grep -qE '^[[:space:]]*describes:[[:space:]]*(describesOf\(|\{\}[[:space:]]*,?[[:space:]]*(//.*)?$)' <<<"$line"; then
      failed=$((failed + 1))
      warn "describes 要寫 describesOf(...) 或 {}，不寫字面版號：component=${comp} entry=${entry}（${src#"$REPO_ROOT"/}）：${line#"${line%%[![:space:]]*}"}"
    fi
    # the built keys: the component, or nothing
    if ! jq -e --arg c "${comp}" '(.describes // {}) | (keys == []) or (keys == [$c])' "$idx" >/dev/null; then
      failed=$((failed + 1))
      warn "dist 的 describes 鍵不是 component 名 ${comp}，也不是 {}：entry=${entry} describes=$(jq -c '.describes // {}' "$idx")"
    fi
  done
  (( entries > 0 )) || die "找不到 ${dir#"$REPO_ROOT"/}/dist/*/index.json（建置沒有產出任何 index.json）"
done <<<"$comps"

(( failed == 0 )) || die "${failed} 項 describes 寫法不對（共 ${count} 個 entry）：index.ts 要用 describesOf('<component>', '<單元目錄>')，沒有被描述的單元寫 {}"
info "全部 ${count} 個 entry 的 describes 寫法正確（describesOf 或 {}，鍵是 component 名）"
