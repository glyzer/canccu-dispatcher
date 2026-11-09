<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The status snapshot

Part of the reference; the index is [`README.md`](README.md).

## Status snapshot

After every pass, also a failed one, the dispatcher writes `status.json` in the project's dir: to
a temp file, then renamed over the old one, so a reader never sees half a file. It is not written
under `--dry-run`. `canccu-monitor` reads nothing else. Times are epoch seconds.

`schema` is `2`. A new field is additive and keeps the number; a change to a field's meaning
bumps it (`STATUS_SCHEMA` in `lib/canccu-snapshot.sh`). The monitor warns about a newer schema
and still draws what it can. `tests/fixtures/monitor/steps.json` is a snapshot written by the
dispatcher; `tests/canccu-snapshot2.sh` checks that it has every field the dispatcher writes.

| Field | What |
|---|---|
| `schema`, `version` | The schema number; the release that wrote it |
| `project`, `repo`, `repo_name`, `pid`, `interval` | The project, its repo, the clone's dir name, the dispatcher's pid, `INTERVAL` |
| `pass` | `at`, `started`, `duration`, `durations` (the last 5), `ok` (false: GitHub could not be read, or the pass ended early), `error`, `paused`, `backoff_until` |
| `caps` | `running` and `cap` (this project), `total_running` and `total_cap` (all projects) |
| `spend` | `today_usd` (exact costs of today's finished runs, UTC), `runs_without_cost` (while above 0, `today_usd` is a lower bound), `day`, `freeze` (`AUTO_MERGE_UNTIL` or null) |
| `running[]` | Each live run, then each managed unit in `check` or `merging` without one: `key`, `issue` (the lead issue), `issues`, `pr`, `package`, `risk`, `kind` (`work`, `review`, `fix-check`, `answer`, `planner`, `health`, `waiting`), `phase`, `stage`, `pipeline` (`plan`, `work`, `ci`, `no-checks`, `review`, `fix`, `fix-check`, `merge`), `ci` (`green`, `red`, `pending`, `none`, or null), `review_verdict` (`changes` once the full review asked for changes), `title`, `started`, `minutes`, `min_cap`, `turns`, `turn_cap`, `last_line`, `color` |
| `needs_you[]` | What waits for you: `kind` (`accept`, `needs-you`, `plan`, `question`, `checkpoint`, `plan-invalid`, `budget`), `issue`, `issues`, `pr`, `package`, `step`, `stage` (where it parked), `reason`, `since`, `title`, `url`, `color` |
| `queue[]` | The candidates in the order the dispatcher takes them, at most 15: `issue`, `title`, `lane` (`fast` or `step`), `package`, `blocked`, `waits_on` (for example `blocked by 12 14`, `depends on auth`, `step budget reached`) |
| `milestones[]` | The open milestones in roadmap order: `title`, `open`, `closed`, `due`, `checkpoints[]` (`issue`, `state`, `ready`) |
| `events[]` | The last 20 rows of the dispatcher's own log lines: `at`, `issue`, `package`, `text`, and `count` and `first_at` when consecutive lines that differ only in a counter fold into one row |
| `steps[]` | Each current step, and each other step with a state file that is not done (below) |
| `current_step` | The main track's current step (its milestone number), or null |
| `step_overview[]` | Every open milestone, for the monitor's roadmap: `milestone`, `title`, `track`, `place` (`done`, `current`, `next`, `later`), `work_open`, `work_closed`, `issues[]` (the current and next steps' open work issues: `issue`, `title`, `url`, `status`, `waits_on`, `package`) |
| `other_runs[]` | Live runs in the project's workers dir the dispatcher did not start (a worker started by hand): `repo`, `key`, `kind`, `started` |
| `usage` | `five_hour` and `seven_day` (percent, or null), `resets_at`, `weekly_resets_at`, `at`, `state` (`normal`, `slow`, `stop`, `drain`), `text` ([`usage.md`](usage.md)) |
| `stale[]` | The sections copied from the previous snapshot because this pass could not read them fresh |

`steps[]` items: `milestone`, `title`, `track` (`main`, `parallel`), `current`, `phase`, `wave`,
`epic`, `error` (why it needs the lead, or null), `checkpoint` (`issue`, `state`, `waiting`),
`budget` (`usd`, `limit`, `runs_without_cost`, `over`), `plan` (null before the first valid plan;
else `wave`, `at`, `left_out` and `packages[]`: the plan's `name`, `issues`, `risk`,
`risk_reason`, `areas`, `depends_on`, `carried_from`, plus `key`, `state` (`pending`, `blocked`,
`work`, `ci`, `no-checks`, `review`, `fix`, `fix-check`, `accept`, `merging`, `merged`, `closed`,
`refused`, `needs-you`), `pr`, `branch`, `risk_effective`), `health` (`state`, `key`, `pr`) and
`notes[]` (`at`, `kind`: `follow-up` or `roadmap`, `pr`, `text`).

A pass that ends before its snapshot (a bash error; its text is in `dispatch.log`) gets one line
in the pane, "the pass ended early (exit N)", and a snapshot with `ok: false` saying the same.
The next pass runs as usual. None of the snapshot's extra reads (milestones, blockers) can fail a
pass.
