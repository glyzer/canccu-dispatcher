#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-cost.sh — offline tests for #77 (the run cost of a worker): the worker prompts say to
# merge main, never rebase; an issue parked in needs-you only because its PR's CI was still
# pending (CI_WAIT_MIN) or had no checks (NO_CHECKS_MIN) goes back to check by itself once CI is
# green or red: the label comes off, nothing is resumed, the normal review starts.
# Harness: tests/lib/harness.sh.
#   bash tests/canccu-cost.sh   one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# parked <ci> <stage> <reason> [ny_wait]: issue 5 in needs-you on PR 50, whose CI is now <ci>; no
# comments by the user since it parked
parked() {
  { issue 5 in-progress,needs-you; } | issues
  p=$(pr 50 5 $HA "$1"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  json c5.json '{"comments": []}'; route 'issue view 5 *' c5.json
  state 5 phase=needs-you pr=50 "check_at=$((NOW - 100 * 60))" "ny_at=$((NOW - 10 * 60))" \
    "reason=$3" ny_stage="$2" ${4:+ny_wait=$4}
}

# ---------------------------------------------------------------- merge, don't rebase

MERGE_LINE='To bring in main, run `git merge origin/main` and push normally; never rebase or force-push a PR branch (the squash-merge flattens it).'
env_new prompt-merge
{ issue 10 ready; } | issues
dispatch --once
ok "worker prompt: merge main, never rebase or force-push" grep -qF -- "$MERGE_LINE" "$FAKE/worker.log"
ok "package and health prompts: the same line" eq "$(lib common_rules | grep -cF -- "$MERGE_LINE")" 1

# ---------------------------------------------------------------- check_pr marks the CI waits

env_new mark-pending
{ issue 5 in-progress; } | issues
pr 50 5 $HA pending | prs
state 5 phase=check "check_at=$((NOW - 91 * 60))" pr=50
dispatch --once
ok "CI pending past CI_WAIT_MIN → needs-you, marked as a CI wait" eq "$(st 5 phase) $(st 5 ny_wait)" "needs-you ci"

env_new mark-none
{ issue 5 in-progress; } | issues
pr 50 5 $HA none | prs
state 5 phase=check "check_at=$((NOW - 11 * 60))" pr=50
dispatch --once
ok "no checks past NO_CHECKS_MIN → needs-you, marked as a CI wait" eq "$(st 5 phase) $(st 5 ny_wait)" "needs-you ci"

env_new mark-red
{ issue 5 in-progress; } | issues
pr 50 5 $HA red | prs
state 5 phase=check "check_at=$NOW" pr=50 ny_wait=ci
dispatch --once
ok "CI red → a fix run, not a CI wait" eq "$(st 5 phase) $(st 5 ny_wait)" "work "

# ---------------------------------------------------------------- green → review

env_new unpark-green
parked green ci "CI on PR #50 is still pending after 90 min" ci
dispatch --once
ok "CI wait, CI now green → the needs-you label comes off" has gh.log "issue edit 5 -R example-org/web --remove-label needs-you"
ok "… the review starts" grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… phase review" eq "$(st 5 phase)" review
ok "… the worker is not resumed" not started 5
ok "… the wait mark is gone" eq "$(st 5 ny_wait)" ""

env_new unpark-none-green
parked green no-checks "no CI checks on PR #50: is CI set up for this repo, or did a path filter skip it?" ci
dispatch --once
ok "no-checks wait, CI now green → the review starts" grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… the worker is not resumed" not started 5

# ---------------------------------------------------------------- red → stays needs-you

env_new unpark-red
parked red ci "CI on PR #50 is still pending after 90 min" ci
dispatch --once
ok "CI wait, CI now red → the red-CI fix run (canccu-followup.sh)" eq "$(st 5 phase) $(grep -c 'CI is red on PR #50' "$FAKE/worker.log")" "work 1"
ok "… no review" not grep -q -- '--key review-50' "$FAKE/worker.log"
dispatch --once
ok "… and the next pass starts no second one" eq "$(grep -c 'CI is red on PR #50' "$FAKE/worker.log")" 1

# ---------------------------------------------------------------- still pending → stays

env_new unpark-pending
parked pending ci "CI on PR #50 is still pending after 90 min" ci
dispatch --once
ok "CI wait, CI still pending → still needs-you" eq "$(st 5 phase) $(st 5 ny_wait)" "needs-you ci"
ok "… the label stays, no comment" eq "$(grep -cE '^issue (edit|comment) 5 ' "$FAKE/gh.log")" 0
ok "… no review, no resume" eq "$(grep -c . "$FAKE/worker.log")" 0

env_new unpark-none-still
parked none no-checks "no CI checks on PR #50: is CI set up for this repo, or did a path filter skip it?" ci
dispatch --once
ok "no-checks wait, still no checks → still needs-you" eq "$(st 5 phase) $(grep -c . "$FAKE/worker.log")" "needs-you 0"

# ---------------------------------------------------------------- other needs-you stay

env_new unpark-other
parked green ci "CI is red on PR #50"
dispatch --once
ok "needs-you for red CI, CI now green → stays (only a CI wait comes back by itself)" eq "$(st 5 phase) $(grep -c . "$FAKE/worker.log")" "needs-you 0"

env_new unpark-commented
parked green ci "CI on PR #50 is still pending after 90 min" ci
json c5.json "$(jq -n --argjson c "$(comment 2030-11-05T11:59:00Z 'rename it first')" '{comments: [$c]}')"
dispatch --once
ok "CI wait with a user comment since, CI now green → the worker resumes with the comment" \
  grep -q -- '--name #5 --fresh web 5 Rules for this run: .* The user answered: rename it first' "$FAKE/worker.log"
ok "… no review" not grep -q -- '--key review-50' "$FAKE/worker.log"

# ---------------------------------------------------------------- tests/run

tr_() { "$root/tests/run" "$@" 2>&1; }
tname=tests-run
ok "tests/run: a test file is linted and run" eq "$(tr_ --list tests/canccu-usage.sh)" $'lint: tests/canccu-usage.sh\ntests/canccu-usage.sh'
ok "tests/run: a pattern picks the test files it matches" eq "$(tr_ --list dispatch | LC_ALL=C sort)" $'tests/canccu-dispatch.sh\ntests/canccu-dispatch2.sh'
ok "tests/run: monitor is the monitor's self-test" eq "$(tr_ --list monitor)" "monitor"
ok "tests/run: a lib file is linted and its tests listed (the docs test: it cites a section)" \
  eq "$(tr_ --list lib/canccu-usage.sh)" $'lint: lib/canccu-usage.sh\ntests/canccu-usage.sh\ntests/canccu-docs.sh'
ok "tests/run: every file that cites docs/canccu-dispatch.md maps to the docs test" \
  eq "$(for f in lib/canccu-ping.sh bin/canccu-init lib/canccu-plan.jq lib/canccu_monitor/data.py; do
          tr_ --list "$f" | grep -cx tests/canccu-docs.sh; done | tr '\n' ' ')" "1 1 1 1 "
