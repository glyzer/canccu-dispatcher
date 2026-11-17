<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Config: steps, packages, reviews and usage

Part of the reference; the index is [`README.md`](README.md). The other project keys, how to
change a setting and the settings table are in [`config.md`](config.md); the rules keys in
[`rules.md`](rules.md).

## Keys

| Key | Default | Meaning |
|---|---|---|
| `STEP_BUDGET` | `400` | USD per step: its planner, package, review, fix-check, answerer and health runs ([`steps.md`](steps.md)) |
| `BUDGET_PLAN` | `60 10 30` | The planner of a step's wave |
| `BUDGET_HEALTH` | `250 60 150` | The health pass at the end of a step |
| `BUDGET_PACKAGE_MAX` | `600 200 360` | A package's work, resume and review budgets are the issue's times its issue count, each part capped by this |
| `PACKAGE_LINES` | `1500` | The planner's size guide: changed lines per package |
| `BUDGET_LINES` | `0` | Above 0: a package's work, resume and review budgets are multiplied by its planned changed lines over this (rounded up) when that is more than its issue count, still capped by `BUDGET_PACKAGE_MAX`; the planner then gives each package `lines` ([`packages.md`](packages.md#the-planner)). `0`: the issue count only |
| `PACKAGE_MIN_ISSUES` | `3` | Above 1, the planner aims for at least this many issues per package, where they fit together (never unrelated ones); `1`: no nudge |
| `PACKAGE_HOLD_SMALL` | `0` | `1`: the planner may leave a lone small leftover (under about 300 changed lines) out of a wave while an earlier package of its area runs or other issues of its area wait, so it joins a later wave's package of its area ([`packages.md`](packages.md#the-planner)) |
| `PLAN_MODEL` | empty | The planner's model; empty: `MODEL` |
| `WAVE_ROLLING` | `0` | `1`: the next wave is planned while this one runs, once no package of it waits to start and a run slot is free (`CAP`); `0`: the planner waits for the wave to be over ([`packages.md`](packages.md#waves)). Locked |
| `REVIEW_MODEL` | empty | The full reviewer's model; empty: `MODEL` ([`reviews.md`](reviews.md), "Model by kind") |
| `REVIEW_MODEL_LIGHT` | empty | The full reviewer's model for a light PR: every path docs, a test (`TEST_PATHS`) or a `LIGHT_REVIEW_PATHS` match, none gated; empty: `REVIEW_MODEL` ([`reviews.md`](reviews.md), "Model by kind") |
| `FIXCHECK_MODEL` | empty | The fix-check's model, for example a cheaper one (`claude-sonnet-5-5`); empty: `MODEL` |
| `FIXCHECK_FULL_LINES` | `100` | A push after a passed review that changes more of the PR's own lines than this since the last full review gets a full review, not a fix-check |
| `FIXCHECK_COUNT_MAIN` | `0` | `0`: that count leaves out what a clean merge of main brought into the PR's files; `1`: those lines count too. A merge of main that conflicted counts in full: its resolution is the PR's own change ([`reviews.md`](reviews.md)) |
| `FIXCHECK_COUNT_RESOLVED` | `0` | `1` (with `FIXCHECK_COUNT_MAIN=0`): after a merge of main that conflicted, the count starts from git's merge with the conflict markers, so only the hand-resolved hunks and later commits count, for the fix-check's effort too ([`review-depth.md`](review-depth.md#the-count-after-a-merge-of-main)). Locked |
| `FINDINGS_RECUR` | `3` | Merged PRs with findings of the same key (class + file) within `FINDINGS_RECUR_DAYS` days before the dispatcher files one issue `Recurring finding: <class> in <file>`, not `ready` ([`reviews.md`](reviews.md#recurring-findings)); `0`: never, and nothing is counted |
| `FINDINGS_RECUR_DAYS` | `30` | The window, in days, `FINDINGS_RECUR` counts over |
| `REVIEW_EFFORT_MAX` | empty | The highest effort of a full review and a fix-check on this machine: `low`, `medium` or `high`. It lowers, never raises, and has no exceptions: gated paths and agent configuration are capped too. `reviews/<pr>.effort` then says `(capped)`. Another value is said once in the log and ignored ([`reviews.md`](reviews.md), "Effort by risk") |
| `HEALTH_MODEL` | empty | The health pass's model (its resumes too), for example a cheaper one; empty: `MODEL` ([`steps.md`](steps.md)) |
| `HEALTH_EFFORT` | empty | The health pass's `--effort` (`low`, `medium`, `high`, `xhigh`, `max`); empty: none, the account's default effort, as for every other run. Another value is said once in the log and not passed |
| `STEP_DEEP_REVIEW` | `0` | `1`: a step whose work is done gets a deep review of its whole change before the health pass; its blocking findings become one polish issue ([`steps.md`](steps.md#deep-review-and-polish)) |
| `DEEP_REVIEW_MODEL` | empty | The deep review's model; empty: `REVIEW_MODEL`, else `MODEL` |
| `DEEP_REVIEW_EFFORT` | `high` | The deep review's `--effort` (`low`, `medium`, `high`, `xhigh`, `max`) |
| `BUDGET_DEEP_REVIEW` | `150 40 120` | The deep review at the end of a step |
| `CADENCE_DAYS` | `0` | Above 0: a step whose milestone description has the line `Cadence: on` gets a round every this many days while it runs: its deep review, polish and checkpoint summary ([`steps.md`](steps.md#cadence-rounds)). `0`: no rounds |
| `STEP_TAG` | empty | The step tag the checkpoint OK pushes, with `{n}` for the step's number (for example `step-{n}`); empty: none. Locked |
| `USAGE_SLOW` | `60` | 5-hour usage share (%) from which one run at a time runs, over all projects ([`usage.md`](usage.md)) |
| `USAGE_STOP` | `90` | 5-hour usage share (%) from which no run starts and running workers are asked to stop at a safe point |
| `USAGE_WINDOW_DELTA` | `0` | `1`: each run's spend-log line records the 5-hour window's utilization before and after it ([`state.md`](state.md#the-spend-log)). Off by default: it means something only with one run at a time on a plan with a 5-hour window |
| `USAGE_WEEKLY_DRAIN` | `90` | Weekly usage share (%) from which nothing new starts; work already started finishes |
| `PACE` | `off` | Weekly pacing against the share of the week gone ([`usage.md`](usage.md#pacing)): `notify` (a log line only), `cap` (at most `PACE_CAP` runs over all projects while ahead) or `pause` (while ahead no new issue or package starts and stopped runs are not resumed; fix runs of started work go on); `off`: none |
| `PACE_MARGIN` | `10` | Points the weekly share may be above the share of the week gone before the project counts as ahead |
| `PACE_CAP` | `1` | `PACE=cap`: the runs at once over all projects while ahead |
| `USAGE_MAX_AGE_MIN` | `360` | A usage reading older than this (minutes), or older than the dispatcher's start, counts as unknown: nothing is throttled until a run writes a fresh one ([`usage.md`](usage.md)); `0`: no age limit |
