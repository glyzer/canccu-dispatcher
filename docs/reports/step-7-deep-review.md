<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Step 7 Token cost: the rest: deep review

Reviewed at origin/main ca5e6b9928c676fc12bcc7cbc62c6836a378cc12, against tag `step-4`. The range
also holds steps 5 and 6, which their own deep reviews covered (docs/reports/step-5-deep-review.md,
docs/reports/step-6-deep-review.md). This review looks mostly at step 7's PRs: #342 (the fix-budget
count readers), #343 (package ci-digest-merge-models: #327 the CI failure digest, #332
release-reds and flaky checks, #329 the narrow runs' models, #331 the scripted merge after a
contract PR) and #346 (package review-build-prepush). The findings already in follow-up #345 are
not reported again.

## Architecture

- **One digest for two callers.** `ci_digest_jobs` (lib/canccu-cidigest.sh) builds the failure
  digest once, and both the red-CI fix prompt (`ci_digest`) and the release-red comments and
  flaky issues (lib/canccu-releasered.sh) use it. That is the right seam. But the cleaning step
  (`ci_log_clean`) is shared by the digest and its fallback tail. So the noise filter decides what
  the "tail as before" holds too, and a log that is mostly compose output loses everything
  (blocking 1).
- **Release-reds run on script only.** `release_red_tick` runs before the queue is read, starts no
  AI run, and keeps its state in its own `release-red/<n>` kv file, apart from the unit state. The
  only link to the queue is `release_red_held` in `candidates`. The flow is easy to follow: start,
  then rerun, then judge, then closed or ordinary. A retried close keeps `rr_filed` and `rr_said`,
  so no check is counted twice.
- **The model choice for a run is made in `resume()`**, with the user's override passed in as a
  prefix assignment (`LEAD_MODEL=… resume`). This is dynamic scope: each call site must remember
  to set it. Two needs-work call sites do not (blocking 2). An argument, or one wrapper that reads
  the comment's model line for every user-driven resume, would close this gap.
