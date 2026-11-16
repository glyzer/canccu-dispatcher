<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Workflow v2 (#216) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (one session builds every
> task itself, in order; no subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fix #214 (a head reviewed twice) and #215 (a pause that does not hold), and add eight
opt-in features (light review, resolved-lines count, budgets by size, pacing, step deep review
with polish and tag, cadence rounds, lead tools, kickoff and gate docs), every new setting off by
default.

**Architecture:** each part is one task, built in the issue's order and committed with its tests
before the next, so a run that stops partway leaves the bug fixes done. New code goes into new
`lib/` files where an existing file would pass ~400 lines: `lib/canccu-lightreview.sh` (part 3),
`lib/canccu-pace.sh` (part 6), `lib/canccu-deep.sh` (parts 7–8), `lib/canccu-leadtools.sh`
(part 9), each sourced by `lib/canccu-common.sh` like the other parts. `lib/canccu-runs.sh` and
`lib/canccu-steps.sh` (exempt, split pending) get call sites only.

**Tech stack:** bash, jq, git ≥ 2.38 (`merge-tree --write-tree`), gh; the offline test harness
`tests/lib/harness.sh` (fake `gh`, fake worker, `CANCCU_NOW`).

**Spec:** issue #216 (`gh issue view 216`): its "Today", "Change", "Decided", acceptance criteria
and "Docs" sections. This plan adds only what the issue leaves open; where they differ, the issue
wins unless the product owner approves a line under "Decisions to approve" below.

## Global constraints

- Every new setting defaults to off: with the defaults, every existing test passes unchanged,
  except the pause checks of `tests/canccu-waits.sh` that part 2 moves under `--finish`.
- Every new key: its line in `lib/canccu-config.default`, its row in `lib/canccu-settings.tsv`
  (`<KEY> <type> <file> <locked>`, in the default file's order), its row in
  `docs/reference/config.md` (project) or `docs/reference/rules.md` (rules file).
- Log lines, prompt text, PR body lines, file names and state field names: word for word as the
  issue writes them.
- `STATE_FORMAT=3` with `state_migrate_3`; empty new fields mean today's behaviour.
- No edit of `docs/plan/`: `Roadmap note:` lines in the PR body (new settings for contracts §5,
  the pace `hold` feed line for §3, and any contract question below).
- About 400 lines per source file; tests use invented names only (AGENTS.md).
- While building: `tests/run <file>` for the files touched; `tests/run` in full once before the PR
  is marked ready.

## Decisions to approve (where the issue leaves a gap or the code adds a case)

1. **#214 and a conflict merge run.** `postpass_step` has a case the issue's "Today" does not
   name: head = `pass_sha` and `conflict_sha` = head (the worker's conflict merge pushed nothing)
   → needs-you. `passed_before` would swallow it and try to merge a conflicting PR. Plan: the
   reuse check is skipped when `conflict_sha` equals the head, so that needs-you keeps priority.
2. **Paused-start log once per pause.** `warn_once` logs again whenever its text changes, and the
   text names what was refused. Plan: `[ -e .warned-paused-start ] || warn_once paused-start …`,
   so the first refusal logs and later ones do not until `canccu-resume` removes the marker.
3. **The light review's durable upgrade.** A light pass rated `Risk: high` sets `review_asked=1`
   (the issue's field) instead of starting the full review directly: a refused start (no slot)
   is retried next pass and never merges on the light pass. `review_asked=1` also forces a
   non-light review (the needs-work `full review` line means a full one too). The light flag of
   the running review is kept like its effort and model: `reviews/<pr>.light` holds the sha.
4. **Light prompt wording around the kept parts.** The light checklist replaces the code-review
   sentence and `$crit`; then `Also run the security-review skill if it touches
   $SECURITY_REVIEW_WHEN. Check${REVIEW_EXTRA:+ $REVIEW_EXTRA and} the implementation choices
   listed under 'Decisions made:' in the PR body.` The closing sentence becomes `use the
   security-review skill as stated`. The test checks there is no `Run the code-review skill`
   (the checklist itself says `do not run the code-review skill`).
5. **D9 for `fixcheck_effort`.** Today it counts `reviewed..head` with no merge-tree step. To keep
   "with `0`, today's counts", it uses the shared helper only when
   `FIXCHECK_COUNT_RESOLVED=1`; `postpass_full` always uses it.
6. **Pace with an unknown reading.** Not ahead (no limit, as the issue says), but no transition
   either: `$CANCCU_HOME/pace` and the `hold` feed line stay until a fresh reading decides. A
   stale reading lifts the limit, so a run can refresh it: no deadlock.
7. **Snapshot kind and run type of the deep review.** The snapshot keeps kind `health` for any
   step run and `spend.log` gets run type `health` for it, unless `docs/plan/contracts.md` lists
   neither as fixed; then `deep`. Either way a `Roadmap note:` says which.
8. **Cadence round with no open checkpoint.** Skipped with a fixed-text `warn_once`, and
   `cadence_at` does not move: the round starts once a checkpoint is open again.
9. **Cadence and the step end.** Once every work issue is closed no new round starts; a round in
   progress finishes before the step's end (deep review, health, checkpoint) begins.
10. **`watch` reads whole lines only** (up to the last newline; the offset moves past them), and a
    `stall` line is a hit like a log line (it waits the settle).

## Review focus (failure modes no acceptance criterion pins)

- A conflict merge run that pushed nothing on a passed head → needs-you, not a merge (Task 1).
- A `changes` verdict reaped while paused → its fix run starts after `canccu-resume`, not lost
  (Task 2).
- A light pass with `Risk: high` whose full review is refused for a slot → no merge next pass;
  the full review starts once a slot is free (Task 3).
- `FIXCHECK_COUNT_RESOLVED=1` with a failing `merge-tree` → today's count, a full review at most
  (Task 4).
- An unknown usage reading while ahead → no limit, no "back on pace" line (Task 6).

---

### Task 1: #214, never review the same head twice

**Files:** modify `lib/canccu-norepeat.sh` (new `passed_before`), `lib/canccu-pipeline.sh`
(`check_pr`, `resume_step`), `lib/canccu-runs.sh` (`start_reviewer`: clear `review_asked`),
`lib/canccu-findings.sh` (`collect_nonblocking`), `lib/canccu-stateformat.sh`,
`docs/reference/reviews.md`, `docs/reference/state.md`. Tests: `tests/canccu-merge.sh`,
`tests/canccu-findings.sh`, `tests/canccu-engine.sh`.

**Interfaces — produces:** `passed_before <n> <pr> <sha>` (0/1); state fields `review_asked`
(`1` or empty), `nb_sha` (`<pr>:<sha>`); `STATE_FORMAT=3`, `state_migrate_3`.

- [ ] **Step 1: failing tests** in `tests/canccu-merge.sh`, each a `review_env` scenario:
  - `reuse-after-dequeue`: unit in needs-you after a merge-queue removal, `pass_sha=$HA`, label
    cleared, head `$HA` → `hasnt worker.log '--key review-50'`; dispatch.log has
    `#5 PR #50: head ${HA:0:7} passed review already; no new review (verdict reused)`; manual
    class → `st 5 phase` is `accept`; auto → `has gh.log "pr merge 50"`.
  - `reuse-after-fixcheck`: stage `fixcheck`, fix-check passed on `$HA`, same head → no second
    `--key review-50` run.
  - `reuse-from-log`: `pass_sha` empty, a `reviews.log` line `…\t50\t$HA\tfull\tpass\t…` →
    no review, the reuse log line.
  - `full-review-asked`: needs-work with a comment line `full review`, worker pushes nothing →
    exactly one `--key review-50` start of `$HA`, then `st 5 review_asked` is empty.
  - `conflict-run-no-push` (decision 1): `pass_sha=conflict_sha=$HA` → the existing needs-you
    text `the worker's merge run pushed no resolution`, no merge.
  - `tests/canccu-findings.sh`: `collect_nonblocking` twice for PR 50 / `$HA` with two different
    verdict times → one follow-up filed; log `non-blocking findings of ${HA:0:7} are filed already; not filed again`.
  - `tests/canccu-engine.sh`: a format-2 home with two units in flight → after a pass
    `state.format` is `3`, the units' state files are byte-identical, dispatch.log has
    `state format 2 → 3:`.
- [ ] **Step 2:** `tests/run merge findings engine` → the new checks FAIL, the old ones pass.
- [ ] **Step 3: implement.**
  - `passed_before`: `[ "$(st_get "$1" pass_sha)" = "$3" ]`, else an awk over
    `$CANCCU_HOME/reviews.log` for `$2 == pr && $3 == sha && $5 == "pass"`.
  - `check_pr`: after the `run_alive "review-$pr"` block, before `postpass_step`:
    `[ -z "$(st_get "$n" review_asked)" ] && [ "$(st_get "$n" conflict_sha)" != "$head" ] && passed_before "$n" "$pr" "$head"`
    → the log line, `after_pass "$n" "$pr" "$head" "earlier"`, `return`.
  - `resume_step`, needs-work branch: once `resume` succeeded and `full_review_asked "$c"`,
    `st_set "$n" review_asked=1` (`new_cycle` does not clear it).
  - `start_reviewer`: after a successful engine start of a non-fix-check review, `review_asked=`.
  - `collect_nonblocking`: after the `nb_at` check, `nb_sha` equal to `$2:$3` → the log line,
    `st_set nb_at="$5"`, return; else file as today and set both.
  - `STATE_FORMAT=3`; `state_migrate_3` echoes `new fields review_asked, nb_sha, plan_lines and
    step fields deep, deep_head, polish, round, round_phase, cadence_at; empty means today's
    behaviour: no unit changed`.
  - Docs: reviews.md (the reuse rule, the `full review` exception), state.md (format 3, fields).
- [ ] **Step 4:** `tests/run merge findings engine review waits dispatch` → PASS (the existing
  ones unchanged).
- [ ] **Step 5:** commit `#214: a head that passed is never reviewed again`; push.

### Task 2: #215, a pause holds every new run

**Files:** `bin/canccu-pause`, `bin/canccu-resume`, `bin/canccu-status`, `bin/canccu-dispatch`
(`pass()`), `lib/canccu-common.sh` (`pause_holds`), `lib/canccu-pipeline.sh` (`check_pr`),
`lib/canccu-merge.sh` (`postpass_step`), `lib/canccu-followup.sh` (`may_start`),
`lib/canccu-runs.sh` (`engine`); docs `docs/reference/pipeline.md`, `commands.md`,
`docs/upgrading.md`, `docs/hosts.md`. Tests: `tests/canccu-dispatch.sh`, `tests/canccu-waits.sh`,
`tests/canccu-engine.sh`.

**Interfaces — produces:** `pause_holds` (0 when `paused` exists and does not hold `finish`);
`canccu-pause [--finish]`.

- [ ] **Step 1: failing tests.**
  - dispatch: paused (plain), a `limited` unit past its back-off → no `resume` in worker.log;
    `canccu-resume`, next pass → resumed.
  - waits: paused (plain) → no review, fix-check, answer, fix run (`changes` verdict), plan-ok
    or needs-work run starts; a review already running that posts `pass` → `pr merge 50`. After
    `canccu-resume` the deferred fix run starts (review focus).
  - waits: the existing `… paused too` and `needs-you lifted …` checks run with
    `echo finish > "$CANCCU_HOME/paused"` (their texts unchanged otherwise).
  - engine: plain pause, `engine` called twice → return 1 both times, one
    `could not start … : the project is paused (canccu-resume to continue)` line, no
    `want_slot` entry for the unit.
  - status: `canccu-status` prints `PAUSED (canccu-resume to continue)` plain and
    `PAUSED, work in flight finishes (canccu-resume to continue)` with `--finish`.
- [ ] **Step 2:** `tests/run dispatch waits engine` → the new checks FAIL.
- [ ] **Step 3: implement.** `canccu-pause --finish` writes `finish` and logs
  `paused, work in flight finishes (canccu-pause --finish, project <p>)`; plain touches as today
  (an empty file: a hold). `pause_holds` next to `paused` in common.sh. `|| pause_holds` beside
  `backing_off` at: the `question)` start and step 4 in `pass()`, `check_pr`, `postpass_step`,
  `may_start`. `engine`: before the dry-run line, `pause_holds` → decision 2's log, `return 1`.
  `canccu-resume` also removes `.warned-paused-start`. `pass()`'s `paused` (step 3) stays as is.
  Docs: the pause holds every new run; `--finish` is today's meaning, used for host moves.
- [ ] **Step 4:** `tests/run dispatch waits engine merge followup` → PASS.
- [ ] **Step 5:** commit `#215: a pause holds every new run; --finish keeps the old meaning`; push.

### Task 3: D3, light review (`REVIEW_LIGHT`)

**Files:** create `lib/canccu-lightreview.sh`; modify `lib/canccu-runs.sh` (`start_reviewer`,
`review_prompt` 6th argument `light`), `lib/canccu-actions.sh` (`act_verdict` pass branch),
config files, `docs/reference/reviews.md`, `rules.md`. Tests: `tests/canccu-review-effort.sh`,
`tests/canccu-review.sh`.

**Interfaces — produces:** `review_light_class <pr> <K>` → prints the risk (`low|normal`) and
returns 0 when the full review is light; `LIGHT_REVIEW_TEXT` (the issue's checklist, word for
word, `$HIGH_RISK_TEXT` substituted at use); `light_upgrade <n> <pr> <head> <pr_detail json>` →
0 when it set `review_asked=1` (the caller returns without `after_pass`). Consumes
`review_asked` (Task 1).

- [ ] **Step 1: failing tests.**
  - review-effort: `REVIEW_LIGHT=1`, a `normal` package → `review_light_class` 0 and the started
    reviewer has `RUN_EFFORT_NOTE=low`; log `PR #50: light review (REVIEW_LIGHT=1, normal risk, low effort)`.
    Not light: a `high` package, a gated path, an agent-config path, the health pass, a
    single issue (fast lane), and `REVIEW_LIGHT=0`.
  - review: the light prompt contains the checklist from `This is a light review:` to
    `makes your Risk: line high.` word for word, the security-review sentence, `Decisions made:`,
    the no-repeat sentence; it does not contain `Run the code-review skill`.
  - review: a light pass with `Risk: high — …` → log
    `#5 PR #50: the light review rated it high risk; full review of ${HA:0:7}`, one more
    `--key review-50` on `$HA` without the light text; its pass → merge or accept, no third review.
  - review: the same with the second start refused (`TOTAL_CAP` full) → no merge that pass or the
    next; the full review starts once a slot frees (review focus).
  - `reviews.log` kind is `full` for the light review.
- [ ] **Step 2:** `tests/run review-effort review` → FAIL.
- [ ] **Step 3: implement.** `review_light_class`: `REVIEW_LIGHT=1`, `review_asked` empty, state
  `pkg` set and not a step run (`is_health`; `is_deep` once Task 7 lands), `effective_risk` low or
  normal, no PR path matching `gated_re`. `start_reviewer` (non-fix-check): light → effort
  `$(effort_cap low)`, the log line, `echo "$sha" > reviews/<pr>.light`; otherwise
  `rm -f reviews/<pr>.light`. `review_prompt … light` builds decision 4's text. `act_verdict`
  pass branch, before `st_set pass_sha`: `light_upgrade` when `reviews/<pr>.light` holds the
  head and `review_risk_of "$j"` is `high`. Setting `REVIEW_LIGHT=0` (rules, `enum:0|1`, locked).
  Docs: reviews.md (light review, high-risk upgrade), rules.md row.
- [ ] **Step 4:** `tests/run review-effort review review2 config docs` → PASS.
- [ ] **Step 5:** commit `D3: REVIEW_LIGHT, a light review for low and normal packages`; push.

### Task 4: D9, count only the resolved lines (`FIXCHECK_COUNT_RESOLVED`)

**Files:** `lib/canccu-merge.sh` (`count_from`, `postpass_full`), `lib/canccu-runs.sh`
(`fixcheck_effort`), config files, `docs/reference/merging.md` or `reviews.md` (where
`FIXCHECK_COUNT_MAIN` is documented). Tests: `tests/canccu-merge.sh`,
`tests/canccu-review-effort.sh`.

**Interfaces — produces:** `count_from <base> <head>` → the commit or tree to count from
(`base` when nothing applies).

- [ ] **Step 1: failing tests** on a real git fixture: base, main gains 500 lines in a PR file
  conflicting with the PR, the merge commit resolves 10 lines.
  `FIXCHECK_COUNT_RESOLVED=1`: `postpass_full` prints nothing (≈10 lines, fix-check) and
  `fixcheck_effort` says `low`; `0`: today's output (`… over FIXCHECK_FULL_LINES=100`).
  A `FIXCHECK_RISKY` path changed only by main → no full review with `1`. A git shim whose
  `merge-tree` fails → today's count (review focus).
- [ ] **Step 2:** `tests/run merge review-effort` → FAIL.
- [ ] **Step 3: implement** `count_from`: the `postpass_full` logic moved out; when
  `merge-tree --write-tree base mb` exits 1, `FIXCHECK_COUNT_RESOLVED=1` and its first line is a
  full object id, that line is the start; any other failure → `base`. `fixcheck_effort` uses it
  only with `FIXCHECK_COUNT_RESOLVED=1` (decision 5). Setting (project, `enum:0|1`, locked, after
  `FIXCHECK_COUNT_MAIN`).
- [ ] **Step 4:** `tests/run merge review-effort config docs` → PASS.
- [ ] **Step 5:** commit `D9: FIXCHECK_COUNT_RESOLVED counts a conflicting main merge's resolved lines only`; push.

### Task 5: D10, budgets by size (`BUDGET_LINES`)

**Files:** `lib/canccu-units.sh` (`budget_factor`), the three `pkg_budget` callers
(`lib/canccu-packages.sh`, `lib/canccu-actions.sh`, `lib/canccu-runs.sh`),
`lib/canccu-planner.sh` (`PLAN_SCHEMA`, prompt), `lib/canccu-plan.jq`, `lib/canccu-packages.sh`
(`start_package` reads `.lines`), config files, `docs/reference/packages.md`. Tests:
`tests/canccu-units.sh`, `tests/canccu-steps.sh`.

**Interfaces — produces:** `budget_factor <K>` → integer; state field `plan_lines`.

- [ ] **Step 1: failing tests.** units: `BUDGET_LINES=500`, one issue, `plan_lines=2000` →
  factor 4, and `pkg_budget "$BUDGET_WORK" 4` capped by `BUDGET_PACKAGE_MAX`; `BUDGET_LINES=0`
  or no `plan_lines` → the issue count. steps: a plan with `"lines": 800` validates;
  `"lines": 0` and `"lines": "800"` are rejected; with `BUDGET_LINES=500` the planner prompt has
  `Give each package "lines": your estimate of its changed lines.`, with `0` it does not.
- [ ] **Step 2:** `tests/run units steps` → FAIL.
- [ ] **Step 3: implement.** `budget_factor`: `unit_size`, raised to `ceil(plan_lines / N)` when
  `N=BUDGET_LINES > 0` and `plan_lines` is an integer ≥ 1. Callers pass `budget_factor` where
  they pass `unit_size` today. Schema: optional `"lines":{"type":"integer","minimum":1}`;
  plan.jq rejects a present `lines` that is not an integer ≥ 1. `start_package` gets the plan's
  `.lines` as a 6th argument, read like `risk_reason`. Setting (project, `int:0:100000`, open).
- [ ] **Step 4:** `tests/run units steps steps2 config docs` → PASS.
- [ ] **Step 5:** commit `D10: BUDGET_LINES, a package's budget by its planned lines`; push.

### Task 6: D6, pace control (`PACE`)

**Files:** create `lib/canccu-pace.sh`; modify `lib/canccu-usage.sh` (`usage_cap`,
`draining`), `bin/canccu-dispatch` (`pass()` calls `pace_tick`; `digest` section), config files,
`docs/reference/usage.md`, `state.md`. Tests: `tests/canccu-usage.sh`, `tests/canccu-dispatch.sh`.

**Interfaces — produces:** `pace_read` → `<weekly %> <gone %> <points ahead>` or nothing when
unknown; `pace_ahead` (0/1); `pace_tick` (transitions, logs, feed); `pace_digest` (the section
text or nothing); `pace_report` (used by Task 9).

- [ ] **Step 1: failing tests** with a `usage.json` fixture and `CANCCU_NOW`: weekly 60 %, reset
  4 days ahead (3 of 7 days gone, 43 %), `PACE=cap` → `usage_cap` 1, the ahead log line once over
  two passes with effect `at most 1 run(s) at once over all projects`; weekly 45 % →
  `TOTAL_CAP` and `pace: back on pace (weekly 45%, 43% of the week gone); PACE=cap no longer limits runs`
  once. `PACE=pause` ahead → `draining` true, a `hold` feed line (`info`) `pace: weekly usage 60% is ahead of the week; nothing new starts until it is back on pace`,
  then its closed line when back. `notify` → no limit, effect `notice only`. A stale reading
  while ahead → no limit, no back-on-pace line (decision 6). dispatch: the digest has
  `**Pace:**` with `PACE=cap`, not with `off`.
- [ ] **Step 2:** `tests/run usage dispatch` → FAIL.
- [ ] **Step 3: implement.** `gone = round(100 × (now − (reset − 604800)) / 604800)`, clamped to
  0–100, from `USAGE_NOW`'s weekly share and reset; ahead when `weekly − gone > PACE_MARGIN`.
  `usage_cap`: with `PACE=cap` and ahead, at most `PACE_CAP`. `draining`: also true with
  `PACE=pause` and ahead. `$CANCCU_HOME/pace` holds `since=<epoch>` while ahead. The feed key is
  `hold-pace`, settled with the state word `lib/canccu-holds.sh` uses. Digest:
  `**Pace:** on pace` or `ahead by <d> points since <ISO> (PACE=<mode>)`, then
  `; weekly <w>%, <g>% of the week gone`. Settings (project, open): `PACE`
  `enum:off|notify|cap|pause`, `PACE_MARGIN` `int:0:100`, `PACE_CAP` `int:1:20`. Never writes
  `CAP` or `TOTAL_CAP`.
- [ ] **Step 4:** `tests/run usage dispatch dispatch2 config docs` → PASS.
- [ ] **Step 5:** commit `D6: PACE, weekly pacing against the time gone`; push.

### Task 7: D4, step deep review, polish and step tag

**Files:** create `lib/canccu-deep.sh`, `tests/canccu-deep.sh`; modify `lib/canccu-steps.sh`
(`STEP_JQ` pending phases, `step_tick`, `checkpoint_tick`, `checkpoint_summary`,
`step_unit_finished`), `lib/canccu-units.sh` (`is_deep`, `is_step_run`), the `is_health` sites
below, config files, `docs/reference/steps.md`, `state.md`.

**Interfaces — produces:** `is_deep <K>`, `is_step_run <K>` (health or deep); `step_n <m>` (the
title's leading number, else `m`); `deep_due <m>`; `start_deep <m> [base]`; `deep_prompt <m> <K>
<base>`; `deep_merged <m> <pr>`, `deep_closed <m> <pr>`; `step_tag_name <m> [suffix]`;
`step_tag <m> <name>`. Step fields `deep` (empty|running|merged|closed), `deep_head`, `polish`.

- [ ] **Step 1: failing tests** in `tests/canccu-deep.sh` (step 12, title `4 Search`):
  - `STEP_DEEP_REVIEW=1`, all work closed → `--key pkg-12-deep` started, not `pkg-12-health`;
    step phase `deep`; the step stays current; log `#pkg-12-deep started: the deep review of step 4 Search`.
  - the prompt names the newest `step-*` tag as base, `deep_head` (origin/main's sha), the
    follow-up issues (`followups` keys `step-12-*`), and `docs/reports/step-4-deep-review.md`.
  - merged report with 2 blocking items → one `issue create` with `--milestone`, `--label ready`,
    title `Step 4 Search: polish (deep review)`; fields `deep=merged polish=<i>`; phase `idle`;
    after the polish issue closes → `pkg-12-health` starts. 0 blocking → health starts at once.
    PR closed unmerged → `deep=closed`, health follows.
  - `checkpoint_summary` has `**Deep review:** PR #<pr>, 2 blocking (polish #<i>)` only with
    `STEP_DEEP_REVIEW=1`.
  - `checkpoint-ok` with `STEP_TAG='step-{n}'` → one `git tag step-4` and one push; a second
    run with the tag present → `tag step-4 exists already; not moved`; empty `STEP_TAG` → no
    `git tag` call (a logging git shim); `STEP_TAG='bad..{n}'` → no tag, one warning.
- [ ] **Step 2:** `tests/run deep` → FAIL.
- [ ] **Step 3: implement.**
  - `step_tick`: `if health_due "$m"; then if deep_due "$m"; then start_deep "$m"; else start_health "$m"; fi`;
    phase `deep` joins `STEP_JQ`'s pending list; `deep_due`: `STEP_DEEP_REVIEW=1` and field
    `deep` empty.
  - `start_deep`, modelled on `start_health`: unit `pkg-<m>-deep`, state `pkg=deep deep=1
    risk=low risk_reason="the step's deep-review report" members= exclusive=0`, `--fresh`,
    `BUDGET_DEEP_REVIEW`, `step_key`; step `phase=deep deep=running deep_head=<sha>`.
    `run_worker`: a deep unit runs on `DEEP_REVIEW_MODEL`, else `REVIEW_MODEL`, else `MODEL`,
    effort `run_effort DEEP_REVIEW_EFFORT`.
  - `deep_prompt`: the issue's part 7.3, its PR body lines word for word.
  - `step_unit_finished`: a deep unit → `deep_merged`/`deep_closed` (not the packages file).
    `deep_merged` reads `git show origin/main:docs/reports/step-<n>-deep-review.md` after a
    fetch and counts `blocking_of`'s list items; a missing report → `warn_once`, retried from
    the `deep)` case of `step_tick`. Logs as the issue writes them.
  - `is_health` sites → `is_step_run` where both apply: `units.sh` (lead, label `deep#<m>`,
    name), `findings.sh` (follow-up key `step-<m>-deep`), `snapshot.sh` (decision 7),
    `pipeline.sh:181` (PR gone), `merge.sh:12` (`pr_gone`), `github.sh` (`effective_risk`: a deep
    unit is `low`), `planner.sh:139`, `runs.sh` (`pr_what`, review crit: the report's sections
    and block), `aftermerge.sh:141`, `steps.sh:273`. `health_nothing` and the health checklist
    stay health only.
  - Step tag after `step_done "$m" "checkpoint #$c OK"`: `step_tag_name` substitutes `{n}`; no
    `{n}` or `git check-ref-format "refs/tags/<t>"` failing → `warn_once`; `step_tag` fetches
    with tags, never moves an existing tag, tags `origin/main` and pushes with `mut git … push`
    as `main_merge` does; the three log lines of 7.6.
  - Settings (project): `STEP_DEEP_REVIEW` `enum:0|1` open, `DEEP_REVIEW_MODEL` `name` open,
    `DEEP_REVIEW_EFFORT=high` `enum:low|medium|high|xhigh|max` open, `BUDGET_DEEP_REVIEW="150 40 120"`
    `budget` open, `STEP_TAG=''` `text` locked.
- [ ] **Step 4:** `tests/run deep steps steps2 health-review snapshot2 units findings config docs` → PASS.
- [ ] **Step 5:** commit `D4: STEP_DEEP_REVIEW, the step's deep review, polish issue and STEP_TAG`; push.

### Task 8: D8, cadence mode (`CADENCE_DAYS`)

**Files:** `lib/canccu-deep.sh` (`is_cadence`, `cadence_tick`), `lib/canccu-steps.sh`
(`step_tick` calls `cadence_tick`; `health_due` waits for a round, decision 9), config files,
`docs/reference/steps.md`, `state.md`. Tests: `tests/canccu-deep.sh`.

**Interfaces — consumes:** `start_deep <m> <base>`, `deep_merged`, `step_tag_name <m> -r<r>`,
`step_tag` (Task 7). Produces step fields `round`, `round_phase` (`deep|polish|checkpoint`),
`cadence_at`.

- [ ] **Step 1: failing tests.** A milestone description with `cadence: ON`, `CADENCE_DAYS=14`,
  step running: day 13 → no round; day 14 → log `step 4 Search: cadence round 1 starts (every 14 days)`,
  the deep review starts with the step's PRs as base; a package of the next wave still starts.
  Report with no blocking → summary on the open checkpoint, `needs-you`, feed kind `checkpoint`.
  `checkpoint-ok` by `octo` → label and `needs-you` removed, checkpoint open, comment
  `Cadence round 1 OK.`, tag `step-4-r1`, `cadence_at=now`; day 27 → no round, day 28 → round 2
  with round 1's `deep_head` as base. No open checkpoint → skipped, one warning (decision 8).
  `CADENCE_DAYS=0` → a normal step.
- [ ] **Step 2:** `tests/run deep` → FAIL.
- [ ] **Step 3: implement.** `is_cadence`: `CADENCE_DAYS > 0` and a description line matching
  `^[[:space:]]*cadence:[[:space:]]*on[[:space:]]*$` (any case) in `MILESTONES`. `cadence_tick`
  runs for phases `running|idle` when no work-closed end is due: starts a round when due, moves
  `round_phase` deep → polish (while the polish issue is open) → checkpoint, and ends it on
  `checkpoint-ok` (`label_by_user` after `checkpoint_at`) or a close. Without
  `STEP_DEEP_REVIEW=1` a round is its checkpoint only. Setting `CADENCE_DAYS=0` (project,
  `int:0:365`, open).
- [ ] **Step 4:** `tests/run deep steps steps2 config docs` → PASS.
- [ ] **Step 5:** commit `D8: CADENCE_DAYS, cadence rounds on a long-running step`; push.

### Task 9: D5, lead toolkit

**Files:** create `lib/canccu-leadtools.sh`; modify `bin/canccu-dispatcher` (subcommands and the
usage text's line range), `bin/canccu-status` (`--pace`), `lib/canccu-feed.sh` (factor the
heartbeat check out of `feed_wait` as `heartbeat_stale` → message or nothing),
`docs/reference/lead.md`, `commands.md`, `state.md`. Tests: `tests/canccu-feed.sh`,
`tests/canccu-usage.sh`.

**Interfaces — produces:** `lead_watch <settle> <match> <file>...` (exit 0, 3 on a stale
heartbeat); `lead_stall` (prints lines, exit 0); consumes `pace_report` (Task 6).

- [ ] **Step 1: failing tests** (`CANCCU_WAIT_EVERY` small, `--settle` short):
  - watch: first run prints no old line; an appended `awaiting accept` line exits 0 after the
    settle; a `--file` line exits at once; a second run starts at the saved offsets; a truncated
    file restarts at 0; a stale heartbeat exits 3.
  - stall: a conflicting PR by `USER_LOGIN`, a CI run in progress 61 min, `dispatch.log` silent
    3 h 1 min with a running step → one line each; a run 1 h later prints none; 3 h later all
    three again.
  - usage: `canccu-status --pace` from a fixture prints the weekly line, the `PACE=` line, and
    `spend of this project's runs, last 7 days (UTC), newest first:` with per-day lines; no
    reading → `weekly usage unknown (no fresh reading)`.
- [ ] **Step 2:** `tests/run feed usage` → FAIL.
- [ ] **Step 3: implement** per the issue's part 9; offsets in `<home>/watch.offsets`
  (`<path>\t<bytes>`), seen keys in `<home>/stall.seen` (`pr-<n>`, `ci-<id>`, `log`, with the
  epoch); decision 10; a gh error skips that stall kind.
- [ ] **Step 4:** `tests/run feed usage config docs` → PASS.
- [ ] **Step 5:** commit `D5: canccu-dispatcher watch and stall, canccu-status --pace`; push.

### Task 10: D7 docs and the settings check

**Files:** create `docs/kickoff.md`, `docs/gates.md`; modify `docs/README.md`. Tests:
`tests/canccu-docs.sh`, `tests/canccu-config.sh`.

- [ ] **Step 1: failing tests.** docs: both files exist, carry the SPDX line and are linked from
  `docs/README.md`. config: `config set` rejects `PACE=fast`, `PACE_MARGIN=-1`,
  `BUDGET_LINES=x`, `CADENCE_DAYS=x`, `DEEP_REVIEW_EFFORT=extreme`; refuses the locked
  `REVIEW_LIGHT`, `FIXCHECK_COUNT_RESOLVED` and `STEP_TAG` for an actor other than the product
  owner (`refused: <KEY> is locked; only the product owner changes it`).
- [ ] **Step 2:** `tests/run docs config` → FAIL.
- [ ] **Step 3:** write `docs/kickoff.md` (the template's headings and question bank of 10.1)
  and `docs/gates.md` (the catalogue of 10.2), link both.
- [ ] **Step 4:** `tests/run docs config` → PASS; then `tests/run` in full once → PASS.
- [ ] **Step 5:** commit `D7: docs/kickoff.md and docs/gates.md`; push; mark the PR ready with
  `Closes #216`, `Closes #214`, `Closes #215` and the `Roadmap note:` lines.
