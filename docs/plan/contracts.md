<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Shared formats

Several packages use the formats below. They are fixed here once; an issue refers to this file
instead of describing them again. A change here is a plan change (see [`README.md`](README.md)).
Nothing in this file exists in the code yet unless it says so.

## 1. Owner

Every item that waits for someone has exactly one owner: `po` or `leader`. The first
matching line decides:

1. `LEADER=off` (the default) → `po`.
2. Class `interrupt` (section 2) → `po`.
3. A checkpoint, or a question the answerer escalated ("Needs the product owner:") → `po`.
4. An accept whose reason is one of these → `po`:
   - the PR touches `USER_VISIBLE_PATHS` (reason text: `users see it: <first matching path>`);
   - the PR touches a gated path or agent config;
   - the review has a `Maintainer accept:` line (breaking contract, destructive migration);
   - an issue of the unit is labelled `manual-accept`;
   - the risk is high and `LEADER_ACCEPTS_HIGH_RISK=0`;
   - `LEADER_ACCEPTS=none`.
5. A plan PR of a unit with an issue labelled `manual-accept` → `po`.
6. Everything else → `leader`.
7. An item of owner `leader` that the leader has not acknowledged for 60 minutes becomes
   `po` (one new feed line, kind `handover`).

The owner is stored in the unit's state as `owner` and shown by `canccu-status`, the snapshot and
the monitor. `po` is the product owner. Older text that says "lead" means `leader`; the review
line `Maintainer accept:` keeps its name.

## 2. Class

Every event has one class:

| Class | Means | Pushed to a person |
|---|---|---|
| `interrupt` | the dispatcher is dead (0.2: the stale heartbeat of §3 is the signal; the notifier of 0.3 writes the line); a security stop; all work is stopped and only the product owner can release it | at once, never capped, quiet hours do not hold it |
| `ask` | an accept, a decision, a checkpoint, a needs-you (kinds `needs-you` and `pr-needs-you`, owner by §1) | yes, to its owner |
| `info` | everything else worth keeping (merged, step done) | never; the digest carries it |

`PING_KINDS` keeps working: its kinds are all of class `ask`.

## 3. The feed

- File: `events` in the project's home (next to `dispatch.log`). Append only.
- Heartbeat: the file `heartbeat` in the same place, touched on every pass.
- One line per event, fields separated by one tab, no tab or newline inside a field:

  `<time>	<id>	<owner>	<class>	<kind>	<unit>	<pr>	<url>	<text>`

| Field | Value |
|---|---|
| time | UTC, `2030-01-31T10:00:00Z` |
| id | a whole number, one higher than the line before; the first is 1 |
| owner | `po`, `leader`, or `-` for class `info` |
| class | section 2 |
| kind | `accept`, `plan`, `question`, `checkpoint`, `needs-you`, `pr-needs-you`, `run-ended`, `idle`, `hold`, `dispatcher`, `step-done`, `handover`, `closed` |
| unit | the unit's key (`86`, `pkg-…`), or `-` |
| pr | the PR number, or `-` |
| url | the issue or PR link, or `-` |
| text | one plain line, at most 200 characters |

- **No repeats:** one line per unit for each change of state. "Still waiting" writes nothing.
- **Settling:** when an item no longer waits, one line of kind `closed` whose text starts with
  `closes <id>`.
- **Holds:** when nothing new of the project can start, one line of kind `hold` says why, and a
  `closed` line ends it. Class `ask`, owner `po`, when a person must act (disk below
  `DISK_MIN_MB`, `STEP_BUDGET` reached); class `info` when a timer ends it (the usage stop or
  back-off, a GitHub rate limit), with the time it ends in the text.
- **One writer at a time:** a line is appended under the feed file's own `kv_lock`, so two
  writers never give the same id.
- **Not in the feed:** started, reviewer started, worker done, the usage slow mode, planned
  restarts.
- `canccu-dispatcher wait [--owner po|leader] [--ack <id>]` blocks until a new line for
  that owner or until the heartbeat is older than 10 minutes, prints the line and exits.

## 4. The ask form

One renderer builds every ask. The GitHub mention, the block at the top of the PR body and (from
0.3) the notifier all show this text, in this order:

```
For the product owner: <what it is, one plain line>
Why you: <the owner reason from section 1>
Change (reviewer's summary):
  - <line 1>
  - <line 2>
  - <line 3>
Review: <pass|changes> on <short sha> · CI: <green|red|running|none>
Recommended: <accept | do not accept | answer needed>, <one-line reason>
If you accept: <what happens>
No answer: this waits.
<link> · head <short sha>
```

Rules:
- The facts (paths, size, risk, verdict, CI, the reason) come from the dispatcher's own shell code.
- The three change lines come from the independent reviewer's file, from a section the review
  prompt asks for. They never come from the worker or the PR body. Each is cut at 160 characters
  and stripped of links, mentions and markup.
- In the PR body the block sits between the markers `<!-- canccu:ask -->` and
  `<!-- /canccu:ask -->`; the dispatcher replaces what is between them when the head changes.
- One message per item: a changed state edits the message, a settled item marks it closed.
- With `NOTIFY_CONTENT=link` only the first line, the last line and the link leave the host.

## 5. New settings

A package adds its setting with the name and default below (rule 5 of the plan applies).
"Locked" settings cannot be changed by the leader or by a run.

