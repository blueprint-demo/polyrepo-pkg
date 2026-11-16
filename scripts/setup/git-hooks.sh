#!/usr/bin/env bash
# Puts forwarding files for commit-msg and pre-push into the repository's common hooks directory
# ($(git rev-parse --git-common-dir)/hooks, which linked worktrees share). Each one hands its arguments and
# stdin to scripts/hooks/<name> of the working tree it runs in, which guard the local lane into main, and
# exits 0 when that file is missing or not executable. Runs from pnpm's prepare on every install, so a fresh
# clone is guarded without a separate step.
#
# The repository's core.hooksPath stays unset: a value there overrides a hooksPath the machine set globally,
# and the machine's hooks would stop running. A machine that sets a global hooksPath runs only those hooks;
# the repository's hooks run when those hand over to .git/hooks/<name>. An older version of this script set
# core.hooksPath to scripts/hooks in the shared config; that exact value is removed, any other value (or one
# in a worktree's own config) stays and is reported, since it hides the forwarding files. A file of the same
# name in the hooks directory that this script did not write (no marker on line 2) is left alone and the
# script exits non-zero. Outside a working tree (a bare repository, an unpacked tarball) it does nothing.
#
# A repository that only takes changes through PRs drops the prepare script from package.json and deletes
# .git/hooks/commit-msg and .git/hooks/pre-push.
#
# Also sets commit.cleanup scissors. Messages use "## " section headings (docs/git-flow.md, commit 與 PR
# 訊息格式); when a message is written in the editor, git's default cleanup (strip) deletes every line
# starting with "#", headings included. scissors keeps them and drops only git's help text, which it
# places below a scissors line. Messages given with -m or -F are not edited and keep "#" lines either way.
# usage: git-hooks.sh
set -euo pipefail
# A bare repository prints false with status 0, so compare the output.
[[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]] || exit 0

marker='# managed by scripts/setup/git-hooks.sh'
names="commit-msg pre-push"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
hooks="$common/hooks"

foreign=""
for name in $names; do
  file="$hooks/$name"
  if [[ -e "$file" || -L "$file" ]] && [[ "$(sed -n 2p "$file" 2>/dev/null)" != "$marker"* ]]; then
    foreign="$foreign  $file"$'\n'
  fi
done
if [[ -n "$foreign" ]]; then
  {
    printf '%s\n' "git-hooks.sh：下列檔不是這支腳本放的，沒有覆寫："
    printf '%s' "$foreign"
    printf '%s\n' "處理方式：確認它的用途，把要保留的檢查併進 scripts/hooks/ 的同名檔後刪掉它，或改由那支檔呼叫 scripts/hooks/<name>，再跑一次 pnpm install。"
  } >&2
  exit 1
fi

if [[ "$(git config --file "$common/config" --get core.hooksPath || true)" == scripts/hooks ]]; then
  git config --file "$common/config" --unset core.hooksPath
  printf '%s\n' "git-hooks.sh：移除舊版設的 core.hooksPath=scripts/hooks，改用 ${hooks} 的轉呼叫檔"
fi

mkdir -p "$hooks"
for name in $names; do
  tmp="$hooks/.$name.tmp.$$"
  cat >"$tmp" <<EOF
#!/bin/sh
$marker: hands over to scripts/hooks/<name> of the working tree
top="\$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
hook="\$top/scripts/hooks/\${0##*/}"
[ -x "\$hook" ] || exit 0
exec "\$hook" "\$@"
EOF
  chmod +x "$tmp"
  mv -f "$tmp" "$hooks/$name"
done

git config commit.cleanup scissors

found="$(git config --show-scope --get core.hooksPath || true)"
if [[ -n "$found" ]]; then
  tab=$'\t'
  scope="${found%%"$tab"*}"
  value="${found#*"$tab"}"
  case "$scope" in
    global | system)
      printf '%s\n' "這台機器的 ${scope} 設定有 core.hooksPath=${value}，git 只跑那裡的 hook。那組 hook 會轉給 .git/hooks/<name> 時，倉的 hook 才會跑。"
      ;;
    *)
      printf '%s\n' "git-hooks.sh：${scope} 設定有 core.hooksPath=${value}，git 只跑那裡的 hook，${hooks} 的轉呼叫檔不會被執行。要讓倉的 hook 跑，移除那筆設定：git config --$scope --unset core.hooksPath" >&2
      exit 0
      ;;
  esac
fi
printf '%s\n' "git hooks → ${hooks}（commit-msg、pre-push 轉給 scripts/hooks）；commit.cleanup → scissors"