ok "tests/run: so does the CHANGELOG" grep -qx tests/canccu-docs.sh <<<"$(tr_ --list CHANGELOG.md)"
ok "tests/run: a file that cites no section does not" not grep -qx tests/canccu-docs.sh <<<"$(tr_ --list lib/canccu-doctor.sh)"
for f in lib/canccu-pipeline.sh lib/canccu-actions.sh lib/canccu-runs.sh; do
  ok "tests/run: $f maps to the needs-work tests too" grep -qx tests/canccu-review2.sh <<<"$(tr_ --list "$f")"
done
ok "tests/run: an absolute path maps like the relative one" \
  eq "$(tr_ --list "$root/lib/canccu-usage.sh")" "$(tr_ --list lib/canccu-usage.sh)"
ok "tests/run: a path relative to the caller's directory maps too" \
  eq "$(cd "$root/lib" && tr_ --list canccu-usage.sh)" "$(tr_ --list lib/canccu-usage.sh)"
ok "tests/run: a path outside the repo → exit 2" eq "$(tr_ --list /etc/hostname >/dev/null; echo $?)" 2
ok "tests/run: a pattern that matches nothing → exit 2" eq "$(tr_ --list no-such-test >/dev/null; echo $?)" 2
ok "tests/run: the engine maps to the engine tests" grep -qx tests/canccu-engine.sh <<<"$(tr_ --list libexec/canccu-worker)"
ok "tests/run: bin/canccu-dispatch maps to the dispatcher's tests" grep -qx tests/canccu-dispatch.sh <<<"$(tr_ --list bin/canccu-dispatch)"
ok "tests/run: the commands and libs map to the compatibility test too" \
  eq "$(grep -cx tests/canccu-compat.sh <<<"$(tr_ --list bin/canccu-status lib/canccu-runs.sh)")" 1
ok "tests/run: an expected compat output maps to the compatibility test" eq "$(tr_ --list tests/fixtures/compat/status-web.txt)" tests/canccu-compat.sh
full=$(tr_ --list)
ok "tests/run (no argument): lints every shell file" \
  grep -q '^lint: .*bin/canccu-dispatch .*libexec/canccu-worker .*lib/canccu-common.sh .*tests/canccu-dispatch.sh .*tests/lib/harness.sh .*tests/run' <<<"$full"