- **contract_resume** (#331) reads "the work is finished" from the run's last report line
  (`Package work: done`). The prompt (`contract_rule`) asks for that line, so worker and script
  share one format. When the line is missing, the work counts as unfinished: the safe side.
- #346's context pack runs inside the build's window and slot, so the state machine still sees one
  run. Its pre-push hook lives in the worktree's own config. Both fit the engine's existing seams.

## Security

- The release-red flow posts CI log lines (the digest) to GitHub issues inside fenced code
  blocks. The logs come from the project's own CI on `BASE_BRANCH`, where GitHub masks secrets.
  `home_tilde` covers the comments of the release-red; the flaky issue's comment goes through it
  too.
- A `flaky: <check>` issue is found by its title alone, among all open issues, whoever opened
  them. The failure count is read from that issue's body, and the dispatcher then overwrites the
  body and may add `ready`. So a stranger's issue with that title and `Failures: 9` in its body
  is released as work after one flaky failure, skipping `FLAKY_FILE_AFTER`. The `ready` gate is
  normally the product owner's or the dispatcher's own (non-blocking below). The harm is limited:
  the body is replaced by the dispatcher's text, and anyone can already comment on the
  dispatcher's own flaky issue.
- The `model: <id>` override takes only a config-name charset, and only from the user comments
  `user_comments` returns, so no shell text or flag can be injected through it.
- #346's guard and pre-push gaps are already in #345.

## Contracts

- New keys (`CI_DIGEST_PATTERN`, `CI_DIGEST_LINES`, `RELEASE_RED_LABEL`, `CI_INFRA_PATTERN`,
  `FLAKY_FILE_AFTER`, `MERGE_MODEL`, `ANSWER_MODEL`, `CONTEXT_PACK_MODEL`, `BUDGET_PACK`,
  `PRE_PUSH_CMD`, `PRE_PUSH_MAX_SEC`) each have a row in docs/reference/config-runs.md or
  config-steps.md, a line in lib/canccu-config.default and a type in lib/canccu-settings.tsv. The
  defaults match the issues: `CI_DIGEST_LINES=120`, `RELEASE_RED_LABEL=release-red`,
  `FLAKY_FILE_AFTER=2`, and `ANSWER_MODEL` empty, which means `MODEL`.
- The issue titles `release red at <sha7>` and `flaky: <check>` and the `Failures: <n>` line are
  used as #332 and docs/reference/release-reds.md write them.
- docs/reference/config-runs.md:34 says that a model line in a `needs-work` comment runs that
  follow-up on that model. The code honours it only on the plain needs-work path, not on the owed
  round or the fix-check's extra round (blocking 2).
- spend.log keeps its types for #329's routing (a user's follow-up on FIX_MODEL is still `build`).
  #333 adds a type `pack`, which docs/reference/usage.md lists.
- docs/plan/contracts.md fixes no name this step touches. The feed kinds in the diff (`handover`)
  are in §3.

## Test quality

- tests/canccu-cidigest.sh checks the four fixtures #327 asks for, two jobs under their names,
  the cap and the no-match tail. Each check names the exact lines it expects, so each would fail
  if the behaviour broke. No fixture has the failing runner's own output under a compose prefix
  (`e2e-1  | FAIL …`). That is the layout the issue's own VM reports, and the one that breaks
  (blocking 1).
- tests/canccu-releasered.sh covers each #332 criterion against a fake gh, including the
  once-across-passes rerun and a failed close retried without a double count. The flaky
  comment's digest is checked with a single job only, so the header prefix match is never
  exercised (blocking 3).
- tests/canccu-models.sh covers the follow-up routing per `ny_stage`, the `opus` and
  `model: <id>` lines on a comment, a sentence that is no model line, `MERGE_MODEL` with its
  fallbacks, `ANSWER_MODEL`, and #331's done, unfinished, no-line and conflict cases. The override
  is never tested on a `needs-work` comment, the path the docs name too.
- tests/canccu-merge.sh changes the expected values of the older #216 FIXCHECK_COUNT_RESOLVED
  checks to the #336 behaviour, with that issue cited, and adds a gated-path case for the
  resolution. This is a stated behaviour change, not a weakened test.
- tests/canccu-docs.sh now reads config-runs.md as part of the reference. The check is just as
  strict as before.

Blocking:
1. [correctness] lib/canccu-cidigest.sh:79 — the "tail as before" fallback is cut from the noise-filtered log, so a job whose failing runner prints under a compose prefix gets no digest and no tail
   Evidence: a job log whose lines are `e2e\tRun\t2030-…Z e2e-1  |  FAIL  e2e/checkout.spec.ts > pays`, `e2e-1  | AssertionError: expected 200, got 500` and `e2e-1  | Tests  1 failed (1)`. `ci_log_clean` drops every line (CI_DIGEST_NOISE `^[A-Za-z0-9_.-]+-[0-9]+ +\| `), so `[ -n "$log" ] || continue` skips the job. With no other failing job, the fix run gets only "Read the failing checks with gh pr checks …", while the old `ci_log_tail` gave it these lines. #327: "fall back to today's tail when nothing matches".
   Fix: keep the raw log (with only the columns, timestamps, ANSI codes and CRs stripped) and take the fallback tail from it, not from the noise-filtered text, when the filtered log is empty or has no match. Add a fixture whose failure lines carry a compose prefix.
2. [correctness] lib/canccu-resume.sh:82 — on `needs-work`, `owed_round` and `extra_round` run without `LEAD_MODEL`, so an `opus` or `model: <id>` line in that comment is ignored
   Evidence: the state is fix_owed=1, phase needs-you, the issue is labelled `needs-work`, and the comment is "Keep the old name.\nopus". `owed_round "$n" "$pr" "$c" needs-work` calls `resume … fix`, which runs on FIX_MODEL. docs/reference/config-runs.md:34: "A line `opus` or `model: <id>` alone in your comment (or `needs-work` comment) runs that follow-up on that model instead". Only the plain needs-work resume at line 88 sets `LEAD_MODEL=$(model_line "$c")`.
   Fix: prefix both calls at lines 82–83 with `LEAD_MODEL=$(model_line "$c")`, or read `model_line` inside `resume` from the comment it is given. Add a tests/canccu-models.sh case for a needs-work comment on an owed round.
3. [correctness] lib/canccu-releasered.sh:161 — a flaky issue's "failing lines" take every digest block whose job name starts with the check's name, not only its own
   Evidence: the first run fails jobs `build` and `build arm`, and the digest has `== build (u1) ==` / `line A` / `== build arm (u2) ==` / `line B`. `awk -v h="== build " 'index($0, h) == 1 …'` turns on at both headers and prints `line A` and `line B` (run against that digest), so the `flaky: build` comment shows the other job's failure.
   Fix: match the whole header. Compare with `h = "== " check " ("` plus the job's url (or `"== " check " =="` when there is no url), or store each job's block under its job id in `.digest` and look it up by id.
Non-blocking:
- [security] lib/canccu-releasered.sh:166 — the `flaky: <check>` issue is found by title alone, whoever opened it. Its body's `Failures:` count is trusted, and the dispatcher overwrites the body and may add `ready`. Check that the issue carries `CANCCU_MARK` (or that the bot or `USER_LOGIN` opened it) before reusing it.
- [test-gap] tests/canccu-models.sh:44 — the model-line override is tested only on a plain comment, never on a `needs-work` comment (the owed round, the extra round, the plain needs-work), which blocking 2 shows can differ.
- [other] lib/canccu-actions.sh:127 — `model_line` accepts a line after a `>` quote, so a reply that quotes an earlier comment's `opus` line changes the model again.
- [other] lib/canccu-actions.sh:98 — `LEAD_MODEL` is read from the environment, not from a settings key. A `LEAD_MODEL` exported in the dispatcher's own environment overrides the model of every resumed run.
- [other] lib/canccu-cidigest.sh:72 — with more failing jobs than `CI_DIGEST_LINES / 2`, `per` stays 2 and `head -n "$cap"` drops the later jobs' blocks whole, so "every failing job" does not hold for long matrices. Say how many jobs were left out.
- [other] lib/canccu-releasered.sh:64 — in a dry run the `release-red/` dir is not created, so the `> "$d.jobs.tmp"` redirect fails and `ci_digest_jobs` reads a missing file, keeping the last call's `DIGEST_INFRA`.
Pre-existing:
Risk: low — the step's deep-review report
Findings: 3 blocking, 6 non-blocking, 0 pre-existing
Review verdict: changes ca5e6b9928c676fc12bcc7cbc62c6836a378cc12
