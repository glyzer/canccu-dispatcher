<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Step 3 Parallel tracks: deep review

Reviewed at origin/main 9a3e02c3c1a1ee775a733bb7cc1e079a94fb185f. The scope was the step's merged
PRs, #81 (#75, #72) and #85 (#82, #73, #26), and the code they added as it stands at that head
(later steps reshaped much of it). The step filed no follow-up issues. PR #85's two `Follow-up:`
lines were never filed, so they appear below.

## Architecture

- **Run settings and the spend log** (#81: lib/canccu-spend.sh, libexec/canccu-worker `spend_line`,
  lib/canccu-runs.sh `run_worker`/`tmux_env`):
  - The settings reach the engine as `WORKER_*` variables, so the engine's arguments did not
    change. `run_effort` keeps a mistyped `HEALTH_EFFORT` from failing every health run.
  - The engine writes the line and the dispatcher fills in column 15 later (`spend_note`). The
    split is sound.
  - The cost is that every note rewrites the whole `spend.log`, which all projects share and
    which grows forever. The rewrite and the append share `.spend.lock`, but the append gives up
    on the lock after 2 s and writes anyway. A line appended while a rewrite holds the lock is
    lost when the rewrite's `mv` lands (Non-blocking 4).
  - `spend_report` joins `merged.log` (the unit key, as `unit_merged` writes it) with the unit's
    own lines, `review-<pr>` and `answer-<unit>`, up to the merge time. A plan PR writes no
    `merged.log` line, so no run is counted twice.
- **The usage-limit handoff** (#82: lib/canccu-followup.sh `handoff_keep`/`limited_task`,
  lib/canccu-pipeline.sh):
  - A nudged run that ends `done` keeps its final message in `handoffs/<K>.md` and clears
    `no_pr`, so the fresh session gets the handoff, not the whole task again.
  - A hard stop removes any stale handoff. The file goes once the fresh run has started.
  - `RESUME_ON=limited` brings back the old resume.
  - One gap: a nudged run whose turn ends with background work pending is classed `background`.
    That path ignores `nudged`, so it goes to `check`, not `limited`, and its handoff is not kept
    (Non-blocking 3).