ok "… the sourced shell files too (config, rules)" grep -q '^lint: .*lib/canccu-config.default .*profiles/default/rules' <<<"$full"
ok "… the release and review-gate scripts, and the template's" \
  grep -q '^lint: .*\.github/scripts/release .*\.github/scripts/release-smoke .*\.github/scripts/review-gate .*templates/repo/\.github/scripts/review-gate' <<<"$full"
ok "… lints no non-shell file" not grep -qE '^lint: .*(canccu-monitor\.py|canccu-plan\.jq|\.json)' <<<"$full"
ok "… runs every test file, the leak check and the monitor's self-test" \
  eq "$(grep -v '^lint:' <<<"$full" | sort | tr '\n' ' ')" "$(cd "$root" && { ls tests/*.sh; echo monitor; } | sort | tr '\n' ' ')"
# a run: one summary line per file, the failing checks only, the full log in a file
F=$T/runroot; mkdir -p "$F/tests/lib"; cp "$root/tests/run" "$F/tests/"
printf '#!/usr/bin/env bash\necho "chatter"\necho "FAIL [x] the thing"\necho "    expected: 1"\necho "bad tests: 1 passed, 1 failed"\nexit 1\n' > "$F/tests/bad.sh"
printf '#!/usr/bin/env bash\necho "chatter"\necho "good tests: 3 passed, 0 failed"\n' > "$F/tests/good.sh"
out=$(cd "$F" && CANCCU_TEST_LOGS=$T/runlogs tests/run tests/bad.sh tests/good.sh 2>&1); rc=$?
ok "tests/run: a failing file → exit 1" eq "$rc" 1
ok "… its FAIL line and what follows it are shown" eq "$(grep -cE '^(FAIL \[x\] the thing|    expected: 1)$' <<<"$out")" 2
ok "… one summary line per file" eq "$(grep -cE '^tests/(bad|good)\.sh: (FAILED|ok) · (bad|good) tests: ' <<<"$out")" 2
ok "… no chatter" not grep -q chatter <<<"$out"
ok "… the full logs are kept, and named" eq "$(cat "$T"/runlogs/*.log | grep -c chatter) $(grep -c "full logs: $T/runlogs" <<<"$out")" "2 1"
# CANCCU_TEST_JOBS caps the parts at once; the biggest test file starts first
printf '#!/usr/bin/env bash\nmkdir "%s/busy" || { echo "two at once"; exit 1; }\nsleep 1; rmdir "%s/busy"\necho "small tests: 1 passed, 0 failed"\n' "$T" "$T" > "$F/tests/small.sh"
{ cat "$F/tests/small.sh"; printf '# %s\n' "padding that makes this file the biggest one" "more padding"; } > "$F/tests/big.sh"
out=$(cd "$F" && CANCCU_TEST_JOBS=1 tests/run tests/small.sh tests/big.sh 2>&1); rc=$?
ok "tests/run: CANCCU_TEST_JOBS=1 runs one part at a time" eq "$rc $(grep -c 'two at once' <<<"$out")" "0 0"
ok "… the biggest test file first" eq "$(grep -oE '^tests/(big|small)\.sh' <<<"$out" | tr '\n' ' ')" "tests/big.sh tests/small.sh "
# CANCCU_TEST_TIMEOUT: each test file's time limit (default 8m), for a slow host such as jq 1.6's
printf '#!/usr/bin/env bash\nsleep 5\necho "slow tests: 1 passed, 0 failed"\n' > "$F/tests/slow.sh"
out=$(cd "$F" && CANCCU_TEST_LOGS=$T/runlogs3 CANCCU_TEST_TIMEOUT=1s tests/run tests/slow.sh 2>&1); rc=$?
ok "tests/run: CANCCU_TEST_TIMEOUT=1s stops a slower test file" eq "$rc $(grep -c '^tests/slow\.sh: FAILED .*(timed out)$' <<<"$out")" "1 1"
out=$(cd "$F" && CANCCU_TEST_LOGS=$T/runlogs3 CANCCU_TEST_TIMEOUT=20s tests/run tests/slow.sh 2>&1); rc=$?
ok "… and a longer one lets it finish" eq "$rc" 0
# CANCCU_TEST_TICK: a heartbeat line names the parts still running, so a long run is never silent
printf '#!/usr/bin/env bash\nsleep 3\necho "slow2 tests: 1 passed, 0 failed"\n' > "$F/tests/slow2.sh"
# another run's parts in a shared log dir are not this run's
mkdir -p "$T/runlogs4/.running-1"; echo tests/other.sh > "$T/runlogs4/.running-1/tests_other.sh.run"
out=$(cd "$F" && CANCCU_TEST_LOGS=$T/runlogs4 CANCCU_TEST_TICK=1 tests/run tests/slow2.sh tests/good.sh 2>&1); rc=$?
ok "tests/run: CANCCU_TEST_TICK=1 prints what still runs" eq "$rc $(grep -cE '^… [0-9]+s, still running: tests/slow2\.sh$' <<<"$out" | awk '{ print ($1 >= 1) }')" "0 1"
ok "… the finished part is not named" not grep -q 'still running: .*good' <<<"$out"
# a heartbeat left running would hold the output open until its next tick, 60s away
t0=$SECONDS; out=$(cd "$F" && tests/run tests/good.sh 2>&1)
ok "… and it ends with the run" eq "$(( SECONDS - t0 < 30 ))" 1
out=$(cd "$F" && CANCCU_TEST_TICK=0 tests/run tests/slow2.sh 2>&1)
ok "… CANCCU_TEST_TICK=0: none" not grep -q 'still running' <<<"$out"
out=$(cd "$F" && CANCCU_TEST_TIMEOUT=soon tests/run tests/slow.sh 2>&1); rc=$?
ok "… a limit that is no duration: a usage error" eq "$rc $(grep -c 'CANCCU_TEST_TIMEOUT' <<<"$out")" "2 1"

