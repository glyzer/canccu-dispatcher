<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Merging

Part of the reference; the index is [`README.md`](README.md).

## Merge policy

**Auto** (`gh pr merge <pr> --auto <method> --match-head-commit <head>`; with a merge queue, the
queue merges) when CI is green and the latest verdict on the PR's current head is `pass`, unless the PR
is manual. `<head>` is always the full 40-character sha: a push between reading the verdict and
arming the merge makes the merge fail closed. The dispatcher never arms a merge before a `pass`
on the current head (or, for a manual PR, your accept of the classified head), and the required
`review-gate` check reads the same verdict line ([`../repo-contract.md`](../repo-contract.md)).
`<method>` comes from the repo's settings, read once per pass: none with a merge queue (the queue
sets it), else `--squash` where allowed, else `--merge`, else `--rebase`; none if the read fails
(one read per pass, however many merges).
A failed merge's `needs-you` quotes `gh`'s own error.

### A GitHub error on the merge

A merge call (`--auto`, or a direct merge) that fails with an error that looks transient (`HTTP
5xx`, `status code: 5xx`, `Bad Gateway`, `Service Unavailable`, `Gateway Timeout`, a timeout, a
connection reset, `EOF`, a TLS handshake error; any case) is tried again on the next pass, up to
`MERGE_RETRY` times (default 3; the count is `merge_tries`): the unit keeps its phase, and the log
says `#<n> PR #<pr>: GitHub error on the merge (try <k> of <MERGE_RETRY>); trying again next pass: <gh's error>`.
Any other error (checks, rules, a stale head, not mergeable) is a refusal and goes to `needs-you`
at once; so does the next transient one after `MERGE_RETRY` tries, its reason ending in
`(after <MERGE_RETRY> tries)`. A merge that goes through clears the count.

A `needs-you` at the merge step of an accepted PR (its stage `merge`) is lifted by removing the
label with no comment: if the PR is open and its head is still the accepted one, the unit goes
back to waiting for the accept (`#<n> PR #<pr>: needs-you lifted at the merge; trying the merge
again`), where the dispatcher checks your `accepted` label and the head again and merges; no new
accept is asked. A push since the accept reviews it again instead. A comment resumes the worker
as for any `needs-you`. A PR that merges without an accept keeps its `needs-you` until you act.
A queue entry still waiting for checks `NO_CHECKS_MIN` after it was queued, with no
`merge_group` run for its merge group (GitHub sometimes starts none), is dequeued and enqueued
again once per head, which starts them; the log says so. Still stuck, `MERGE_WAIT_MIN` applies.
A PR whose enqueue fails is out of the queue: `needs-you`.
A contract-first PR (on the unit's branch plus `-contract`) closes none of the unit's issues
and is classified like the unit's own PR otherwise ([`pipeline.md`](pipeline.md)). The rule
holds for a single issue as for a package: the issue's branch is `<n>-<slug>`, kept in its
state, so its contract PR is on `<n>-<slug>-contract`.

A contract PR that GitHub links as closing an issue (`closingIssuesReferences`: a closing keyword
anywhere in its body, prose too) would close the issue with only the contract done. `check_pr`
looks for that before the verdict, so it never reaches a review or an accept: the worker is
resumed once to correct the body (`body_fix`; not a fix round of `FIX_ATTEMPTS`). Still linked on
the next pass: `needs-you`. Once the links are gone the PR goes on as usual; a review that already
passed on its head is acted on without a new one (a body edit leaves the head as it is).

### A merged PR that leaves its issue open

A unit's PR that merged while one of its issues is still open (neither a contract PR nor a plan
PR) never parks the unit. An open issue the PR's `Closes` lines name is closed by GitHub a moment
later: the dispatcher waits for that (`gone_at`). One GitHub left open after `MERGE_CLOSE_MIN`
the dispatcher closes itself, with a comment; a close that fails is tried again on the next pass,
at most until `MERGE_WAIT_MIN`. An open issue the PR does not name, or a named one it could not
close by then, gets `needs-you` (and loses `in-progress` and `awaiting-accept`) with a comment, and
the unit is released as after any merge: `merged.log`, its worktree, branch and session id gone,
the closed issues advanced, a package counted as merged in its step. The issue stays out of the
queue while it has `needs-you`. Done: close it. Work left: remove `needs-you` and add `ready`, and
a new worker starts from main.

