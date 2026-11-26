<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The pipeline: one pass

Part of the reference; the index is [`README.md`](README.md). The merge decision is in
[`merging.md`](merging.md), the reviewer, fix-check and answerer in [`reviews.md`](reviews.md).

**Worker implements → independent reviewer reviews the PR → the PR merges when the review
passes and CI is green.** A review that asks for changes gets one fix by the worker and one narrow
fix-check of that fix, then the merge or you: never a second full review, never a loop. Your
`needs-work` on the fix-check's open items gives one more fix round and fix-check, not a new full
review.

## One pass

Every `INTERVAL` seconds, under the project's lock:

1. **Credential and pings.** The project's token is checked ([`projects.md`](projects.md)); a
   problem stops the pass. Pings ([`pings.md`](pings.md)) go out next, paused or not. Paused
   (`canccu-pause`): no new run starts at all, no issue, package, planner, health pass, review,
   fix-check, answer or resume; running runs finish, their reaps work, and a passed review still
   merges (a merge costs no tokens). Paused with `--finish` (for a host move): no new issue,
   package, planner or health pass starts (step 3); work in flight still gets its reviews,
   answers and resumes. Backing off from a usage limit: nothing starts and nothing resumes.
   A GitHub rate limit (a failed `gh` call that says so) writes `gh_limit` with the reset (the
   primary limit's from `gh api rate_limit`, else 15 minutes): until then every pass returns at
   once, with no `gh` call, logged once when it starts and once when it ends. Free space below `DISK_MIN_MB` on the
   worktrees' file system: nothing new starts (step 3), logged once when it starts and once when
   it ends; reaping, running reviews, resumes of started work and merges go on.
2. **Reap.** For each managed issue whose run has finished:
   - A worker that finished with no PR (the PR list read again to be sure) and a status line
     starting `blocked` or `not started` → phase `waiting`, quietly: no `needs-you`, no answerer
     (even if it asked too). Its issue (a package's lead) gets `blocked`, marked as the
     dispatcher's own; the run resumes once the label goes. If the label cannot be set, the run is
     reaped again next pass.
   - Permission denials in a run's exit report are information, not a status: a finished run
     that lists denials is checked against its PR. When the PR's head is the worktree's HEAD and
     nothing is uncommitted, it is treated as finished, like any other (next item); otherwise
     (no PR, a head that differs, uncommitted files, a worktree gone) → `needs-you` with the
     denials. An older worker whose report says `blocked` with an open PR is still finished. A `needs-you` of a
     finished worker or of a red CI whose label the leader removes with no comment, its PR open,
     not a draft and green (a re-run), goes back to `check` and the review starts.
   - A worker that stopped with a question (a line starting `Question:`) → the answerer.
   - A worker that finished → phase `check`, then its PR decides (a PR for issue `n`: one that closes it, a plan-only PR with a `Plan for #n` line, or one on its branch `<n>-…`):
     - an open contract-first PR (on the unit's branch plus `-contract`, closing none of its
       issues, for a repo whose rule is "a contract change is its own PR and merges first") is
       the unit's PR until it merges: it is reviewed, classified and merged as any other.
       Once merged, the unit's own PR is back in `check`; a draft resumes the worker to merge
       main and finish;
     - no PR, but commits on its branch or uncommitted work in its worktree (its turn ended
       with background work, or before its push) → once, a fresh finish session
       with the handoff to push and open the PR (`finish_tried`); after that, or with nothing
       in the worktree → `needs-you` with the worker's last message;
     - a draft PR with `docs/plans/issue-<n>.md` in its diff or a `Tier: plan` line →
       `needs-you`, "plan ready for OK"; another draft → `needs-you`;
     - CI pending → wait up to `CI_WAIT_MIN`, then `needs-you`; no check reported (never
       green) → wait up to `NO_CHECKS_MIN`, then `needs-you`; CI red → main is merged into the
       branch by script (`git merge origin/main`, a normal push, no AI run), CI runs again,
       since another merged PR may have caused it; a merge that conflicts is aborted and a fresh
       session resolves it; still red with main in → failed or cancelled Actions jobs rerun once
       per head; still red → a fresh fix session with the failure digest of every
       failing job (`CI_DIGEST_PATTERN`, at most `CI_DIGEST_LINES` lines, each job under its
       name; a log with no failure line gives its tail), at most
       `FIX_ATTEMPTS` red-CI fix runs per PR, then `needs-you`. A job its
       time limit ended reads "timed out"; `REVIEW_CHECKS` are ignored. A `needs-you`
       that only waited on CI returns to `check` once CI is green or red;
     - CI green, no verdict, body lacking `Testing:`/`Revert:` (no contract, no `Tier: plan`)
       → worker resumed once (`body_lines`; no fix round; no back-off), then review;
     - CI green and no verdict for this head → the review (or, after a fix round, the
       fix-check) starts; it checks both lines against the diff (a false `Testing:` is a `[test]`
       finding, a false `Revert:` a `[correctness]` one).
   - A reviewer that finished: its review file, if valid for the reviewed head, is posted as
     `REVIEWER_LOGIN`; then the verdict on the current head decides:
     - `pass` → classify: **auto** arms the merge (phase `merging`); **manual** labels
       `awaiting-accept`, comments a short summary with the reason, phase `accept`;
     - `changes` from the full review → the worker resumes once with the review (stage
       `fixing`; none left of `REVIEW_FIX_ATTEMPTS`: [`review-depth.md`](review-depth.md#one-full-review-per-pr-cycle)). When it is done and CI is green, the fix-check runs on the fix diff. A worker
       that pushed nothing → `needs-you`; if no fix was needed (a finding was wrong),
       `canccu-review <pr>` reviews the unchanged head again: its pass merges, its `changes`
       returns to `needs-you`. Otherwise a comment from you resumes the worker;
     - `changes` from the fix-check → `needs-you` with the open items (saved, with that head as
       `open_sha`; a `pass` clears it before the merge or accept step). Your `needs-work` there
       is one more fix round (step 4) and a fix-check of `git diff <open_sha>..<head>` against
       those items and your comments, not a full review;
     - a push after the fix-check voids it: a new fix-check of the whole fix diff runs;
     - no counting verdict line → `needs-you`.
     A verdict counts as acted on only once the merge, accept request or resume
     happened, so a failed step sees the same verdict next pass.
   - An answerer that finished: `ANSWERED` → the worker resumes with the `Answer:` comment;
     `ESCALATE`, no marker or a failed run → `needs-you`.
   - A run that ended its turn with background work still running (`error: ended with
     background work pending`) → phase `check`, like a finished one: its PR decides, or the
     finish session above.
   - A crashed, stalled or killed run (an `error` result excepted) gets `CRASH_RETRY` fresh runs
     with its handoff, never its own session: phase `retry`, started once a slot is free. Past that → `needs-you`. A unit in `starting` whose run is gone after 60 s counts as killed.
   - A run stopped at its turn or time budget whose PR moved on → phase `continue`
     ([`usage.md`](usage.md#continuations)). A blocked, over-budget, stalled or crashed run past
     its retries → `needs-you` with the reason.
   - A usage limit in any run's output → phase `limited` and a global back-off until the reset
     the message names ([`usage.md`](usage.md)). No `needs-you`, no comment.
   - **Unblock.** Each open issue with the dispatcher's own `blocked` (a `waiting` run's) whose
     blocked-by links (the dependencies API and `Blocked by #x` lines in the body; for a package,
     every member's) are all closed → the label goes (`ready` for an issue nobody manages). A
     `blocked` set by anyone else is never removed, whatever its links say: whoever set it lifts
     it (logged once when its links are all closed). The dispatcher's mark goes with its label,
     however the label went.
3. **Start.** The fast lane first, then each current step's bookkeeping, planner or health pass,
   then its packages ([`packages.md`](packages.md)). Starts stay under `CAP` and `TOTAL_CAP`,
   counting the runs plus the managed issues about to take a slot (a review about to start, a
   usage-limit resume, an answerer, a `plan-ok` or `needs-work` resume), less the slots owed to
   projects waiting with fewer runs ([`projects.md`](projects.md#fair-share-of-total_cap)). An
   issue whose CI is still pending holds no slot, nor does a run that cannot start: its step at
   `STEP_BUDGET` (a review or fix-check of an open PR still holds one), a `plan-ok` or
   `needs-work` resume of an issue with an open blocker (or blockers `gh` could not read; a PR
   in check keeps its slot), or a review while reviews are refused. The first runnable issue is open, `ready`, not `epic`,
   `blocked`, `in-progress`, `needs-you` or `awaiting-accept`, not managed yet, with every blocked-by issue
   closed, and not of the one-at-a-time kind ([`rules.md`](rules.md)) while another is open.
   Order: the leading number of the milestone's title (`1 Skeleton`, `2 Contracts`, …; a title
   without a number after the numbered ones; no milestone last), then the position in an epic's
   `Order: #a → #b` line, then the issue number. It is labelled `in-progress`, assigned to
   `USER_LOGIN`, and its worker starts in window `#<n>`.
4. **Resume.** `plan-ok` → "The user approved the plan. Execute it with the superpowers skill
   executing-plans. Build it in this PR: replace each `Plan for #<n>` line with `Closes #<n>`…", followed by
   your comments on the issue and PR since the `needs-you` (your answers to the plan's questions;
   a `gh` error reading them keeps `plan-ok` for next pass). `needs-work` → your comments since the newest of the accept request, the
   arming of the merge and the verdict. A `needs-work` on a `needs-you` the fix-check's open
   items left (`open_sha` set, still in the fix round, not parked at `merge`) is one more fix
   round with a fix-check after it, unless a line of your comment is just `full review`; every
   other `needs-work` (a refused accept, a stopped merge) starts a new cycle: the next review is
   a full one. A `gh` error reading the comments decides nothing: `needs-work` stays for the
   next pass. `needs-work` may be put on the unit's PR too: the pass first moves it to the lead
   issue (added there, then removed from the PR; logged), then handles it as above in the same pass; a `gh` error on the move leaves it on the PR till next pass. A `needs-you` whose issue or PR got a new comment
   from `USER_LOGIN` → that comment. `limited` after the back-off, and `continue`, → a fresh session from the handoff ([`usage.md`](usage.md)). `waiting` whose
   `blocked` is gone → "check its blockers again, then do the work". An issue labelled `blocked`
   is never started or resumed, and gets no answerer. A run that finished with no PR is not
   `--resume`d: a fresh session gets the whole task (with `plan_ok`, the order to execute the
   merged plan), the question it stopped with if the message answers one, and the message. Every
   other follow-up is fresh too unless `RESUME_ON` names its kind: it gets the safety block, the
   task and the handoff, in that order ([`engine.md`](engine.md), "Follow-up runs"); a resumed
   session gets the message alone. A PR armed for
   merge is disarmed before its worker resumes; resuming removes `needs-you`.
5. **Accept and merging.** An `accept` PR labelled `accepted` by `USER_LOGIN` after the accept
   request, whose head is still the classified one → the merge is armed (`canccu-ship <n>` does
   the same by hand, where the repo allows auto-merge). A push after classification removes `accepted` and the PR is reviewed
   again. A push while the merge is armed disarms it and reviews again; auto-merge switched off
   by someone, or no merge within `MERGE_WAIT_MIN` → `needs-you`. Auto-merge off because the PR
   already merged (the merge queue's reason `merged`) is a merge, not a rejection.
   `--auto` refused for "clean status" → a direct merge at that head. Auto-merge off on an
   open PR → `mergeable` read fresh: `CONFLICTING` → the conflict path; `UNKNOWN` → the
   next pass looks again; else the queue's removal reason, or `needs-you`.
   A merged plan-only PR (`Plan for #n` or `Tier: plan`, closing none of the issues) sends the
   unit back to the queue: no longer managed, its worktree, branch (locally and on GitHub) and
   session gone, its issues
   `ready` and `plan-ok`, without `in-progress`, `needs-you` and `awaiting-accept`. The next start
   sets `plan_ok`, drops `plan-ok` and tells the worker to execute the merged plan. A PR merged
   after `plan-ok` is the build, never a plan sent back.
6. **After the merge.** For each managed issue whose PR merged: a line in `merged.log`; its
   worktrees, local branch, session id and question file go; `in-progress`, `awaiting-accept`
   and `needs-you` come off; the main clone is fast-forwarded. An epic whose sub-issues are all
   closed is closed (a step's epic only once its step is done). An issue closed without a merged
   PR logs "closed without a merged PR; its worktree is kept": only its question file goes.
7. **Digest.** On the first pass at or after `DIGEST_HOUR_UTC` each day: `digest/<date>.md` and,
   with `DIGEST_ISSUE` set, one comment there: the merges of the last 24 hours, the questions the
   answerer answered (with links, so you can overrule them), PRs awaiting accept, issues that need
   you, CI on main and the running workers. None on a day with no activity. A failed post
   removes the file, so the next pass writes and posts it again.
8. **Log and snapshot.** One line per action in `dispatch.log`;
   the raw output of the commands goes to the file only, prefixed `  │ `. Then `status.json`
   ([`snapshot.md`](snapshot.md)), also after a pass that failed or ended early.

## Phases

`starting` (engine starting; a failed start restores the old phase) → `work` (worker running) → `check` (awaiting PR and CI) → `review` (reviewer or
fix-check running) → `merging` (merge armed) or `accept` (awaiting your accept). A question:
`question` (awaiting a slot) → `answer` → `work` or `needs-you`. Waiting: `needs-you`,
`limited` (usage limit), `continue` (continuing), `retry` (a crashed run waits for a slot), `waiting` (blocked until `blocked` goes) and `stopped` (`canccu-stop`).