# ---------------------------------------------------------------- the worker's test rule

RULE='run only the tests of the files you change (the affected-tests command CLAUDE.md names, when it has one), in the foreground; do not run the full suite locally: CI runs it on every push.'
env_new test-rule
{ issue 30 ready; } | issues
dispatch --once
ok "worker prompt: the test rule" grep -qF "$RULE" "$FAKE/worker.log"
ok "… and branch updates merge main, never rebase" grep -qF 'To bring in main, run `git merge origin/main` and push normally; never rebase or force-push' "$FAKE/worker.log"
ok "package and health prompts: the test rule" grep -qF "$RULE" <<<"$(lib common_rules)"
ok "… and merge, never rebase" grep -qF 'never rebase or force-push' <<<"$(lib common_rules)"
# #26: a headless run ends with its turn, so no background work, early pushes and no CI wait
for t in 'Never run a command in the background' 'Commit and push early: push the branch after the tests-first commit and again when the tests pass' \
  'stop as soon as the PR is open and ready: do not wait for CI, the dispatcher watches it'; do
  ok "worker prompt: $t" grep -qF "$t" "$FAKE/worker.log"
  ok "… the package prompts too" grep -qF "$t" <<<"$(lib common_rules)"
done
ok "… and no fix-round count of their own: the dispatcher's FIX_ATTEMPTS caps them" not grep -qF 'CI red after two fix rounds' "$FAKE/worker.log"
ok "the engine's system prompt: no background work" grep -qF 'Never run a command or subagent in the background' "$root/libexec/canccu-worker"

# ---------------------------------------------------------------- planner guidance

tname=planner-guidance
pp() { lib eval "$1"'; planner_prompt 12 1 "101 102"'; }
ok "PACKAGE_MIN_ISSUES defaults to 1, PLANNER_EXTRA to empty" eq "$(lib eval 'echo "$PACKAGE_MIN_ISSUES [$PLANNER_EXTRA]"')" "1 []"
ok "PACKAGE_MIN_ISSUES 1: no bundling nudge" not grep -q 'issues per package' <<<"$(pp :)"
ok "PACKAGE_MIN_ISSUES 3: the planner is nudged to bundle" \
  grep -qF 'aim for at least 3 issues per package where they fit together (never bundle unrelated issues just to reach it)' <<<"$(pp PACKAGE_MIN_ISSUES=3)"
ok "PLANNER_EXTRA: the project's guidance reaches the planner" \
  grep -qF "The project's guidance: aim for 2-4 issues per package." <<<"$(pp 'PLANNER_EXTRA="aim for 2-4 issues per package"')"
ok "… and is no part of the prompt when empty" not grep -q "project's guidance" <<<"$(pp :)"
# #106: a number at the start of the step's title is no step number
ok "the prompt says which number is the plan's step" grep -qF 'In the plan, "step" is 4 and "wave" is 1: "step" is the milestone'"'"'s number, and a number at the start of the step'"'"'s title is only part of its name.' \
  <<<"$(lib eval 'MILESTONES='"'"'[{"number":4,"title":"3 Release 0.2"}]'"'"'; planner_prompt 4 1 "101"')"
ok "both are documented in the rules template" eq "$(grep -cE "^# (PLANNER_EXTRA=''|PACKAGE_MIN_ISSUES=1)$" "$root/profiles/default/rules")" 2

echo "canccu-cost tests: $npass passed, $nfail failed"
(( nfail == 0 ))
