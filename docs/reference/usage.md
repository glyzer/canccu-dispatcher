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
  tells it to stop at a safe point with a handoff (below). A nudged worker that ends is `limited`
  and continues after the 5-hour reset in a fresh session from its handoff
  ([After the reset](#after-the-reset)). Reviewers, fix-checks, answerers and planners are short:
  they finish.
- **Weekly share ≥ `USAGE_WEEKLY_DRAIN`** (90 %): **drain mode**. No new package, planner wave,
  health pass or fast-lane issue starts; work already started finishes its whole pipeline (the
  worker, the review, the fix, the fix-check, the merge) under the 5-hour caps. It ends when the
  weekly share drops below the threshold.

`canccu-status` (its `usage:` line), the snapshot (`usage`) and the monitor's header show the
shares and the throttle state, for example `draining (weekly 92%)`.

## Usage-limit back-off

When a run ends in an error or a crash and its output says the account hit its limit ("usage
limit reached", "You've hit your limit", "5-hour limit · resets 11:30pm (UTC)", "weekly
limit", …): the issue keeps `in-progress`, its phase becomes `limited`, and `~/.canccu/backoff`
stops every project until the reset time the message names plus 120 s, or for 30 minutes when it
names none. The reset is read as an epoch after a `|` ("Claude AI usage limit reached|<epoch>"),
else as a time of day with an optional zone ("resets 3pm (Europe/Helsinki)", "resets at 15:30").
A longer back-off already running is kept.
`canccu-status` shows "usage limit until <time>". No `needs-you`, no comment.

After the back-off a worker continues in a fresh session ([After the reset](#after-the-reset)), a
review or fix-check runs again at the same head, and an answerer or planner asks again (the round
does not count). Reviewers, fix-checks, answerers and planners always start a fresh session: the
engine never keeps their session id. A run that hits the limit again backs off again: never a
failure, never a new fix round.

## After the reset

By the reset the prompt cache of the stopped session has long expired, so resuming it would read
the whole old conversation again at full price. A `limited` worker therefore starts a **fresh**
session (never `--resume`) in the same worktree and branch, unless `RESUME_ON` names `limited`
(then it resumes with "Continue where you stopped", as before).

**The nudge** (the hook's text, added after each tool call while the `.nudge` file exists): stop
now, without running tests; commit the work in progress (a WIP commit is fine) and push the
branch; end with a handoff as the final message.

**The handoff**: the run's final message, at most 40 lines, in this order:

```
Done: what is finished
Left: what is not
Next step: the first thing to do
Decisions made: the choices so far
Test state: which tests pass or fail
Head: <sha> (the pushed commit)
```

The dispatcher keeps it (the run's final message, from `.last`) in
`~/.canccu/projects/<name>/handoffs/<K>.md`; nothing is written to the repo.

**The fresh session's prompt**: "the usage limit has reset", the handoff, then the follow-up
handoff of [`engine.md`](engine.md#follow-up-runs) with `git log origin/main..HEAD --oneline` and
`git diff --stat origin/main...HEAD`. A run cut off by the hard limit before any nudge (an error
saying the limit was hit) has no handoff: its fresh session gets the same commit log and diff stat
and is told to check `git status` for uncommitted work. The handoff file goes once the fresh run
has started.

The throttle and the back-off are per host: two hosts on one Claude account each read only their
own runs ([`../hosts.md`](../hosts.md)).