- **Non-blocking findings** (#73: lib/canccu-findings.sh):
  - `collect_nonblocking` files each verdict once (`nb_at`), and the fix run gets only
    `blocking_of`.
  - Later steps moved this to one ticket per step and to the §8 block, through `review_valid` /
    `_review_awk`. `nonblocking_of` and `blocking_of` follow that block.
  - `findings_report` was not updated for it (Blocking 1).
- **Stalls and background work** (#26: lib/canccu-engine.sh `tool_ticks`/`tools_busy`,
  lib/canccu-stream.py, tests/run):
  - The watchdog's pid is the process substitution that execs `timeout`, so the first `timeout`
    in `tree_pids` is the engine's own and its child is `claude`. A worker's own `timeout` is
    never taken by mistake.
  - The stream reader's `timeout` (`guard`) is not under that pid either.
  - `finish_once` runs once per PR-less stretch (`finish_tried`, cleared in `check_pr` once a PR
    appears).
  - The heartbeat in tests/run exits with the run and reads only its own `.running-$$` marks.
  - Background launches are tracked by a heuristic over Claude Code's result texts (Non-blocking 5).

## Security

- No credential reaches the new paths. `spend_line` and `spend_note` write only values the
  dispatcher made (numbers, `k=v` with fixed keys, `answer=` from `ANSWERED|ESCALATE`).
- `handoffs/<K>.md` is named after the unit key. Package names are held to `^[a-z0-9]+(-[a-z0-9]+)*$`
  by `PLAN_SCHEMA`, so the key cannot leave the directory. The handoff is the worker's own text,
  sent back to the same unit's next run at the same trust level.
- The non-blocking findings go to a public issue through `home_tilde`, as the review comment they
  come from already did. The issue is not labelled `ready`, so it never enters the queue
  unreviewed.
- `followups` is read as a number into `jq --argjson`. A corrupt value makes jq fail, which only
  creates a new issue.
- The stall detector only reads `/proc/<pid>/stat` and `comm` of the run's own tree.
- Nothing found.

## Contracts

- The spend-log columns (docs/reference/state.md:112-123) match `spend_line`. Readers take both
  15- and 16-column lines.
- One run type is wrong: a fix-check's file retry is logged as `review`, not `fix-check`
  (Pre-existing 1). That line came after this step.
- `HEALTH_MODEL`, `HEALTH_EFFORT` and `USAGE_WINDOW_DELTA` have their rows
  (docs/reference/config-steps.md:32-42) and their defaults in lib/canccu-config.default.
- `FINDINGS_TOP`, which docs/reference/reviews.md:46 names, has neither (Non-blocking 2).
- The nudge text (libexec/canccu-nudge-hook) matches docs/reference/usage.md:65-75. So do the
  handoff order (Done, Left, Next step, Decisions made, Test state, Head) and the status
  `error: ended with background work pending` (docs/reference/engine.md).
- State.md column 13–14 says the "after" share is `-` "when the run's own stream reported no
  reading". `window_now` takes any reading in the shared `usage.json` newer than the run's start,
  whichever run's stream wrote it (Non-blocking 6). This is harmless under the documented "one
  run at a time".
- Issue #26's third criterion was replaced by the agreed scope change in the issue's last
  comment (foreground tests only, no background work, stop at PR ready). `RUN_RULES` follows it.
  The repo templates and this repo's own CLAUDE.md still describe the old flow (Non-blocking 1).

## Test quality

- tests/canccu-spend.sh covers each acceptance line of #75 and #72:
  - `HEALTH_MODEL`/`HEALTH_EFFORT` set, unset and invalid;
  - `--effort` on claude's arguments;
  - every column, including the old four;
  - the window on and off;
  - the outcome note: replace, add, an old line, a hand-written line;
  - the report.
- tests/canccu-usage.sh and tests/canccu-dispatch.sh check that the limited restart is `--fresh`,
  carries the handoff, the commit log and the diff stat, and that a hard stop has no handoff.
- tests/canccu-engine.sh's stall pair tells a CPU-spending tool from an idle one. The
  background-work tests cover a Bash launch, an Agent launch, a poll that still runs and a
  completion notification.
- **Weakness:** the `--findings` tests (tests/canccu-findings.sh:180-191) build their review
  records in the pre-§8 free form (`- src/a.ts:8 comment restates the code`). They pass while the
  report fails on every record a reviewer writes today, `- [<class>] <file>:<line> — <what>`
  (Blocking 1).
- **Weakness:** the background fixtures copy the texts the heuristic expects ("with ID:",
  "agentId:"). Only real stream captures would catch a change in Claude Code's wording.
- **No test** covers a nudged run whose turn ends with background work pending.
- No skipped or weakened checks were found. The four tests changed in tests/canccu-pane.sh and
  tests/canccu-dispatch.sh were tightened to the new formats, not loosened.

Blocking:
1. [correctness] lib/canccu-findings.sh:202 — `canccu-status --findings` counts each finding of a §8 review file as its class tag, not as the finding
   Evidence: two review records with `1. [correctness] src/a.sh:10 — the loop never ends on empty input` and `1. [correctness] src/b.sh:4 — a missing quote splits the path` (plus one `- [docs] …` each) give `2× [correctness] (#50, #51)` and `2× [docs] (#50, #51)`: the file:line ref is cut out, the `[class]` tag is left first, and the cut at the first ` —` keeps only the tag; #73's criterion is "a report of the most common findings"
   Fix: drop a leading `[<class>]` tag (`sub(/^\[[[:alnum:]-]+\][[:space:]]*/, "", l)`) before the separator cut, so the gist is the finding's text, and add a `--findings` test whose records use the §8 block
Non-blocking:
- [docs] templates/repo/CLAUDE.snippet.md:54 — still "Watch CI … Red after two fix rounds: stop", and templates/repo/AGENTS.snippet.md:23 and CLAUDE.md:41 still say to run the full suite before pushing or watch CI; the worker prompt (#26) says the opposite; PR #85's Follow-up line was never filed
- [docs] lib/canccu-findings.sh:207 — `FINDINGS_TOP` has no row in the config reference and no default in lib/canccu-config.default (AGENTS.md, Docs); a non-numeric value makes `head -n` fail and the list print empty
- [other] lib/canccu-pipeline.sh:55 — a nudged run that ends with background work pending goes to `check`, not `limited`: its handoff is not kept, and a finish run sees only the last 12 lines of `.last`
- [other] libexec/canccu-worker:100 — after 2 s without the lock `spend_line` appends anyway; a `spend_note` rewrite holding the lock then `mv`s its copy over the file and that line is lost, against the comment's "must not cost the line"
- [test-gap] lib/canccu-stream.py:101 — when no task id matches, the pending key is the tool_use_id, cleared only if a later event quotes it; the heuristic is tested only against texts written to match it (PR #85's second Follow-up, never filed)
- [docs] libexec/canccu-worker:75 — `window_now` reads the shared `usage.json`, so the "after" share can come from another run's stream; the comment and docs/reference/state.md:121 say "this run's own"
- [docs] docs/reference/usage.md:52 — "the engine never keeps their session id": `retry_review_file` runs a reviewer with `--keep-session`
Pre-existing:
- [contract] lib/canccu-runs.sh:592 — `retry_review_file` sets `RUN_TYPE=review` for a fix-check's retry too; docs/reference/state.md:116 names its type `fix-check`
Risk: low — a report only; no code changed
Findings: 1 blocking, 7 non-blocking, 1 pre-existing
Review verdict: changes 9a3e02c3c1a1ee775a733bb7cc1e079a94fb185f