| Setting | Default | Meaning | Package | Locked |
|---|---|---|---|---|
| `REVIEW_EFFORT_MAX` | empty | caps the review effort on this machine, gated paths and agent config included | E1 | no |
| `FIXCHECK_FULL_LINES` | 100 | a change after a pass above this many changed lines gets a full review; checked first, `FIXCHECK_BIG` still picks the fix-check's effort | M1 | yes |
| `KEEP_ACCEPT_ON_MAIN_MERGE` | 0 | 1 keeps the accept when the only change is a merge of main | M1 | yes |
| `CRASH_RETRY` | 1 | fresh retries with a handoff after a crash or a killed window | R1 | no |
| `DISK_MIN_MB` | 200 | below this free space a pass starts nothing and says so | R1 | no |
| `IDLE_ALARM_MIN` | 60 | minutes a unit may fit none of the three states of rule 1 before it writes a feed line (not `STALL_MIN`, which kills a silent run) | F1 | no |
| `LEADER` | off | `on`: a leader runs for this project | F1 | yes |
| `USER_VISIBLE_PATHS` | empty | grep -E on the PR's paths; a match always waits for the product owner | F1 | yes |
| `PREVIEW_CMD` | empty | per repo: the command that writes the before and after captures | N1 | no |
| `NOTIFY_CONTENT` | full | `full` or `link` | N1 | yes |
| `ALLOW_DEFAULT_GH_LOGIN` | 0 | 1 lets a project run on the broad default gh login | S1 | yes |
| `ACCEPT_CHANNELS` | all | which accept channels count: `label`, `ship`, `reply`, `leader`, or `all` | S2 | yes |
| `LEADER_ACCEPTS` | none | `technical` or `none`; read by the owner rule from F1, acted on from L1 | F1 | yes |
| `LEADER_ACCEPTS_HIGH_RISK` | 0 | 1 lets the leader accept high-risk technical PRs (hardened level only) | F1 | yes |
| `BRAKE_DEFECTS` | 2 | escaped defects within `BRAKE_WINDOW` that stop all automatic merges; 0 switches the brake off | L1 | yes |
| `BRAKE_WINDOW` | 20 | the number of most recent merged PRs the brake counts over | L1 | yes |
| `WORKER_WATCHES_CI` | 1 | 0: workers stop at "PR ready" and the dispatcher watches CI | P2 | no |
| `NOTIFY` | github | `github`, `telegram`, both, or `off` | 0.3 | yes |
| `NOTIFY_BATCH_MIN` | 30 | asks are collected this long into one message; 0 sends each at once | 0.3 | no |
| `NOTIFY_MAX_PER_DAY` | 8 | pushed messages above this go to the digest; `interrupt` is never capped | 0.3 | no |
| `NOTIFY_REMIND_H` | 12 | one reminder for an open ask after this many hours; 0: none | 0.3 | no |
| `QUIET_HOURS` | empty | for example `22-07`; empty switches quiet hours off | 0.3 | no |
| `QUIET_TZ` | empty | the clock `QUIET_HOURS` uses; empty: the host's | 0.3 | no |

Existing settings that are locked in the same way: `USER_LOGIN`, `REVIEWER_LOGIN`, `GATED_PATHS`,
`RISKY_PATHS`, `FIXCHECK_RISKY`, `HIGH_RISK_PATHS`, `HIGH_RISK_TEXT`, `SECURITY_REVIEW_WHEN`,
`REVIEW_CHECKS`, `REVIEW_EXTRA`, `AUTO_MERGE_UNTIL`, `PING`, `PING_KINDS`.

`REVIEWER_TOKEN_FILE` and `GH_CONFIG_DIR` are not settable through `config set`.

## 6. New state fields

| Field | Set by | Meaning | Package |
|---|---|---|---|
| `gone_at` | `merged_left` | when a merged PR was first seen with its issue still open | P1 |
| `branch` | `start_issue` | the branch of a single issue (packages have it already) | P1 |
| `body_fix` | `check_pr` | the contract PR whose body the worker was asked to correct once | P1 |
| `owner` | the owner rule | `po` or `leader` while the unit waits; empty otherwise | F1 |
| `ev_id` | the feed | the id of the unit's open feed line, for `closed` | F1 |

R1 adds a state format version and a migration step at start; every package after R1 that adds a
field adds its migration and a test that upgrades with units in flight.

## 7. The actions log

From L1: `actions.log` in the project's home, one line per command a person or the leader ran,
tab-separated: `<time>	<actor>	<command>	<unit or ->	<result>`. The actor is `po`,
`leader` or `dispatcher`.

## 8. The review file and the PR body

From Q1. The review file the reviewer writes has, in this order:

1. The summary line, exactly
   `Findings: <b> blocking, <n> non-blocking, <p> pre-existing` (all three counts, zeros
   included).
2. `Blocking:`, then the findings, ranked. Each is
   `<n>. <file>:<line> — <class>: <what is wrong>. Fix: <the fix>`, followed by one
   `   also <file>:<line>` line per further instance of the same class.
3. `Non-blocking:`, then the findings, one per line, each with `<file>:<line>`.
4. `Pre-existing:`, then the findings, one per line, each with `<file>:<line>`.
5. The `Maintainer accept:` line when it applies, the `Risk:` line and the verdict line, as today.

A heading with no findings is followed by `none`. Only `Blocking:` findings make the verdict
`changes`. The dispatcher files the non-blocking and pre-existing findings in the follow-up issue,
the pre-existing ones marked `(pre-existing)`.

The PR body of every work PR has, besides today's lines:

- `Testing:` each command run, then the last lines it printed, in a code block; or `none — <why>`.
- `Revert:` `plain revert`, or the numbered steps that undo state, config or a release.