**Without auto-merge** (the repo does not allow it) the dispatcher merges directly, with
`gh pr merge <pr> <method> --match-head-commit <head>` (`--squash` if the settings cannot be
read), only while the reviewed (or accepted) head
is still the PR's head, CI is green on it and no `REVIEW_CHECKS` check still runs there. Pending
CI waits up to `MERGE_WAIT_MIN`, no checks up to `NO_CHECKS_MIN`; red CI → `needs-you`.

**Manual**: the PR waits for your accept. `canccu-classify <pr>` prints the first reason that
applies:

1. another repo than `REPO`;
2. a PR for no issue, more than one, or another issue than the one being handled (a
   package's PR: not exactly the package's issues; the health pass's: any). A PR is for the
   issues it closes and those a `Plan for #n` line names (a plan-only PR, which must not close
   its issue); with neither, the issue its branch `<n>-…` names: that finds and reviews the PR,
   but a PR that names no issue (no `Closes`, no `Plan for`) is always manual, whatever its
   branch;
3. a PR that is not ours ([`commands.md`](commands.md));
4. 3000 or more changed files (the files API lists no more);
5. a plan-tier PR (`docs/plans/issue-<n>.md` in the diff, or `Tier: plan`) before `plan-ok`;
   after `plan-ok`, a PR that does not close exactly the unit's issues (the build must close them);
6. a path the rules' `GATED_PATHS` match, or agent configuration at any depth: `.claude/`,
   `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`. A rename counts by its old path too;
7. an issue (any issue of a package) labelled `manual-accept`;
8. a package's risk class is `high`: from the plan, the PR's `Risk:` line or the reviewer,
   whichever is highest; for the health pass, a diff that touches `HIGH_RISK_PATHS`
   ([`packages.md`](packages.md));
9. the passing review has a `Maintainer accept: <reason>` line (a breaking contract, a
   destructive migration);
10. `AUTO_MERGE_UNTIL` is set and is not a real date, or today is on or after it;
11. any other `gh` error while classifying (reading the PR's files, its comments).

**Retry**: when the PR itself cannot be read, `canccu-classify` prints `retry: gh error reading
PR #<pr>`. The dispatcher logs it and classifies the passed review again at the next pass; it asks
no accept, so a GitHub blip never turns an automatic merge into a manual one.

**Your accept**: label the PR `accepted`, or run `canccu-ship <n>`. `canccu-ship` merges the way
the dispatcher's own merge does: auto-merge with the repo's merge method, pinned to the head, and
a direct merge where the repo does not allow auto-merge (a PR not managed yet: auto-merge only).
In a repo without auto-merge the accept request names only the label. Only an `accepted` label
event by `USER_LOGIN`, newer than the accept request, counts: a label left from an older head
never does. An `accepted` label on the unit's issue (any issue of a package) is taken as well,
by the same checks, and removed from the issue once it counts; a new push removes it from the
PR and from the issues (with `KEEP_ACCEPT_ON_MAIN_MERGE=1`, a push that is a clean merge of main
only keeps the PR's own label and merges: [`config.md`](config.md)). Everything except reviews and pings is authored as you, so the dispatcher never
requests a review from you and never relies on approvals.

### A PR that conflicts with main

A PR that waits for your accept, or sits in auto-merge or a direct merge, and that GitHub marks as
conflicting with main (`mergeStateStatus` `DIRTY`) gets main merged into its branch by script, in
the unit's worktree, without an AI run (auto-merge is disabled first). It is tried once per head,
so a merge that leaves the PR still conflicting never loops. The push is a new head: a merge of
main only needs no new review ([`reviews.md`](reviews.md)). Where git cannot merge it, the worker
gets one merge run (not a fix round of `FIX_ATTEMPTS`) with the conflicting paths; a run that
pushed nothing (its PR is still the passed head when the run ends: no second review), or a merge by script that could not run (no worktree, uncommitted changes, a
failed push), is `needs-you`. A PR only behind main (`BEHIND`) is left to the merge queue.

## Guards

- Merge only with `--match-head-commit <full sha>`; never `--delete-branch`. With auto-merge,
  always `--auto` (a merge queue rejects the rest).
- Never touch rulesets, secrets, variables or collaborators.
- Never review, merge or comment on a PR that is not ours.
- "No checks reported" is never green.
- On any error while classifying: manual, but for a failed read of the PR itself: again next
  pass.
- A PR that waits for your accept is never left armed: an auto-merge someone else enabled is
  disabled.
- The reviewer token is used only by the dispatcher's own `gh` calls ([`../security.md`](../security.md)).
- Every `gh`, `jq` and `git` call runs under `timeout`; the dispatcher never kills a process or
  tmux window it did not create ([`engine.md`](engine.md)).
