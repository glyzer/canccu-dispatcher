<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The pipeline: one pass

Part of the reference; the index is [`README.md`](README.md). The merge decision is in
[`merging.md`](merging.md), the reviewer, fix-check and answerer in [`reviews.md`](reviews.md).

**Worker implements → independent reviewer reviews the PR → the PR merges when the review
passes and CI is green.** A review that asks for changes gets one fix by the worker and one narrow
fix-check of that fix, then the merge or you: never a second full review, never a loop.

## One pass

Every `INTERVAL` seconds, under the project's lock:

1. **Credential and pings.** The project's token is checked ([`projects.md`](projects.md)); a
   problem stops the pass. Pings ([`pings.md`](pings.md)) go out next, paused or not. Paused:
   no new issue, package, planner or health pass starts (step 3); work in flight still gets its
   reviews, answers and resumes. Backing off from a usage limit: nothing starts and nothing
   resumes.
2. **Reap.** For each managed issue whose run has finished:
   - A worker that stopped with a question (a line starting `Question:`) → the answerer.
   - A worker that finished → phase `check`, then its PR decides:
     - no PR → `needs-you` with the worker's last message;
     - a draft PR with `docs/plans/issue-<n>.md` in its diff or a `Tier: plan` line →
       `needs-you`, "plan ready for OK"; another draft → `needs-you`;
     - CI pending → wait up to `CI_WAIT_MIN`, then `needs-you`; no check reported at all (never
       green) → wait up to `NO_CHECKS_MIN`, then `needs-you`; CI red → `needs-you` (the worker
       already had its fix rounds). Checks in `REVIEW_CHECKS` are ignored here. A `needs-you`
       that only waited on CI goes back to `check` by itself once CI is green or red;
     - CI green and no verdict for this head → the review (or, after a fix round, the
       fix-check) starts.
   - A reviewer that finished: its review file, if valid for the reviewed head, is posted as
     `REVIEWER_LOGIN`; then the verdict on the current head decides:
     - `pass` → classify: **auto** arms the merge (phase `merging`); **manual** labels
       `awaiting-accept`, comments a short summary with the reason, phase `accept`;
     - `changes` from the full review → the worker resumes once with the review (stage
       `fixing`). When it is done and CI is green, the fix-check runs on the fix diff. A worker
       that pushed nothing → `needs-you`; if no fix was needed (a finding was wrong),
       `canccu-review <pr>` reviews the unchanged head again: its pass merges, its `changes`
       returns to `needs-you`. Otherwise a comment from you resumes the worker;
     - `changes` from the fix-check → `needs-you` with the open items;
     - a push after the fix-check voids it: a new fix-check of the whole fix diff runs;
     - no counting verdict line → `needs-you`.
     A verdict counts as acted on only once the merge, the accept request or the resume
     happened, so a step that fails sees the same verdict again next pass.
   - An answerer that finished: `ANSWERED` → the worker resumes with the `Answer:` comment;
     `ESCALATE`, no marker or a failed run → `needs-you`.
   - A blocked, over-budget, stalled or crashed run → `needs-you` with the reason.
   - A usage limit in any run's output → phase `limited` and a global back-off until the reset
     the message names ([`usage.md`](usage.md)). No `needs-you`, no comment.
   - **Unblock.** Each open `blocked` issue whose blocked-by links (the dependencies API and
     `Blocked by #x` lines in the body) are all closed → `ready`. An issue labelled `blocked` with
     no link is left alone: a human set it.
3. **Start.** The fast lane first, then each current step's bookkeeping, planner or health pass,
   then its packages ([`packages.md`](packages.md)). Starts stay under `CAP` and `TOTAL_CAP`,
   counting the runs plus the managed issues about to take a slot (a review about to start, a
   usage-limit resume, an answerer, a `plan-ok` or `needs-work` resume). An issue whose CI is
   still pending holds no slot. The first runnable issue is open, `ready`, not `epic`,
   `in-progress`, `needs-you` or `awaiting-accept`, not managed yet, with every blocked-by issue
   closed, and not of the one-at-a-time kind ([`rules.md`](rules.md)) while another is open.
   Order: the leading number of the milestone's title (`1 Skeleton`, `2 Contracts`, …; a title
   without a number after the numbered ones; no milestone last), then the position in an epic's
   `Order: #a → #b` line, then the issue number. It is labelled `in-progress`, assigned to
   `USER_LOGIN`, and its worker starts in window `#<n>`.
4. **Resume.** `plan-ok` → "The user approved the plan. Execute it with the superpowers skill
   executing-plans." `needs-work` → your comments since the newest of the accept request, the
   arming of the merge and the verdict. A `needs-you` issue whose issue or PR got a new comment
   from `USER_LOGIN` → that comment. `limited` after the back-off → `continue`. A PR armed for
   merge is disarmed before its worker resumes; resuming removes `needs-you`.
5. **Accept and merging.** An `accept` PR labelled `accepted` by `USER_LOGIN` after the accept
   request, whose head is still the classified one → the merge is armed (`canccu-ship <n>` does
   the same by hand, where the repo allows auto-merge). A push after classification removes `accepted` and the PR is reviewed
   again. A push while the merge is armed disarms it and reviews again; auto-merge switched off
   by someone, or no merge within `MERGE_WAIT_MIN` → `needs-you`.
6. **After the merge.** For each managed issue whose PR merged: a line in `merged.log`; its
   worktrees, local branch, session id and question file go; `in-progress`, `awaiting-accept`
   and `needs-you` come off; the main clone is fast-forwarded. An epic whose sub-issues are all
   closed is closed (a step's epic only once its step is done). An issue closed without a merged
   PR logs "closed without a merged PR; its worktree is kept": only its question file goes; no
   `merged.log` line, and its worktree, branch and session id stay.
7. **Digest.** On the first pass at or after `DIGEST_HOUR_UTC` each day: `digest/<date>.md` and,
   with `DIGEST_ISSUE` set, one comment there: the merges of the last 24 hours, the questions the
   answerer answered (with links, so you can overrule them), PRs awaiting accept, issues that need
   you, CI on main and the running workers. None on a day with no activity. A failed post
   removes the file, so the next pass writes and posts it again.
8. **Log and snapshot.** One line per action in `dispatch.log` (also in the pane, coloured);
   the raw output of the commands goes to the file only, prefixed `  │ `. Then `status.json`
   ([`snapshot.md`](snapshot.md)), also after a pass that failed or ended early.

## Phases

`work` (worker running) → `check` (waiting for the PR and CI) → `review` (reviewer or
fix-check running) → `merging` (merge armed) or `accept` (waiting for your accept). A question:
`question` (waiting for a slot) → `answer` → `work` or `needs-you`. Waiting: `needs-you`,
`limited` (usage limit) and `stopped` (`canccu-stop`).
