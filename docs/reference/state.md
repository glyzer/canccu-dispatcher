<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# State

Part of the reference; the index is [`README.md`](README.md). The status snapshot's schema is in
[`snapshot.md`](snapshot.md).

## Where the state lives

Everything the tool keeps is under `~/.canccu` (or `CANCCU_ROOT`). The installed code lives
elsewhere (`~/.local/lib/canccu-dispatcher/`, [`../install.md`](../install.md)); an upgrade never
touches the state, and uninstall keeps it unless you pass `--purge-state --yes`.

| Path | What |
|---|---|
| `config` | The global config ([`config.md`](config.md)) |
| `reviewer-token` | The reviewer bot's token, mode 600, one for all projects |
| `default-project` | The project a command without `--project` acts on; it owns the tmux session `canccu` |
| `backoff` | The epoch until which nothing starts in any project (a usage limit) |
| `.engine.lock` | Held while a run starts, so `TOTAL_CAP` holds over all projects |
| `profiles/<template>/` | Your own project templates for `canccu-init --profile` |
| `projects/<name>/` | One project ([`project-dir.md`](project-dir.md)) |

## A project's dir

Every file in `~/.canccu/projects/<name>/` is listed in [`project-dir.md`](project-dir.md).

## The review brake

Two files in the project's dir ([`review-depth.md`](review-depth.md#the-review-brake)):

- `brake`: while the brake is on, one line, `<time> <trigger>`: the UTC time it engaged and why,
  for example `2030-11-05T12:00:00Z escaped defects 0.20/PR over the last 10 merged PRs, baseline
  0.10/PR`. Every review decision checks that the file exists. Only `canccu-dispatcher brake
  release` removes it.
- `brake-baseline`: one line, `<time> <escaped/PR> <rounds/PR> <PRs counted>`, written once when
  the first pass with enough PRs before Q1 finds it missing. Delete it to compute the baseline
  again.

## The state format

