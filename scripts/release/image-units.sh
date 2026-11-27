#!/usr/bin/env bash
# Push the container images of the units whose publish.to in release-policy.json is image (blueprint-shared.publishing.container-image)
# and attach each digest to the Release of the unit tag in this repository.
#
#   image       ghcr.io/<owner>/<ComponentName>:<version>, one tag per version and never latest. A prerelease version is pushed too,
#               with its full version as the tag (1.2.0-rc.1)
#   build       docker buildx build with the Dockerfile in the unit directory (the build context), for every <os>/<arch> of
#               publish.platforms, in one command. The Dockerfile compiles on the build platform (FROM --platform=$BUILDPLATFORM)
#               and does not run under emulation
#   digest      <ComponentName>-<version>.digest, one line "sha256:...", an asset of the Release of the unit tag
#               (<ComponentName>/v<version>) in this repository. The digest is also written to the job summary
#   login       docker login ghcr.io with the token of the job (GITHUB_TOKEN, packages: write). DOCKER_CONFIG is a new directory
#               in the temporary directory, and it is deleted when the script ends, whatever the exit status. Its config.json lists
#               the cli-plugins directory of the original DOCKER_CONFIG (cliPluginsExtraDirs), so the buildx plugin is still found
#   builder     docker buildx create --driver docker-container, named publish-<pid>, used for the build and removed when the script
#               ends, whatever the exit status. A runner needs docker and the buildx plugin (selfHostedRunnerLabels.docker)
#   config      the image carries no configuration of the organization: it is mounted at deployment
#
# A rerun is safe:
#   - the image exists: nothing is built or pushed, and its digest is attached to the Release when the Release has none
#   - the image exists and the digest on the Release is another one: refuse, because a published version must not move
#   - only an answer of the registry that says the image is not there (not found, MANIFEST_UNKNOWN) counts as "no image"; any other
#     error of the inspect stops the run and is printed
#   - the image does not exist but the Release already has a digest: refuse, a person decides
#
# A package is private after its first push. A person makes it public once in GitHub, and that cannot be undone.
#
# usage: image-units.sh [--dry-run] <path>...       units whose publish.to is not image are skipped
#   --dry-run          print the image and the digest file and run nothing: no login, no build, no push
#   IMAGE_OWNER        owner of the image (default: the owner of GITHUB_REPOSITORY, in lower case, as ghcr.io requires)
#   IMAGE_REGISTRY     the registry host (default ghcr.io)
#   IMAGE_TOKEN        the token docker logs in with (default: GITHUB_TOKEN, then GH_TOKEN)
#   IMAGE_ACTOR        the user name of the login (default: GITHUB_ACTOR, then x-access-token)
#   GH_TOKEN           the token gh reads and writes the Release of this repository with (contents: write)
#   GITHUB_REPOSITORY  owner/repo of this repository, the one that has the Release
#   IMAGE_OUT          where the digest file and the build metadata are written (default tmp/image)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
cd "$REPO_ROOT"

