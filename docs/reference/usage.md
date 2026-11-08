<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The usage throttle

Part of the reference; the index is [`README.md`](README.md).

## Usage throttle

Every `claude -p` run's output stream carries a `rate_limit_event` with the account's usage
shares: the 5-hour and the weekly window, each with its use (0–1) and its reset time.
`lib/canccu-stream.py` writes the newest one of each run to `workers/usage.json`. One account
serves every project on the host, so the newest reading of all projects counts, and a window whose
reset has passed counts as 0 %. With no reading at all nothing is throttled, and the usage-limit
back-off below stays the fallback. No AI runs to probe the usage.

- **5-hour share ≥ `USAGE_SLOW`** (60 %): at most one run at a time over all projects; the fast
  lane counts too.
- **≥ `USAGE_STOP`** (90 %): no run starts. Each running worker is nudged: every worker run has a
  `PostToolUse` hook (`libexec/canccu-nudge-hook`) that, while `workers/<repo>-<K>.nudge` exists,
  tells it to finish its current small step, commit and push a WIP if needed, write `Next action:`
  and stop. A nudged worker that ends is `limited` and resumes with `continue` after the 5-hour
  reset. Reviewers, fix-checks, answerers and planners are short: they finish.
- **Weekly share ≥ `USAGE_WEEKLY_DRAIN`** (90 %): **drain mode**. No new package, planner wave,
  health pass or fast-lane issue starts; work already started finishes its whole pipeline (the
  worker, the review, the fix, the fix-check, the merge) under the 5-hour caps. It ends when the
  weekly share drops below the threshold.

`canccu-status` (its `usage:` line), the snapshot (`usage`) and the monitor's header show the
shares and the throttle state, for example `draining (weekly 92%)`.

## Usage-limit back-off

When any run's output says the account hit its limit ("usage limit reached", "You've hit your
limit", "5-hour limit · resets 11:30pm (UTC)", "weekly limit", …), whatever its exit status:
the issue keeps `in-progress`, its phase becomes `limited`, and `~/.canccu/backoff` stops every
project until the reset time the message names plus 120 s, or for 30 minutes when it names none
(only a time of day, with an optional zone, is read). A longer back-off already running is kept.
`canccu-status` shows "usage limit until <time>". No `needs-you`, no comment.

After the back-off a worker resumes with `continue`, a review or fix-check runs again at the same
head, and an answerer asks again (the round does not count). A run that hits the limit again backs
off again: never a failure, never a new fix round.

The throttle and the back-off are per host: two hosts on one Claude account each read only their
own runs ([`../hosts.md`](../hosts.md)).
