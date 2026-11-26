<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Review depth: a head reviewed once, the light review, the count, the brake

Part of the reference; the index is [`README.md`](README.md). How much review a PR head gets:
the reviewer itself, the fix-check and the verdict line are in [`reviews.md`](reviews.md).

## A head is reviewed once

A head that passed a review (a full review, a fix-check, or a post-pass check) is never reviewed
again: the same head finds the same things and costs a whole review. When a unit comes back to
check on a head that passed (after a merge-queue removal and its `needs-you`, a `needs-work`
the worker pushed nothing for, or a fix-check's pass seen again), the dispatcher logs
`#<n> PR #<pr>: head <sha7> passed review already; no new review (verdict reused)` and acts on
the pass as if it had just been posted: it classifies the PR again, then merges it (auto) or
asks for your accept (manual). An accept still valid for that head is merged as before.

A head passed when the unit's `pass_sha` is that head, or when `reviews.log` has a `pass` line
for that PR and head (a new cycle clears `pass_sha`; the log keeps every verdict).

Explicit asks still review:

- `canccu-review <pr>` reviews the head it is given, passed or not;
- a line `full review` in your `needs-work` comment (as in [`reviews.md`](reviews.md#fix-check))
  asks for one full review of the next head, even when the worker pushed nothing. It is kept as
  the unit's `review_asked` until that review's verdict is acted on, so a run that ends with no
  verdict (the usage limit) is started again rather than the earlier pass reused.

The worker's merge run for a conflict that pushed nothing (the head is still the one it started
on) is no reuse: it goes to `needs-you`, as before.

A head's non-blocking findings go to the follow-up ticket once per review kind: a second verdict
of the same kind on the same head (an explicit re-review) files none (the full review after a
light one on that head files its own), and logs
`#<n> PR #<pr>: non-blocking findings of <sha7> are filed already; not filed again`.

## The light review

With `REVIEW_LIGHT=1` (rules, locked, the default; [`rules.md`](rules.md)) a full review (never a fix-check)
is light when the unit is a package (not the health pass or a step's deep review), its class
(the highest of the plan, the PR's `Risk:` line and earlier reviews) is `low` or `normal`, no
`full review` was asked for, and no path of the PR (a rename's old path too) is gated or agent
configuration. A single issue of the fast lane has no class: never light. The light review runs
at `low` effort (`REVIEW_EFFORT_MAX` still caps it) and logs
`PR #<pr>: light review (REVIEW_LIGHT=1, <risk> risk, low effort)`.

Its prompt (`light_review_prompt` in `lib/canccu-depth.sh`) replaces the code-review skill
and the acceptance-criteria sentence with a fixed checklist: the change is sensible; each issue
of the package is done; every new behaviour has a test and none was weakened; obvious bugs in the
changed lines; code and contracts agree; no TODO, stub, debug code or work outside the package;
and two tripwires: a secret or a private name is a blocking `security` finding, a new dependency
or risky code (`HIGH_RISK_TEXT`) makes its `Risk:` line high. The rest is the full review's: the
security-review skill when the diff touches `SECURITY_REVIEW_WHEN`, `REVIEW_EXTRA`,
`Decisions made:`, the risk and no-repeat sentences, the file and its block. `reviews.log` keeps
kind `full` for it (contracts §8 fixes the kinds).

`reviews/<pr>.light` holds the head a light review runs on. A light review that passes with a
`Risk:` line of `high` is not acted on as a pass: the class decides the depth, so the unit asks
for one full review of the same head (the one allowed second review of a head) and logs
`#<n> PR #<pr>: the light review rated it high risk; full review of <sha7>`. Until that review
can start (a free slot) the PR waits; it never merges on the light pass. The full review's own
verdict is then acted on as usual.

## The count after a merge of main

A push after a pass gets a fix-check, or a full review when it is big or touches a gated or
risky path ([`reviews.md`](reviews.md#fix-check)). The count starts at `count_from`
(`lib/canccu-depth.sh`): with main merged in since the pass, from git's own merge of the passed
head with main, so main's lines drop out. When that merge conflicts, the count starts at the
passed head today: main's lines in the PR's files count, and a big main change or a risky path
only main touched makes it a full review.

With `FIXCHECK_COUNT_RESOLVED=1` (project config, locked, the default) the count starts instead from the tree
`git merge-tree --write-tree` writes for that merge with its conflict markers (git ≥ 2.38). The
diff from it to the head holds the hand-resolved hunks and the PR's later commits; the size, gated
and risky checks see only those. The fix-check's effort (`FIXCHECK_BIG`, `FIXCHECK_RISKY`) counts
the same way with it, and as before without it. Any other git result counts as before: the cost
is a full review, never a missed one. The count after a pass, and the fix-check's with
`FIXCHECK_COUNT_RESOLVED=1`, diff with `--no-renames`: a file moved out of a gated or risky path
counts by its old path too.

## One full review per PR cycle

Two fix budgets per PR, so red CI never uses up the review's fix round: `FIX_ATTEMPTS` counts the
automatic red-CI fix runs (`fixes`), `REVIEW_FIX_ATTEMPTS` (default 1) the automatic review fix
runs (`rfixes`: a full review's `changes`, and the extra round of `FIX_EXTRA_IF_FEWER`). A
round you asked for (a comment, `needs-work`) counts in neither. `canccu-status` lists each
open PR's `fixes: ci 2/2 · review 0/1`.

A full review's `changes` with no review fix run left (and no extra round) is a `needs-you` that
keeps the round open: the blocking findings are saved as `reviews/<pr>/<head>.findings.md`,
stage `fixing` on the reviewed head, `fix_owed=1`. Your comment, or `needs-work`, resumes the
worker as that fix run (a fix kind: `FIX_MODEL`, `FIX_EFFORT`) with the findings and your
comment's items, which join the findings file; its push gets a fix-check of `<reviewed
head>..<new head>` against both, not a second full review. A full review runs only on a line
`full review` in your comment, on a refused accept, or when the PR's own files changed more than
`FIXCHECK_FULL_LINES` since the review, counted as above: lines merged from main never count, and
after a conflicting merge only the resolved ones do (with `FIXCHECK_COUNT_RESOLVED=1`).

## The review brake

Q1 relaxed the reviews (demotions, no repeats, light reviews). The brake takes that back by
itself when escaped defects rise. An escaped defect is an issue or PR, open or closed, with a
`Regression of: #<pr>` line. Bug issues carry one, and the reviewer asks for one on a fix PR.

- **The baseline.** It covers the last `BRAKE_WINDOW` PRs merged before the first `reviews.log`
  line: their escaped defects per merged PR, and their review rounds per merged PR (the
  `review-<pr>` runs of the spend log up to the merge, but those whose outcome says
  `verdict=none` or `void`: a lost or retried run posted nothing). It is written once, to `brake-baseline`.
  With fewer than 5 such PRs there is no baseline, the trigger is off, and `canccu-status` says so.
- **The trigger.** With `REVIEW_BRAKE=auto`, each pass compares the escaped defects per merged PR
  of the last `BRAKE_WINDOW` merged PRs with the baseline. Above it, the brake engages: the file
  `brake` (`<time> <trigger>`), one `ask` feed line for the product owner (kind `needs-you`), and
  the same text in `dispatch.log`: "Review brake on: <trigger>. Reviews block as before Q1 until
  you run canccu-dispatcher brake release". GitHub is searched at most once an hour; the result
  is kept in `regressions`.
- **The review set's trigger.** A red run of the reviewer's test set engages the brake the same
  way, with the trigger `review set missed <cases>` ([`review-set.md`](review-set.md)).
- **While it is on**, reviews block as before Q1:
  - the dispatcher demotes nothing for pre-existing, no class or no `Evidence:`. An item under
    `Blocking:` or `Pre-existing:` blocks unless its class is one that never blocks (`style` and
    the like). An item with no class is listed as `unclassed`.
  - the no-repeat rules are off: no settled findings, no pass rule, no history in the prompt.
  - the full review runs one effort step higher (low, medium, high, xhigh, max), still capped at
    `REVIEW_EFFORT_MAX`.
  - `REVIEW_LIGHT` is off.
- **The release.** `canccu-dispatcher brake release` is the product owner's only. The leader and
  runs are refused, as with a locked setting (exit 3). The release removes `brake` and writes
  `<time> po brake release - released` to `actions.log`. Nothing else releases the brake. It
  also writes `brake-released`, the newest merged PR: the trigger then waits until a PR merged
  after the release moves the window, and decides again from there.
  `canccu-dispatcher brake` prints the state.
- **Where it shows.** `canccu-status` and the monitor show `brake: on since <time> (<trigger>)`.
  `canccu-status --kpi-review` prints one line each for the last `BRAKE_WINDOW` merged PRs,
  since the baseline (the PRs merged from the first `reviews.log` line on), and at the baseline.
  Each line gives the review rounds per merged PR, the blocking findings by class (the verdicts
  that left each), the findings demoted (a `Pre-existing:` item the brake kept blocking is not one), and the
  escaped defects per merged PR.
