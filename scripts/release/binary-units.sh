#!/usr/bin/env bash
# Release the executables of the units whose publish.to in release-policy.json is binary (blueprint-shared.publishing.binary-release).
# Each unit is a Go program: it is cross-compiled for every platform the policy lists, packed, and released with its checksum file
# to the public release repository, and at a GA version the Homebrew formula in that repository is updated.
#
#   build       CGO_ENABLED=0 go build -trimpath -buildvcs=false for each <os>/<arch> of publish.platforms, in the unit directory.
#               -buildvcs=false keeps the commit and its time out of the executable, so one source gives the same bytes at any commit
#   archive     <command>-<version>-<os>-<arch>.tar.gz, with the executable <command> and, for each name of publish.links, a symbolic
#               link of that name to <command>. The archive is the same bytes for the same executable (fixed mtime, owner and gzip
#               header), so a rerun can tell a version that changed from one that did not
#   checksum    <command>-<version>.sha256, sha256sum format: "<sha256>  <archive name>" for every archive
#   version     the unit has a version.txt and it must equal the version of .release-please-manifest.json. After the build the
#               executable of the runner platform runs with --version and must print that version
#   release     tag <ComponentName>/v<version> in the release repository (the same string as the unit tag of the source
#               repository), with the archives and the checksum file. A prerelease version is a GitHub prerelease and the formula
#               is not touched. A GA version updates Formula/<command>.rb on main with a fast-forward push, never forced
#   formula     in on_macos and on_linux, each on_arm and on_intel block holds a url and the sha256 of the archive; a comment lists
#               the platforms. Only darwin and linux on amd64 and arm64 can be in a formula; any other platform is released but left out.
#               install has bin.install "<command>" and, for each name of publish.links, bin.install_symlink "<command>" => "<name>"
#
# A rerun is safe:
#   - the release exists and its checksum file is the one just built: nothing is released again
#   - the release exists with another checksum file: refuse, because a published version must not move
#   - the release exists without a checksum file (an upload that did not finish): refuse, a person decides
#   - a GA formula that already says this version is left alone, and one that says a higher version is not changed
#
# usage: binary-units.sh [--dry-run] <path>...      units whose publish.to is not binary are skipped
#   --dry-run                  print the release (tag, archives, formula) and write nothing: nothing is built, released or pushed
#   BINARY_RELEASE_REPOSITORY  the name of the release repository without the owner (binaryReleaseRepository of the organization values)
#   BINARY_RELEASE_OWNER       owner of that repository (default: the owner of GITHUB_REPOSITORY)
#   BINARY_RELEASE_REMOTE      full remote URL or path of the release repository for git (tests use a local bare repository)
#   BINARY_RELEASE_TOKEN       GitHub App token with contents: write on the release repository only; sent as an HTTP header that git reads
#                              from its environment (GIT_CONFIG_*), never in a URL or in an argument (default for gh: GH_TOKEN)
#   BINARY_OUT                 where the archives are built (default tmp/binary)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

