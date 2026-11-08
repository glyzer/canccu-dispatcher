<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Merging

Part of the reference; the index is [`README.md`](README.md).

## Merge policy

**Auto** (`gh pr merge <pr> --auto --match-head-commit <head>`; with a merge queue, the queue
merges) when CI is green and the latest verdict on the PR's current head is `pass`, unless the PR
is manual. `<head>` is always the full 40-character sha: a push between reading the verdict and
arming the merge makes the merge fail closed. The dispatcher never arms a merge before a `pass`
on the current head (or, for a manual PR, your accept of the classified head), and the required
`review-gate` check reads the same verdict line ([`../repo-contract.md`](../repo-contract.md)).

**Without auto-merge** (the repo does not allow it) the dispatcher merges directly, with
`gh pr merge <pr> --squash --match-head-commit <head>`, only while the reviewed (or accepted) head
is still the PR's head, CI is green on it and no `REVIEW_CHECKS` check still runs there. Pending
CI waits up to `MERGE_WAIT_MIN`, no checks up to `NO_CHECKS_MIN`; red CI → `needs-you`.

**Manual**: the PR waits for your accept. `canccu-classify <pr>` prints the first reason that
applies:

1. another repo than `REPO`;
2. a PR that closes no issue, more than one, or another issue than the one being handled (a
   package's PR: not exactly the package's issues; the health pass's: any);
3. a PR that is not ours ([`commands.md`](commands.md));
4. 3000 or more changed files (the files API lists no more);
5. a plan-tier PR (`docs/plans/issue-<n>.md` in the diff, or `Tier: plan`) before `plan-ok`;
6. a path the rules' `GATED_PATHS` match, or agent configuration at any depth: `.claude/`,
   `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`. A rename counts by its old path too;
7. an issue (any issue of a package) labelled `manual-accept`;
8. a package's risk class is `high`: from the plan, the PR's `Risk:` line or the reviewer,
   whichever is highest; for the health pass, a diff that touches `HIGH_RISK_PATHS`
   ([`packages.md`](packages.md));
9. the passing review has a `Maintainer accept: <reason>` line (a breaking contract, a
   destructive migration);
10. `AUTO_MERGE_UNTIL` is set and is not a real date, or today is on or after it;
11. any `gh` error while classifying.

**Your accept**: label the PR `accepted`, or run `canccu-ship <n>`. Only an `accepted` label
event by `USER_LOGIN`, newer than the accept request, counts: a label left from an older head
never does. Everything except reviews and pings is authored as you, so the dispatcher never
requests a review from you and never relies on approvals.

## Guards

- Merge only with `--match-head-commit <full sha>`; never `--delete-branch`. With auto-merge,
  always `--auto` (a merge queue rejects the rest).
- Never touch rulesets, secrets, variables or collaborators.
- Never review, merge or comment on a PR that is not ours.
- "No checks reported" is never green.
- On any error while classifying: manual.
- A PR that waits for your accept is never left armed: an auto-merge someone else enabled is
  disabled.
- The reviewer token is used only by the dispatcher's own `gh` calls ([`../security.md`](../security.md)).
- Every `gh`, `jq` and `git` call runs under `timeout`; the dispatcher never kills a process or
  tmux window it did not create ([`engine.md`](engine.md)).
