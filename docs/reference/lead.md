<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The lead

Part of the reference; the index is [`README.md`](README.md).

## The lead's session

The lead is an interactive `claude` session in the left pane of window `main`, which `canccu-up`
starts in `~/code` with the project's `gh` login ([`projects.md`](projects.md)). The dispatcher
does not start, wake or watch it: it is your own session, used to turn ideas into issues the
pipeline can run and to clear what waits for you. Nothing the lead does bypasses the pipeline:
its PRs, if any, are reviewed and gated like a worker's.

## Writing issues

An issue is the worker's spec and the reviewer's checklist, so write it for both:

- `## Goal`: what changes for whom, in two or three sentences;
- `## Acceptance criteria`: checkboxes a reviewer can verify from the diff and the tests;
- `## Out of scope`: what a worker must not do, so it neither creeps nor asks;
- a last line `Risk: low|normal|high — <why>`.

Label it `ready` once you agree with it; until then the dispatcher lists it under "waiting for the
product owner" in `canccu-status` and never starts it. A `Blocked by #x` line (or a GitHub
blocked-by link) on a `ready` issue holds it until #x closes. `blocked` holds it whatever its links
say, until you remove the label: the dispatcher removes only a `blocked` it set itself (a worker
that stopped blocked).

## Steps and epics

A roadmap step is a milestone whose title starts with its number (`1 Skeleton`, `2 Contracts`);
"Parallel tracks" runs beside the main track. Each step has:

- an **epic** (label `epic`) whose sub-issues are the step's issues; an `Order: #a → #b` line
  orders them in the queue. The dispatcher posts the step's plan there and labels it `needs-you`
  when the step needs the lead;
- optionally a **checkpoint** issue (label `checkpoint`): the step pauses there after its health
  pass until you label it `checkpoint-ok` or close it ([`steps.md`](steps.md)).

An issue with no milestone, or labelled `fast`, runs alone in the fast lane.

## What waits for you

The monitor's NEEDS YOU box and `canccu-status` list it; pings tell your phone
([`pings.md`](pings.md)). Each item says how to clear it:

| Item | How |
|---|---|
| A plan-tier plan | Read `docs/plans/issue-<n>.md` in the draft PR; label the issue `plan-ok`, or comment |
| An escalated question | Answer it in a comment on the issue: the worker resumes with it |
| An accept | Label the PR `accepted`, or `canccu-ship <n>` (only where the repo allows auto-merge) |
| A checkpoint | Read the summary; label `checkpoint-ok`, or close it |
| The fix-check's open items | `needs-work` with your comments: one more fix round and a fix-check of it; a line `full review` in the comment asks for a new full review |
| `needs-you` (CI red, no PR, a failed run) | Read the latest comments; comment to resume the worker, `needs-work` with your comments, or fix it yourself |
| An invalid plan, the step budget | Comment on the epic and remove `needs-you` to plan again; raise `STEP_BUDGET` |

## The owner of a waiting item

Every waiting item has one owner: `po` (the product owner, you) or `leader`. With `LEADER=off`,
the default, every item is `po`. With `LEADER=on`, the first matching rule decides
(contracts §1):

1. a checkpoint, an invalid plan, a step budget, or a question the answerer escalated to the
   product owner → `po`;
2. an accept whose reason is `users see it:`, `changes agent config`, a gated path or directory,
   `maintainer accept:` or `the issue has manual-accept`; a `risk high` accept while
   `LEADER_ACCEPTS_HIGH_RISK=0`; any accept while `LEADER_ACCEPTS=none` → `po`;
3. a plan (its needs-you, or the accept of a plan-tier PR) of a unit with an issue labelled
   `manual-accept` → `po`;
4. everything else → `leader`.

The dispatcher works it out from its own state and settings, never from a label the leader sets,
and stores it as the unit's `owner` when the unit enters `accept` or `needs-you`
([`state.md`](state.md#a-units-state)). `canccu-status` lists the leader's items under
`leader has it:`; the monitor's NEEDS YOU box and the pings show only yours
([`monitor.md`](monitor.md), [`pings.md`](pings.md)). The hand-over of a leader's item after 60
minutes waits for the leader's acknowledgement, which is not built yet.

## The feed

The dispatcher writes `events` in the project's dir (next to `dispatch.log`): one line per change
of state a person must act on, in the format of contracts §3, tab-separated:
`<time> <id> <owner> <class> <kind> <unit> <pr> <url> <text>`. Ids count up from 1 under the
file's lock; the text is one line of at most 200 characters. A state that goes on writes nothing
more; when an item no longer waits, one line of kind `closed` says `closes <id>: <new state>`.
Runs starting, reviews starting, a worker done, the usage slow mode and planned restarts write
none. Every pass touches `heartbeat` beside it.

`canccu-dispatcher wait --owner leader` blocks until the next line for that owner and prints it
([`commands.md`](commands.md)); `--ack <id>` resumes after the last line handled. Exit 3 says the
heartbeat is 10 minutes old: the dispatcher may be down. A loop for the leader:

```
ack=0; while l=$(canccu-dispatcher wait --owner leader --ack "$ack"); do ack=$(cut -f2 <<<"$l"); …; done
```

| Kind | Written when | Check, and what to do |
|---|---|---|
| `accept` | A unit enters `accept` | Read the PR and its review; the product owner accepts |
| `plan` | A plan-tier plan waits | Read `docs/plans/issue-<n>.md`; `plan-ok` is the product owner's |
| `question` | The answerer escalated a worker's question | Answer it on the issue if it is yours |
| `needs-you`, `pr-needs-you` | A unit, or our PR, needs a person | Read the latest comments; comment to resume, or fix it |
| `run-ended` | A run ended with no PR, by a crash or a budget | Read the run's report; comment to resume, or reword the issue |
| `checkpoint` | A step waits for `checkpoint-ok` | Read the summary; the product owner decides |
| `idle` | A unit no rule moved for `IDLE_ALARM_MIN` minutes with nothing running | `canccu-status` and the log: why it sits; `canccu-run`, or a comment |
| `hold` | Nothing new starts: low disk or `STEP_BUDGET` (class `ask`), the usage back-off or a GitHub rate limit (class `info`, the end time in the text) | Free disk, raise `STEP_BUDGET`; a timer ends the others |
| `dispatcher` | The dispatcher started after a stop it did not plan (killed, a crash, a reboot) | The log's last lines before the start |
| `step-done` | A step is done (class `info`) | Nothing |
| `closed` | An item no longer waits (class `info`) | Nothing: drop the item it closes |

`Follow-up:` and `Roadmap note:` lines from the step's PRs land in the digest and the checkpoint
summary: the lead turns the ones you want into issues.
