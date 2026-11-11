#!/usr/bin/env bash
# Check who started a manual release workflow. The workflows that advance a stage or merge a Release PR call this before
# they run anything that writes, because a private repository on the free plan has no environment with required reviewers.
#
# usage: check-trigger-actor.sh
#   env: TRIGGERING_ACTOR  github.triggering_actor of the run. It is the account that started this run attempt: on a re-run
#                          it is the person who re-ran, while github.actor and github.event.sender stay the person who
#                          started the first attempt. A name list read against those two would let an account outside the
#                          list re-run a run that a listed account dispatched, so never pass them here.
#        ALLOWED_ACTORS    the accounts that may start the run, separated by commas, spaces or new lines
#                          (the repository variable RELEASE_TRIGGER_ACTORS). A GitHub App appears as <slug>[bot].
#                          Empty or unset: nobody is excluded.
# Exit 0 when the account is listed or the list is empty, 1 otherwise. Logins are compared without regard to case,
# as GitHub does.
set -euo pipefail
actor="${TRIGGERING_ACTOR:-}"
allowed="${ALLOWED_ACTORS:-}"
list="$(tr ',[:space:]' '\n\n' <<<"$allowed" | sed '/^$/d' | tr '[:upper:]' '[:lower:]')"
if [[ -z "$list" ]]; then
  printf '%s\n' "→ RELEASE_TRIGGER_ACTORS 沒有設定，不限制誰可以觸發（觸發者 ${actor:-未知}）"
  exit 0
fi
if [[ -z "$actor" ]]; then
  printf '%s\n' "✗ 讀不到觸發者（TRIGGERING_ACTOR 是空的），名單有設定時不放行" >&2
  exit 1
fi
if grep -qxF -- "$(tr '[:upper:]' '[:lower:]' <<<"$actor")" <<<"$list"; then
  printf '%s\n' "→ 觸發者 ${actor} 在名單內"
  exit 0
fi
printf '%s\n' "✗ 觸發者 ${actor} 不在 RELEASE_TRIGGER_ACTORS 的名單內（$(tr '\n' ' ' <<<"$list" | sed 's/ $//')），不執行" >&2
exit 1
