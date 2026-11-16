<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Review depth: a head reviewed once, the light review, the count

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
  the unit's `review_asked` until that review starts.

The worker's merge run for a conflict that pushed nothing (the head is still the one it started
on) is no reuse: it goes to `needs-you`, as before.

A head's non-blocking findings go to the follow-up issue once: a second verdict on the same
head (an explicit re-review) files none, and logs
`#<n> PR #<pr>: non-blocking findings of <sha7> are filed already; not filed again`.

## The light review

With `REVIEW_LIGHT=1` (rules, locked; [`rules.md`](rules.md)) a full review (never a fix-check)
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

With `FIXCHECK_COUNT_RESOLVED=1` (project config, locked) the count starts instead from the tree
`git merge-tree --write-tree` writes for that merge with its conflict markers (git ≥ 2.38). The
diff from it to the head holds the hand-resolved hunks and the PR's later commits; the size, gated
and risky checks see only those. The fix-check's effort (`FIXCHECK_BIG`, `FIXCHECK_RISKY`) counts
the same way with it, and as before without it. Any other git result counts as before: the cost
is a full review, never a missed one. The count after a pass, and the fix-check's with
`FIXCHECK_COUNT_RESOLVED=1`, diff with `--no-renames`: a file moved out of a gated or risky path
counts by its old path too.