`state.format` holds one number: the format of the project's `state/` and `steps/` files (a
missing file is format `0`, a release before the file). `canccu-dispatch` runs `state_migrate` at
start, under its lock and before the first pass: each migration from the file's number up to the
release's `STATE_FORMAT` (`5`), in order, writing the new number after each and logging
`state format <a> → <b>: <what it did>`. Migration 0 → 1 changes no field; 1 → 2 sets `owner` on each unit in `accept` or `needs-you` (`phase_at`, `ev_id` and `idle_ev` start empty); 2 → 3 changes no field: workflow v2's
fields (`review_asked`, `nb_sha`, `plan_lines`, the step's `deep`, `polish`, `round` and
`cadence_at` fields) start empty, which means the behaviour before them; 3 → 4 changes no field either (the step's `round_from` starts empty); 4 → 5 sets `pre5=1` on each step that is idle or health-due, has neither field, is in no cadence round and has no unit of its own; the step's next pass then skips its deep review and health pass if it has no open work and some closed (`deep=skipped health=skipped`, on to the checkpoint), else drops the marker, so a step finished before the upgrade is not owed what the new defaults turn on (#277). A number above
`STATE_FORMAT` (an older release after a newer one ran) stops the start with
`state format <n> is newer than this release knows (<STATE_FORMAT>); install a newer release`.
`--dry-run` only says which migrations it would run.

A release that adds a state field, or changes one, raises `STATE_FORMAT` (a field whose empty
value means the behaviour before it gets a migration that changes nothing, so an older release
refuses the state instead of dropping the field), adds the migration
(`state_migrate_<n>` in `lib/canccu-stateformat.sh`) and a test that upgrades a project with units in
flight (`work`, `needs-you`, `merging`) and checks the next pass handles them as before
(contracts §6).

## A unit's state

`state/<K>` holds, among others: `phase` ([`pipeline.md`](pipeline.md)), `pr`, `color` (its
palette index), `stage` (`review` → `fixing` → `fixcheck`), `reviewed_sha` (the head the full
review asked for changes on; after a `needs-work` on a fix-check's open items, that fix-check's
head), `review_mode`, `review_sha` (the effort and model are in `reviews/<pr>.effort` and `.model`;
an empty model is the account
default), `review_maccept` (the full review's
`Maintainer accept:` reason; a fix-check's own, given with its `changes`, is added), `open_sha`
(the head a fix-check left open items on; cleared by a `pass` before its merge step and by a new
cycle), `posted` (the head whose review was posted), `file_retry` (the head whose reviewer was
asked once to write its missing review file, [`reviews.md`](reviews.md)), `review_retry` (the head whose review or fix-check, stopped at its budget with no verdict, was given one full review),
`ny_kind` (what a `needs-you` waits for: `plan`, `question` or empty), `ny_stage` (where it
parked), `ny_wait` (`ci`: it only waited on CI), `phase_at` (when the phase last changed: the idle alarm's clock), `ev_id` (the feed line of the accept or needs-you it waits in), `ev_at` (when that line was written: the hand-over clock), `idle_ev` (its `idle` feed line), `owner` (who an `accept` or `needs-you` waits for, `po` or `leader`, set when the unit enters the phase and cleared when it leaves; [`leader.md`](leader.md#the-owner-of-a-waiting-item)), `exclusive` (of the one-at-a-time kind),
`nb_at` (the verdict whose non-blocking findings were filed), `nb_sha` (`<pr>:<sha>:<light|full>`, the head and review kind whose non-blocking findings were filed: a later verdict of that kind on it files none), `review_asked` (`1`: a `needs-work` comment asked for a `full review`; the next head gets one even when it passed already, cleared once that review's verdict is acted on; [`review-depth.md`](review-depth.md)), `hist_at` (the verdict whose findings went into `reviews/<pr>/history`), `finish_tried` (its finish session after a run that left work but no PR was had), `no_pr` (its last run finished with no PR: the next resume starts a fresh session), `fixes` and `fixes_pr` (the automatic fix runs on that PR, against `FIX_ATTEMPTS`), `blocking_last`, `blocking_prev` and `blocking_at` (the blocking findings of the last verdict acted on, of the one before, and the last one's time), `extra_fix` (the cycle had its extra fix round, `FIX_EXTRA_IF_FEWER`; cleared by a new cycle), `main_merged` (the head a scripted merge of main pushed), `conflict_sha` (the head a conflict run started on), `conflict_paths` (that run's conflicting paths), `conflict_merge` (the head GitHub's conflict with main was last merged on by script), `ci_rerun` and `ci_rerun_at` (the red head whose failed jobs were rerun, and when the rerun started), `ci_wait_at` (`<head>:<epoch>`: when the rerun of that head's failed jobs first had to wait for a running or refusing run; after 10 minutes it is `needs-you`), `mm_err` (scripted merges failed in a row), `crash_tries` (the fresh runs a crash was given, against `CRASH_RETRY`; cleared when a run finishes), `retry_status` (the status of the run that crashed), `prev_phase` (the phase a unit in `starting` had, put back if the start fails), `started` (when its run started), `run_head` and `run_draft` (its PR's head and draft state when the run started), `used` (`<turns> <usd> <secs>` of its runs since it started, deep reviews excepted), `cont` and `cont_why` (the continuations so far and the budget the last run stopped at; [`usage.md`](usage.md#continuations)), `plan_ok`,
`body_fix` (the contract PR whose body the worker was resumed once to correct; [`merging.md`](merging.md)),
`body_lines` (the PR whose body the worker was resumed once to complete with its `Testing:` and `Revert:` lines; [`pipeline.md`](pipeline.md)),
`merge_tries` (the merges that failed on a transient GitHub error in a row, against `MERGE_RETRY`; cleared by a merge that goes through and by lifting a needs-you at the merge; [`merging.md`](merging.md#a-github-error-on-the-merge)),
`gone_at` (when its merged PR was first seen with an issue it closes still open; [`merging.md`](merging.md#a-merged-pr-that-leaves-its-issue-open)),
`plan_lines` (a package's planned changed lines, `BUDGET_LINES`; [`packages.md`](packages.md#package-runs)), `accept_sha`, `merge_sha` and timestamps. `branch` is the
unit's branch (a single issue's `<n>-<slug>`, set at its start; an issue started before 0.2 has
none). A package adds `pkg`, `step`, `wave`, `members`, `risk`, `risk_reason`, `review_risk` and
`health`.

Every write of a `state/<K>` or `steps/<m>` file goes through a temp file under the file's own
lock (`.<K>.lock` beside it), so the pass and a `canccu-ship`, `-stop`, `-run` or `-review` at the
same time never lose a key. The state of an issue goes when the issue closes.

`steps/<m>` holds the step's `phase` (`idle`, `planning`, `running`, `health-due`, `deep`, `health`,
`checkpoint`, `done`, `needs-you`), `title`, `track` (`main` or `parallel`), `wave`, `plan`,
`left_out`, the needs-you reason, `health`, `health_pr`, `checkpoint` and the summary's link;
with `STEP_DEEP_REVIEW=1` `deep` (`running`, `read`: merged, its report not read yet, `merged`,
`closed`), `deep_head`, `deep_pr`, `deep_blocking` and `polish` ([`steps.md`](steps.md#deep-review-and-polish)).
The deep review's unit adds `deep=1` and `deep_base` (and `round` in a cadence round). A cadence
step adds `round`, `round_phase`, `round_head`, `round_from`, `round_pr`, `round_blocking`, `round_polish`,
`round_cp`, `round_cp_at` and `cadence_at` ([`steps.md`](steps.md#cadence-rounds)).

## Colour per issue

An issue gets a colour when it becomes managed or a run of it starts: the lowest free one of 6
ANSI 256 colours (33 blue, 208 orange, 135 purple, 37 teal, 205 pink, 142 olive; red, yellow and
green mean needs-you, waiting and merged). Issues running at the same time never share one while
`CAP` is 6 or less. The colour marks the issue in the monitor, in the dispatcher's pane and in
its windows' tmux status. `dispatch.log` stays plain; `NO_COLOR` turns colour off.

## The spend log

`workers/spend.log` has one tab-separated line per run, written by the engine when the run ends
or is killed. The first four columns are the original format, so a reader of those keeps working;
the rest were added after them. `-` is an unknown value.

| # | Column | What |
|---|---|---|
| 1 | time | The epoch the run ended |
| 2 | repo | The repo's name |
| 3 | key | The run's key: `<n>` or `pkg-<m>-<name>` (a worker), `review-<pr>` (a review or fix-check), `answer-<K>`, `plan-<m>` |
| 4 | cost | The exact USD claude reported, or `?` (stopped at a budget, stalled, crashed, killed) |
| 5 | type | `plan`, `build` (a new or resumed worker), `fix` (a worker's follow-up fixing review findings, a red CI or a `needs-work`), `merge` (a worker's follow-up bringing in main: after its contract PR merged, or a merge of main that conflicts), `review`, `fix-check`, `answer`, `health`, `deep` (the step's deep review) |
| 6 | model | The `--model` the run got; `-`: the account's default |
| 7 | effort | The `--effort` the run got; for a review or fix-check, the code-review skill's effort it was told; `-`: none |
| 8 | session | `fresh` or `resumed` |
| 9–12 | tokens | Input, output, cache read and cache write tokens, from the final `result` event's `usage` |
| 13–14 | window | The 5-hour window's utilization (%) before and after the run, only with `USAGE_WINDOW_DELTA=1` ([`config-steps.md`](config-steps.md)); after: `-` when the run's own stream reported no reading |
| 15 | outcome | `k=v` fields joined by `,`, filled in by the dispatcher when it reaps the run: `pr=<n>` or `pr=none` and `ci=green`, `ci=red` or `ci=rerun-green` (a worker's run; rerun-green: green after the one rerun of its failed jobs, a flaky check) with `ci_wait=<s>`, the seconds from the check's start (`check_at`) to CI settling; `verdict=pass`, `changes`, `none` or `void`, `blocking=<n>`, `nonblocking=<n>` (a review or fix-check: its top-level list items under "Blocking" and under "Non-blocking", an estimate; in a `changes` file with no "Blocking" heading, the items before "Non-blocking" block); `answer=answered`, `escalate` or `none`; `rounds=<n>` (the unit's fix runs so far). The engine writes the first fields itself when the run ends: `test_secs=<s>` and `tests=<n>`, the seconds from each of the run's Bash calls of `TEST_CMD` ([`rules.md`](rules.md)) to its result, summed, and their count (only when it made one) |
| 16 | secs | The run's wall seconds, start to end; `-`: unknown. Lines written before it have 15 columns, and every reader takes both |

`canccu-status --spend` reads it with `merged.log`: the cost of every merged PR (its unit's runs,
lost ones included, its reviews and fix-checks, its answerers), grouped by model and run type,
then the same over all merged PRs.

`canccu-status --costs [--since DATE] [--top N]` sums the same logs without any state of its own:
the cost by run type, the `N` (default 5) most expensive issues with their fix rounds, and the
cost by kind (`COST_KINDS` in the rules, [`rules.md`](rules.md)). A review or fix-check counts for
the issue whose PR merged; one for a PR not merged yet is listed as `PR <n>`. A unit not merged
yet has no PR title in the logs, so its kind is `other`. The daily digest has a `Cost today` line
with the last 24 h by kind, and a line for each issue over `COST_ROUNDS_ALERT` fix rounds.
