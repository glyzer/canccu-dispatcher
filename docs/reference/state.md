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
| `projects/<name>/` | One project (below) |

## A project's dir

In `~/.canccu/projects/<name>/`:

| Path | What |
|---|---|
| `config`, `rules` | [`config.md`](config.md), [`rules.md`](rules.md) |
| `gh/` | The project's own `gh` login (`hosts.yml`, mode 600) ([`projects.md`](projects.md)) |
| `state/<K>` | One file per unit the dispatcher manages (`<n>`, `pkg-<m>-<name>`, `pkg-<m>-health`), `key=value` lines (below) |
| `steps/<m>` | A step's state, with `steps/<m>.keys` (its run keys, for its budget), `.packages` (one line per finished package), `.notes` (follow-ups and roadmap notes), `.plan-<w>.json` (each wave's plan) and `.plan-<w>.rejected.json` |
| `workers/` | The run engine's state: locks, logs, `.last` reports, session ids, worktrees, `usage.json`, `spend.log`, `.nudge` files ([`engine.md`](engine.md)) |
| `reviews/<pr>/<sha>.md` | A reviewer's review of that head, which the dispatcher posts; `<sha>.findings.md` the full review's findings for the fix-check (or, after your `needs-work` on a fix-check's open items, those items and your comments, rebuilt each time from `<sha>.open.md`, the open items that fix-check left); `reviews/<pr>.sha`, `.mode`, `.effort` and `.model` what the PR's latest reviewer works on, at which effort and on which model |
| `followups` | One tab-separated line per wave (`step-<m>-wave-<w>`, `step-<m>-health`, `fast`): the issue its non-blocking review findings go to ([`reviews.md`](reviews.md)) |
| `handoffs/<K>.md` | The handoff a run stopped by the usage limit ended with, for the fresh session after the reset ([`usage.md`](usage.md#after-the-reset)) |
| `questions/<K>.txt` | The question a worker stopped with, for its answerer |
| `pings/<n>` | The state issue n was last pinged for ([`pings.md`](pings.md)) |
| `digest/<date>.md` | The daily digest |
| `merged.log` | One line per merged PR of a managed issue: time, issue, PR, how (`auto`, `accepted`, or `by hand` when the dispatcher did not arm it), title |
| `workers/spend.log` | One tab-separated line per run, written when it ends (below) |
| `answers.log` | One line per question an answerer answered, with the link to its comment |
| `want` | The project's wait for a shared slot, rewritten by every pass: `n` (the runs it could not start for want of a slot of `TOTAL_CAP`; 0: none), `cap` (its `CAP`), `until` (the epoch the wait holds to); removed when the dispatcher exits ([`projects.md`](projects.md#fair-share-of-total_cap)) |
| `last_start` | When the project's engine last started a run (ns since the epoch): the fair share's tie rule |
| `state.format` | The format of `state/` and `steps/`: one number (below) |
| `dispatch.log` | One line per action, each starting with its UTC time (`2030-11-05T12:00:00Z`; lines written by an earlier release have the host's local time, `2030-11-05 12:00:00`, and readers accept both), plus the raw output of the commands (prefixed `  │ `) |
| `events`, `heartbeat` | The feed, one line per event a person must act on, and the file every pass touches ([`lead.md`](lead.md#the-feed)) |
| `feed.open` | `<key>=<id>` of the open feed items no unit's state holds (holds, checkpoints, PRs labelled `needs-you`) |
| `.running` | Present while the dispatcher loops; one left at its start means a stop it did not plan |
| `dispatch.pid`, `.dispatch.lock` | The running dispatcher and its lock |
| `paused` | Present while paused (`canccu-pause`) |
| `gh_limit` | The epoch until which passes pause for a GitHub rate limit ([`pipeline.md`](pipeline.md#one-pass)); removed when it has passed |
| `.disk-low` | Present while free space is below `DISK_MIN_MB`, so the hold is logged once |
| `status.json` | The status snapshot, written after every pass ([`snapshot.md`](snapshot.md)) |
| `.warned-*` | The last recurring warning of a kind, so it is logged once |
| `blocked/<n>` | Issue `n`'s `blocked` was set by the dispatcher (a `waiting` run): the only kind it removes |

## The state format

`state.format` holds one number: the format of the project's `state/` and `steps/` files (a
missing file is format `0`, a release before the file). `canccu-dispatch` runs `state_migrate` at
start, under its lock and before the first pass: each migration from the file's number up to the
release's `STATE_FORMAT` (`2`), in order, writing the new number after each and logging
`state format <a> → <b>: <what it did>`. Migration 0 → 1 changes no field; 1 → 2 sets `owner` on each unit in `accept` or `needs-you` (`phase_at`, `ev_id` and `idle_ev` start empty). A number above
`STATE_FORMAT` (an older release after a newer one ran) stops the start with
`state format <n> is newer than this release knows (<STATE_FORMAT>); install a newer release`.
`--dry-run` only says which migrations it would run.

A release that adds or changes a state field raises `STATE_FORMAT`, adds the migration
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
asked once to write its missing review file, [`reviews.md`](reviews.md)),
`ny_kind` (what a `needs-you` waits for: `plan`, `question` or empty), `ny_stage` (where it
parked), `ny_wait` (`ci`: it only waited on CI), `phase_at` (when the phase last changed: the idle alarm's clock), `ev_id` (the feed line of the accept or needs-you it waits in), `idle_ev` (its `idle` feed line), `owner` (who an `accept` or `needs-you` waits for, `po` or `leader`, set when the unit enters the phase and cleared when it leaves; [`lead.md`](lead.md#the-owner-of-a-waiting-item)), `exclusive` (of the one-at-a-time kind),
`nb_at` (the verdict whose non-blocking findings were filed), `finish_tried` (its finish session after a run that left work but no PR was had), `no_pr` (its last run finished with no PR: the next resume starts a fresh session), `fixes` and `fixes_pr` (the automatic fix runs on that PR, against `FIX_ATTEMPTS`), `main_merged` (the head a scripted merge of main pushed), `conflict_sha` (the head a conflict run started on), `conflict_paths` (that run's conflicting paths), `conflict_merge` (the head GitHub's conflict with main was last merged on by script), `ci_rerun` and `ci_rerun_at` (the red head whose failed jobs were rerun, and when the rerun started), `mm_err` (scripted merges failed in a row), `crash_tries` (the fresh runs a crash was given, against `CRASH_RETRY`; cleared when a run finishes), `retry_status` (the status of the run that crashed), `prev_phase` (the phase a unit in `starting` had, put back if the start fails), `started` (when its run started), `plan_ok`,
`body_fix` (the contract PR whose body the worker was resumed once to correct; [`merging.md`](merging.md)),
`merge_tries` (the merges that failed on a transient GitHub error in a row, against `MERGE_RETRY`; cleared by a merge that goes through and by lifting a needs-you at the merge; [`merging.md`](merging.md#a-github-error-on-the-merge)),
`gone_at` (when its merged PR was first seen with an issue it closes still open; [`merging.md`](merging.md#a-merged-pr-that-leaves-its-issue-open)),
`accept_sha`, `merge_sha` and timestamps. `branch` is the
unit's branch (a single issue's `<n>-<slug>`, set at its start; an issue started before 0.2 has
none). A package adds `pkg`, `step`, `wave`, `members`, `risk`, `risk_reason`, `review_risk` and
`health`.

Every write of a `state/<K>` or `steps/<m>` file goes through a temp file under the file's own
lock (`.<K>.lock` beside it), so the pass and a `canccu-ship`, `-stop`, `-run` or `-review` at the
same time never lose a key. The state of an issue goes when the issue closes.

`steps/<m>` holds the step's `phase` (`idle`, `planning`, `running`, `health-due`, `health`,
`checkpoint`, `done`, `needs-you`), `title`, `track` (`main` or `parallel`), `wave`, `plan`,
`left_out`, the needs-you reason, `health`, `health_pr`, `checkpoint` and the summary's link.

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
| 5 | type | `plan`, `build` (a new or resumed worker), `fix` (a worker's follow-up fixing review findings, a red CI or a `needs-work`), `merge` (a worker's follow-up bringing in main: after its contract PR merged, or a merge of main that conflicts), `review`, `fix-check`, `answer`, `health` |
| 6 | model | The `--model` the run got; `-`: the account's default |
| 7 | effort | The `--effort` the run got; for a review or fix-check, the code-review skill's effort it was told; `-`: none |
| 8 | session | `fresh` or `resumed` |
| 9–12 | tokens | Input, output, cache read and cache write tokens, from the final `result` event's `usage` |
| 13–14 | window | The 5-hour window's utilization (%) before and after the run, only with `USAGE_WINDOW_DELTA=1` ([`config.md`](config.md)); after: `-` when the run's own stream reported no reading |
| 15 | outcome | `k=v` fields joined by `,`, filled in by the dispatcher when it reaps the run: `pr=<n>` or `pr=none` and `ci=green`, `ci=red` or `ci=rerun-green` (a worker's run; rerun-green: green after the one rerun of its failed jobs, a flaky check) with `ci_wait=<s>`, the seconds from the check's start (`check_at`) to CI settling; `verdict=pass`, `changes`, `none` or `void`, `blocking=<n>`, `nonblocking=<n>` (a review or fix-check: its top-level list items under "Blocking" and under "Non-blocking", an estimate; in a `changes` file with no "Blocking" heading, the items before "Non-blocking" block); `answer=answered`, `escalate` or `none`; `rounds=<n>` (the unit's fix runs so far) |
| 16 | secs | The run's wall seconds, start to end; `-`: unknown. Lines written before it have 15 columns, and every reader takes both |

`canccu-status --spend` reads it with `merged.log`: the cost of every merged PR (its unit's runs,
lost ones included, its reviews and fix-checks, its answerers), grouped by model and run type,
then the same over all merged PRs.