dry=0
if [[ "${1:-}" == --dry-run ]]; then dry=1; shift; fi
[[ $# -ge 1 ]] || die "usage: image-units.sh [--dry-run] <path>..."

unit_tag() { printf '%s/v%s\n' "$(unit_component "$1")" "$2"; } # the unit tag, <ComponentName>/v<version>

summary() { [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || printf '%s\n' "- $*" >> "$GITHUB_STEP_SUMMARY"; }

registry() { printf '%s\n' "${IMAGE_REGISTRY:-ghcr.io}"; }

image_owner() {
  local owner="${IMAGE_OWNER:-${GITHUB_REPOSITORY:-}}"
  owner="${owner%%/*}"
  [[ -n "$owner" ]] || die "不知道映像的 owner，請設 GITHUB_REPOSITORY（owner/repo）或 IMAGE_OWNER"
  printf '%s\n' "$owner" | tr '[:upper:]' '[:lower:]'
}

# the DOCKER_CONFIG of this run: a directory of its own that holds the credential of the login, deleted when the script ends
docker_cfg=""
builder=""
cleanup() {
  local rc=$?
  # the builder is removed with the DOCKER_CONFIG it was made in; a failure here does not change the exit status
  [[ -z "$builder" ]] || docker buildx rm "$builder" >/dev/null 2>&1 || true
  [[ -z "$docker_cfg" ]] || rm -rf "$docker_cfg"
  return "$rc"
}
trap 'cleanup; report_skipped_external' EXIT

docker_login() {
  [[ -z "$docker_cfg" ]] || return 0 # one login for the whole run
  local token="${IMAGE_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
  [[ -n "$token" ]] || die "沒有可以登入 $(registry) 的 token：job 的 GITHUB_TOKEN 要帶 packages: write，並設成 IMAGE_TOKEN 或 GITHUB_TOKEN"
  local plugins="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
  docker_cfg="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/docker-config.XXXXXX")"
  # the new directory has no plugins of its own, so it points at the ones of the runner
  if [[ -d "$plugins" ]]; then jq -n --arg d "$plugins" '{cliPluginsExtraDirs: [$d]}' > "$docker_cfg/config.json"; fi
  export DOCKER_CONFIG="$docker_cfg"
  printf '%s' "$token" | docker login "$(registry)" -u "${IMAGE_ACTOR:-${GITHUB_ACTOR:-x-access-token}}" --password-stdin >/dev/null
}

# the digest of an image that is in the registry, or nothing when it is not there
# Only an answer that says the image is not there is "nothing"; any other error (network, auth, daemon) stops the run
image_digest() { # image_digest <ref>
  local out rc=0
  out="$(docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>&1)" || rc=$?
  if (( rc == 0 )); then printf '%s\n' "$out"; return 0; fi
  shopt -s nocasematch
  # A package that was never pushed answers NAME_UNKNOWN ("name unknown"), a missing tag answers MANIFEST_UNKNOWN or "not found"
  if [[ "$out" == *"not found"* || "$out" == *MANIFEST_UNKNOWN* || "$out" == *NAME_UNKNOWN* || "$out" == *"name unknown"* ]]; then shopt -u nocasematch; return 0; fi
  shopt -u nocasematch
  die "查 $1 在 $(registry) 的狀態失敗，不當成映像不存在：$out"
}

image_unit() { # image_unit <path>
  local p="${1%/}" comp ver ref tag repo out file="" platforms_csv have attached view rc=0 existing digest
  local -a platforms=()
  comp="$(unit_component "$p")"
  if [[ "$(policy_unit_publish_to "$comp")" != image ]]; then info "$p: publish.to is not image, skipped"; return 0; fi
  [[ -f "$p/Dockerfile" ]] || die "${p}：publish.to 是 image，但單元目錄沒有 Dockerfile"
  jq -e --arg p "$p" '.packages | has($p)' "$CONFIG" >/dev/null || die "unexpected package path: $p (not a key of packages in $CONFIG)"
  ver="$(manifest_version "$p")"
  [[ -n "$ver" ]] || die "$p 不在 $MANIFEST"
  version_stage "$ver" >/dev/null || die "$p: version \"$ver\" is not X.Y.Z or X.Y.Z-<alpha|beta|rc>.N"
  mapfile -t platforms < <(policy_unit_publish_field "$comp" platforms)
  (( ${#platforms[@]} )) || die "${p}：政策檔的 units.${comp}.publish 要寫 platforms"
  for have in "${platforms[@]}"; do [[ "$have" =~ ^[a-z0-9]+/[a-z0-9]+$ ]] || die "${p}：平台「${have}」不是 <os>/<arch>"; done
  platforms_csv="$(IFS=,; printf '%s' "${platforms[*]}")"
  ref="$(registry)/$(image_owner)/${comp}:${ver}"
  tag="$(unit_tag "$p" "$ver")"
  file="${comp}-${ver}.digest"
  repo="${GITHUB_REPOSITORY:-}"

  if (( dry )); then
    echo "## $comp  ($p $ver)"
    echo "image         $ref"
    echo "platforms     $platforms_csv"
    echo "digest file   $file (asset of the Release $tag${repo:+ in $repo})"
    echo "dry run: nothing built or pushed"
    return 0
  fi

  [[ -n "$repo" ]] || die "不知道要把 digest 附到哪個倉的 Release，請設 GITHUB_REPOSITORY（owner/repo）"
  git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null 2>&1 || die "release tag $tag does not exist, so $p $ver has not been released"
  command -v docker >/dev/null 2>&1 || die "找不到 docker：image job 要跑在組織值 selfHostedRunnerLabels.docker 指定的 runner 上；組織沒有給這個值，就沒有能建映像的 runner"
  docker version >/dev/null 2>&1 || die "docker 連不上 daemon：image job 要跑在有 docker 的 runner 上（組織值 selfHostedRunnerLabels.docker）"
  docker buildx version >/dev/null 2>&1 || die "docker 沒有 buildx 外掛：image job 要跑在裝了 docker buildx 的 runner 上（組織值 selfHostedRunnerLabels.docker）"
  out="${IMAGE_OUT:-$REPO_ROOT/tmp/image}/${comp}-${ver}"
  rm -rf "$out"; mkdir -p "$out"

  # the Release of the unit tag must be there: release-please creates it with the tag
  view="$(read_retry gh release view "$tag" --repo "$repo" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    [[ "$view" == *"release not found"* ]] && die "$repo 沒有 $tag 的 Release，digest 沒有地方附；release-please 發版時會建它"
    die "查 $repo 的 Release $tag 失敗：$view"
  fi
  attached=""
  existing="$out/existing"; mkdir -p "$existing"
  read_retry gh release download "$tag" --repo "$repo" --pattern "$file" --dir "$existing" >/dev/null 2>&1 || true
  [[ ! -s "$existing/$file" ]] || attached="$(tr -d '[:space:]' < "$existing/$file")"

  docker_login
  digest="$(image_digest "$ref")"
  if [[ -n "$digest" ]]; then
    if [[ -n "$attached" && "$attached" != "$digest" ]]; then
      die "$ref 已在 $(registry)，digest 是 ${digest}，但 Release $tag 附的 $file 是 ${attached}；已發布的版本不能動，請使用者決定，改發下一個版號"
    fi
    echo "$ref is already pushed ($digest), not built again"
  else
    [[ -z "$attached" ]] || die "$ref 不在 $(registry)，但 Release $tag 已附 ${file}（${attached}）；請使用者決定怎麼處理，不要推出另一個 digest"
    log "build and push：${ref}（${platforms_csv}）"
    local -a labels=(--label "org.opencontainers.image.version=$ver")
    labels+=(--label "org.opencontainers.image.source=https://github.com/$repo")
    if [[ -z "$builder" ]]; then
      docker buildx create --name "publish-$$" --driver docker-container --use >/dev/null
      builder="publish-$$"
    fi
    docker buildx build --platform "$platforms_csv" --file "$p/Dockerfile" --tag "$ref" "${labels[@]}" --metadata-file "$out/metadata.json" --push "$p"
    digest="$(jq -r '."containerimage.digest" // empty' "$out/metadata.json")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "建置沒有回報 $ref 的 digest（${digest:-空}）"
  fi

  printf '%s\n' "$digest" > "$out/$file"
  if [[ -z "$attached" ]]; then
    gh release upload "$tag" "$out/$file" --repo "$repo"
    log "digest $digest 已附到 $repo 的 Release $tag"
  fi
  summary "映像 \`$ref\`，digest \`$digest\`（附在 Release \`$tag\`）"
}

for p in "$@"; do image_unit "$p"; done
