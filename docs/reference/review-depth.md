<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Review depth: a head reviewed once

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
