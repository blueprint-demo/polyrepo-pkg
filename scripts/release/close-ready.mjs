// Decides whether the close workflow (close-release.yml) may close a release line now: merge the merge-back PR, tag the product
// version and delete the branches. It only reads the facts of the PR and of its checks and prints the decision; close-ready.sh
// gathers the facts with `gh`, so this file stays testable without a network.
//
// usage: node scripts/release/close-ready.mjs --input <file|-> [--config scripts/merge/merge-config.json]
//   input  JSON { pr, checkedSha, eventHeadSha, checks, changedFiles }
//     pr             from `gh pr view --json number,state,isDraft,headRefOid,headRefName,baseRefName,isCrossRepository`, read last
//     checkedSha     the head commit of the PR when the checks were read
//     eventHeadSha   the head_sha of the workflow_run event that started the run (github.event.workflow_run.head_sha), or null when
//                    a person started it. It is the commit the finished ci or pr-message ran for. Never github.sha, which is main.
//     checks         from `gh pr checks --json name,bucket`
//     changedFiles   the paths the PR changes (for the checks with a path filter)
//   config the one auto-merge reads (scripts/merge/merge-config.json): requiredChecks and pathFiltered
// Output: one JSON line { action, reason, ... }. action is "close" (pr, sha and line are set) or "skip". A skip is the normal answer of
// most events, because ci and pr-message finish one after the other and the PR is not ready until both have: the workflow ends
// successfully and the event of the later one asks again.
// Exit status: 0 whenever a decision was made, 2 when the input or the config is unusable.
//
// Whether the PR can be merged (a conflict with main) is not decided here: finalize-release.sh --phase close looks at it right before
// it merges and stops with the message to run merge-back again.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { MERGE_BACK_HEAD, requiredCheckProblems } from "../merge/decide.mjs";

const skip = (reason, extra = {}) => ({ action: "skip", reason, ...extra });

export function decideClose({ pr, checkedSha, eventHeadSha = null, checks = [], changedFiles = [] }, config) {
  const number = pr.number;
  if (pr.state !== "OPEN") return skip(`the pull request is ${pr.state}, not OPEN: nothing to close`, { pr: number });
  if (!MERGE_BACK_HEAD.test(pr.headRefName)) return skip(`${pr.headRefName} is not a merge-back branch (release/vX.Y--to-main)`, { pr: number });
  if (pr.baseRefName !== "main") return skip(`a merge-back PR targets main, this one targets ${pr.baseRefName}`, { pr: number });
  if (pr.isCrossRepository) return skip("the pull request comes from a fork and cannot get the App token", { pr: number });
  if (pr.isDraft) return skip("the pull request is a draft", { pr: number });
  if (eventHeadSha && eventHeadSha !== pr.headRefOid) {
    return skip(`the head moved after the finished run (the run was for ${eventHeadSha}, head now ${pr.headRefOid}): the checks of the new head will start this again`, { pr: number });
  }
  if (checkedSha !== pr.headRefOid) {
    return skip(`a commit was pushed after the checks were read (checked ${checkedSha}, head now ${pr.headRefOid})`, { pr: number });
  }
  const { failed, pending, missing } = requiredCheckProblems(checks, changedFiles, config);
  if (failed.length > 0) return skip(`required check failed: ${failed.join(", ")}`, { pr: number, failed });
  if (pending.length > 0) return skip(`required check still running: ${pending.join(", ")}`, { pr: number });
  if (missing.length > 0) return skip(`required check has not run: ${missing.join(", ")}`, { pr: number });
  return {
    action: "close",
    reason: "every required check passed or was skipped, and the head is the one that was checked",
    pr: number,
    sha: pr.headRefOid,
    line: /^release\/v(\d+\.\d+)--to-main$/.exec(pr.headRefName)[1],
  };
}

const read = (p) => readFileSync(p === "-" ? 0 : p, "utf8");

function main(argv) {
  const opt = (k, d) => (argv.includes(`--${k}`) ? argv[argv.indexOf(`--${k}`) + 1] : d);
  const input = opt("input");
  if (!input) throw new Error("missing --input <file|->");
  const config = JSON.parse(read(opt("config", "scripts/merge/merge-config.json")));
  if (!Array.isArray(config.requiredChecks) || config.requiredChecks.length === 0) throw new Error("the config needs a non-empty requiredChecks");
  console.log(JSON.stringify(decideClose(JSON.parse(read(input)), config)));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    console.error(`close-ready.mjs: ${e.message}`);
    process.exit(2);
  }
}