dry=0
if [[ "${1:-}" == --dry-run ]]; then dry=1; shift; fi
[[ $# -ge 1 ]] || die "usage: binary-units.sh [--dry-run] <path>..."

unit_tag() { printf '%s/v%s\n' "$(unit_component "$1")" "$2"; } # the unit tag, <ComponentName>/v<version>

# version_gt <a> <b> → success when version a is above b (X.Y.Z or X.Y.Z-<alpha|beta|rc>.N)
version_gt() {
  local a="$1" b="$2" sa="${1%%-*}" sb="${2%%-*}"
  [[ "$a" != "$b" ]] || return 1
  if [[ "$sa" != "$sb" ]]; then
    [[ "$(printf '%s\n%s\n' "$sa" "$sb" | sort -V | tail -1)" == "$sa" ]]
    return
  fi
  [[ "$a" != "$sa" ]] || return 0 # a is the release, b a pre-release of it
  [[ "$b" != "$sb" ]] || return 1
  [[ "$(printf '%s\n%s\n' "${a#*-}" "${b#*-}" | sort -V | tail -1)" == "${a#*-}" ]]
}

release_token() { printf '%s\n' "${BINARY_RELEASE_TOKEN:-${GH_TOKEN:-}}"; }

# gh against the release repository, with its token
ghr() { GH_TOKEN="$(release_token)" gh "$@"; }
ghr_read() { GH_TOKEN="$(release_token)" read_retry gh "$@"; }

# git against the release repository. The token goes to git as an HTTP header set in the environment of that one call (GIT_CONFIG_*),
# so it is in no argument and no process list shows it
with_git_auth() { # with_git_auth <command>...
  local t n="${GIT_CONFIG_COUNT:-0}"; t="$(release_token)"
  if [[ -z "$t" ]]; then "$@"; return; fi
  env "GIT_CONFIG_COUNT=$((n + 1))" "GIT_CONFIG_KEY_${n}=http.https://github.com/.extraheader" \
    "GIT_CONFIG_VALUE_${n}=Authorization: Basic $(printf 'x-access-token:%s' "$t" | base64 | tr -d '\n')" "$@"
}
rgit() { with_git_auth git "$@"; }
rgit_push() { # a push that is asked again after a transient error of GitHub, never forced
  with_git_auth node "$RETRY_MJS" push -- git push "$@"
}

release_repo() { # → owner/name of the release repository
  local owner="${BINARY_RELEASE_OWNER:-${GITHUB_REPOSITORY:-}}"
  owner="${owner%%/*}"
  [[ -n "${BINARY_RELEASE_REPOSITORY:-}" ]] || die "組織值 binaryReleaseRepository 沒有填，不知道執行檔要發到哪個倉；有 binary 單元的倉要填它"
  [[ "$BINARY_RELEASE_REPOSITORY" =~ ^[A-Za-z0-9._-]+$ ]] || die "binaryReleaseRepository「${BINARY_RELEASE_REPOSITORY}」只能是倉庫名，不含 owner"
  [[ -n "$owner" ]] || die "不知道發布倉的 owner，請設 GITHUB_REPOSITORY（owner/repo）或 BINARY_RELEASE_OWNER"
  printf '%s/%s\n' "$owner" "$BINARY_RELEASE_REPOSITORY"
}

release_remote() { # → the remote git uses for the release repository
  if [[ -n "${BINARY_RELEASE_REMOTE:-}" ]]; then printf '%s\n' "$BINARY_RELEASE_REMOTE"
  else printf 'https://github.com/%s.git\n' "$(release_repo)"; fi
}

sha256_of() { # sha256_of <file> → the hex digest
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# pack_archive <executable> <command> <archive> [<link>...]: a tar.gz of the executable and a symbolic link to it for each link name,
# the same bytes for the same executable
pack_archive() {
  python3 - "$@" <<'PY'
import gzip, io, sys, tarfile
src, name, dest, *links = sys.argv[1:]
data = open(src, "rb").read()
with open(dest, "wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime, info.uid, info.gid = len(data), 0o755, 0, 0, 0
            tar.addfile(info, io.BytesIO(data))
            for link in links:
                entry = tarfile.TarInfo(link)
                entry.type, entry.linkname, entry.mode, entry.mtime, entry.uid, entry.gid = tarfile.SYMTYPE, name, 0o777, 0, 0, 0
                tar.addfile(entry)
PY
}

# the Homebrew blocks of a platform: <os>/<arch> → "on_macos on_arm", or nothing when a formula cannot hold it
formula_slot() {
  local os arch
  case "${1%%/*}" in darwin) os=on_macos ;; linux) os=on_linux ;; *) return 1 ;; esac
  case "${1#*/}" in arm64) arch=on_arm ;; amd64) arch=on_intel ;; *) return 1 ;; esac
  printf '%s %s\n' "$os" "$arch"
}

# formula_text <command> <description> <version> <tag> <repo> <checksum file> <links> <platform>...
#   <links> is the names of publish.links separated by spaces, empty when the unit has none
formula_text() {
  local cmd="$1" desc="$2" ver="$3" tag="$4" repo="$5" sums="$6" links="$7" cls="" part pl slot os arch name sha link listed=()
  shift 7
  for part in $(printf '%s' "$cmd" | tr '._-' '   '); do cls+="$(tr '[:lower:]' '[:upper:]' <<<"${part:0:1}")${part:1}"; done
  for pl in "$@"; do formula_slot "$pl" >/dev/null && listed+=("$pl"); done
  (( ${#listed[@]} )) || die "${cmd}：平台 $* 裡沒有 formula 放得下的（darwin 或 linux，amd64 或 arm64）"
  printf '# Supported platforms: %s\n' "$(IFS=,; printf '%s' "${listed[*]}" | sed 's/,/, /g')"
  printf 'class %s < Formula\n  desc "%s"\n  homepage "https://github.com/%s"\n  version "%s"\n' "$cls" "${desc//\"/\\\"}" "$repo" "$ver"
  for os in on_macos on_linux; do
    local opened=0
    for arch in on_arm on_intel; do
      for pl in "${listed[@]}"; do
        slot="$(formula_slot "$pl")"
        [[ "$slot" == "$os $arch" ]] || continue
        (( opened )) || { printf '\n  %s do\n' "$os"; opened=1; }
        name="${cmd}-${ver}-${pl%%/*}-${pl#*/}.tar.gz"
        sha="$(awk -v n="$name" '$2 == n { print $1 }' "$sums")"
        [[ -n "$sha" ]] || die "$sums 沒有 $name 的一行"
        printf '    %s do\n      url "https://github.com/%s/releases/download/%s/%s"\n      sha256 "%s"\n    end\n' "$arch" "$repo" "$tag" "$name" "$sha"
      done
    done
    (( ! opened )) || printf '  end\n'
  done
  printf '\n  def install\n    bin.install "%s"\n' "$cmd"
  for link in $links; do printf '    bin.install_symlink "%s" => "%s"\n' "$cmd" "$link"; done
  printf '  end\n\n  test do\n    assert_match version.to_s, shell_output("#{bin}/%s --version")\n  end\nend\n' "$cmd"
}

summary() { [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || printf '%s\n' "- $*" >> "$GITHUB_STEP_SUMMARY"; }

# update_formula <command> <description> <version> <tag> <repo> <checksum file> <source tag> <links> <platform>...
update_formula() {
  local cmd="$1" desc="$2" ver="$3" tag="$4" repo="$5" sums="$6" ref="$7" links="$8" remote work text have cur ad
  shift 8
  remote="$(release_remote)"
  work="$(mktemp -d "${TMPDIR:-/tmp}/formula.XXXXXX")"
  text="$(formula_text "$cmd" "$desc" "$ver" "$tag" "$repo" "$sums" "$links" "$@")"
  [[ -n "$(rgit ls-remote "$remote" refs/heads/main | cut -f1)" ]] || { rm -rf "$work"; die "發布倉 ${repo} 沒有 main，formula 沒有地方推；先建好有 main 的發布倉"; }
  rgit clone -q --no-tags --branch main "$remote" "$work"
  if [[ -f "$work/Formula/$cmd.rb" ]]; then
    cur="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$work/Formula/$cmd.rb" | head -1)"
    if [[ -n "$cur" ]] && version_gt "$cur" "$ver"; then
      info "formula $cmd 已是更高的版本 ${cur}，不改成 $ver"; rm -rf "$work"; return 0
    fi
    have="$(cat "$work/Formula/$cmd.rb")"
    if [[ "$have" == "$text" ]]; then info "formula $cmd 已是 ${ver}，沒有要推的"; rm -rf "$work"; return 0; fi
  fi
  mkdir -p "$work/Formula"
  printf '%s\n' "$text" > "$work/Formula/$cmd.rb"
  # the commit is made by the bot, not by the author of the source repository: that one may be private and its address would be public here
  ad="$(git log -1 --format='%aI' "$ref")"
  local bot_name="github-actions[bot]" bot_email="41898283+github-actions[bot]@users.noreply.github.com"
  GIT_AUTHOR_NAME="$bot_name" GIT_AUTHOR_EMAIL="$bot_email" GIT_AUTHOR_DATE="$ad" GIT_COMMITTER_NAME="$bot_name" GIT_COMMITTER_EMAIL="$bot_email" GIT_COMMITTER_DATE="$ad" \
    git -C "$work" add "Formula/$cmd.rb"
  GIT_AUTHOR_NAME="$bot_name" GIT_AUTHOR_EMAIL="$bot_email" GIT_AUTHOR_DATE="$ad" GIT_COMMITTER_NAME="$bot_name" GIT_COMMITTER_EMAIL="$bot_email" GIT_COMMITTER_DATE="$ad" \
    git -C "$work" commit -q --no-gpg-sign -m "$cmd $ver" -m "Source: $ref"
  # a fast-forward only: a push that is not one is refused by the remote, and the script stops with its error
  ( cd "$work" && rgit_push origin HEAD:refs/heads/main )
  rm -rf "$work"
  log "formula $cmd → $ver 已推到 ${repo} 的 main"
  summary "formula \`$cmd\` → \`$ver\`（${repo}）"
}

binary_unit() { # binary_unit <path>
  local p="${1%/}" comp ver stage cmd desc tag repo ref work out sums host plat os arch bin archive pre=0 title sum_have
  local -a platforms=() archives=() links=()
  comp="$(unit_component "$p")"
  if [[ "$(policy_unit_publish_to "$comp")" != binary ]]; then info "$p: publish.to is not binary, skipped"; return 0; fi
  [[ -f "$p/go.mod" ]] || die "${p}：publish.to 是 binary，但單元沒有 go.mod；這一版的執行檔發布只支援 Go"
  jq -e --arg p "$p" '.packages | has($p)' "$CONFIG" >/dev/null || die "unexpected package path: $p (not a key of packages in $CONFIG)"
  ver="$(manifest_version "$p")"
  [[ -n "$ver" ]] || die "$p 不在 $MANIFEST"
  stage="$(version_stage "$ver")" || die "$p: version \"$ver\" is not X.Y.Z or X.Y.Z-<alpha|beta|rc>.N"
  [[ "$stage" == ga ]] || pre=1
  cmd="$(policy_unit_publish_field "$comp" command)"
  desc="$(policy_unit_publish_field "$comp" description)"
  mapfile -t platforms < <(policy_unit_publish_field "$comp" platforms)
  [[ -n "$cmd" && -n "$desc" ]] || die "${p}：政策檔的 units.${comp}.publish 要寫 command 與 description"
  (( ${#platforms[@]} )) || die "${p}：政策檔的 units.${comp}.publish 要寫 platforms"
  for plat in "${platforms[@]}"; do [[ "$plat" =~ ^[a-z0-9]+/[a-z0-9]+$ ]] || die "${p}：平台「${plat}」不是 <os>/<arch>"; done
  mapfile -t links < <(policy_unit_publish_field "$comp" links)
  local link seen=" "
  for link in ${links[@]+"${links[@]}"}; do
    [[ "$link" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "${p}：連結名「${link}」只能用小寫英數與 . _ -，開頭是英數"
    [[ "$link" != "$cmd" ]] || die "${p}：連結名「${link}」和 command 相同，連結要是另一個名字"
    [[ "$seen" != *" $link "* ]] || die "${p}：連結名「${link}」寫了兩次"
    seen+="$link "
  done
  [[ -f "$p/version.txt" ]] || die "${p}：執行檔的單元要有 version.txt，放它的版號"
  [[ "$(tr -d '[:space:]' < "$p/version.txt")" == "$ver" ]] \
    || die "${p}：manifest 是 ${ver}，但 $p/version.txt 是 $(tr -d '[:space:]' < "$p/version.txt")；release-please 沒有更新到這個檔"
  tag="$(unit_tag "$p" "$ver")"
  repo="$(release_repo)"

  if (( dry )); then
    echo "## $comp  ($p $ver)"
    echo "release repo  $repo"
    echo "release tag   $tag$( (( pre )) && echo ' (prerelease)')"
    for plat in "${platforms[@]}"; do echo "archive       ${cmd}-${ver}-${plat%%/*}-${plat#*/}.tar.gz"; done
    for link in ${links[@]+"${links[@]}"}; do echo "link          $link -> $cmd"; done
    echo "checksum      ${cmd}-${ver}.sha256"
    if (( pre )); then echo "formula       not changed (prerelease)"; else echo "formula       Formula/${cmd}.rb"; fi
    echo "dry run: nothing built, released or pushed"
    return 0
  fi

  ref="$tag"
  git rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null 2>&1 || die "release tag $ref does not exist, so $p $ver has not been released"
  command -v go >/dev/null 2>&1 || die "找不到 go：binary job 要先用 actions/setup-go 裝 go.mod 指定的版本"
  work="${BINARY_OUT:-$REPO_ROOT/tmp/binary}/${comp}-${ver}"
  out="$work/out"
  rm -rf "$work"; mkdir -p "$out"
  host="$(go env GOHOSTOS)/$(go env GOHOSTARCH)"

  for plat in "${platforms[@]}"; do
    os="${plat%%/*}" arch="${plat#*/}"
    mkdir -p "$work/bin/$os-$arch"
    log "build：$cmd $ver for $plat"
    ( cd "$p" && CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath -buildvcs=false -o "$work/bin/$os-$arch/$cmd" . )
    archive="${cmd}-${ver}-${os}-${arch}.tar.gz"
    pack_archive "$work/bin/$os-$arch/$cmd" "$cmd" "$out/$archive" ${links[@]+"${links[@]}"}
    archives+=("$archive")
  done
  sums="$out/${cmd}-${ver}.sha256"
  : > "$sums"
  for archive in "${archives[@]}"; do printf '%s  %s\n' "$(sha256_of "$out/$archive")" "$archive" >> "$sums"; done

  # the executable of the runner platform must say it is this version
  if [[ ! -x "$work/bin/${host%%/*}-${host#*/}/$cmd" ]]; then
    mkdir -p "$work/bin/host"
    ( cd "$p" && CGO_ENABLED=0 GOOS="${host%%/*}" GOARCH="${host#*/}" go build -trimpath -buildvcs=false -o "$work/bin/host/$cmd" . )
    bin="$work/bin/host/$cmd"
  else
    bin="$work/bin/${host%%/*}-${host#*/}/$cmd"
  fi
  sum_have="$("$bin" --version 2>&1)" || die "$cmd --version 在 ${host} 失敗：$sum_have"
  [[ "$sum_have" == *"$ver"* ]] || die "$cmd --version 印的是「${sum_have}」，沒有版號 ${ver}：版號要從 version.txt 進到執行檔裡"

  # what the release repository has now
  local view rc=0 existing
  view="$(ghr_read release view "$tag" --repo "$repo" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    existing="$work/existing"; mkdir -p "$existing"
    ghr_read release download "$tag" --repo "$repo" --pattern "${cmd}-${ver}.sha256" --dir "$existing" >/dev/null 2>&1 || true
    [[ -s "$existing/${cmd}-${ver}.sha256" ]] || die "$repo 已有 release ${tag}，但沒有 ${cmd}-${ver}.sha256：上傳沒有做完，請使用者決定怎麼補，不要覆蓋已發布的檔"
    cmp -s "$existing/${cmd}-${ver}.sha256" "$sums" \
      || die "$repo 的 release $tag 已有 ${cmd}-${ver}.sha256，但內容和這次建置的不同；已發布的版本不能動，請使用者決定，改發下一個版號"
    echo "$cmd $tag is already released in $repo, nothing to release"
  else
    [[ "$view" == *"release not found"* ]] || die "查 $repo 的 release $tag 失敗：$view"
    title="$comp $ver"
    local -a flags=()
    (( ! pre )) || flags+=(--prerelease)
    log "release：$tag → ${repo}（${#archives[@]} 個壓縮檔與 checksum）"
    ghr release create "$tag" --repo "$repo" --title "$title" --notes "Source: $ref" --target main ${flags[@]+"${flags[@]}"} \
      "${archives[@]/#/$out/}" "$sums"
    summary "執行檔 \`$cmd $ver\` → \`$repo\` release \`$tag\`$( (( pre )) && echo '（prerelease）')"
  fi

  if (( pre )); then
    info "預發布版本，不更新 formula"
  else
    update_formula "$cmd" "$desc" "$ver" "$tag" "$repo" "$sums" "$ref" "${links[*]-}" "${platforms[@]}"
  fi
}

for p in "$@"; do binary_unit "$p"; done
