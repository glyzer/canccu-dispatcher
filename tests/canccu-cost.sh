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
ok "CI red → needs-you, not a CI wait" eq "$(st 5 phase) $(st 5 ny_wait)" "needs-you "

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
ok "CI wait, CI now red → still needs-you" eq "$(st 5 phase)" needs-you
ok "… now for the red CI" eq "$(st 5 reason)" "CI is red on PR #50"
ok "… no review" not grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… the worker is not resumed" not started 5
dispatch --once
ok "… and the next pass leaves it there (no second comment)" eq "$(grep -c '^issue comment 5 ' "$FAKE/gh.log")" 1

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
  grep -q -- '--name #5 web 5 The user answered: rename it first' "$FAKE/worker.log"
ok "… no review" not grep -q -- '--key review-50' "$FAKE/worker.log"

# ---------------------------------------------------------------- tests/run

tr_() { "$root/tests/run" "$@" 2>&1; }
tname=tests-run
ok "tests/run: a test file is linted and run" eq "$(tr_ --list tests/canccu-usage.sh)" $'lint: tests/canccu-usage.sh\ntests/canccu-usage.sh'
ok "tests/run: a pattern picks the test files it matches" eq "$(tr_ --list dispatch)" "tests/canccu-dispatch.sh"
ok "tests/run: monitor is the monitor's self-test" eq "$(tr_ --list monitor)" "monitor"
ok "tests/run: a lib file is linted and its tests listed" \
  eq "$(tr_ --list lib/canccu-usage.sh)" $'lint: lib/canccu-usage.sh\ntests/canccu-usage.sh'
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

# ---------------------------------------------------------------- the worker's test rule

RULE='While working, run only the tests of the files you change; run the full suite once, just before pushing; never paste whole test logs into the conversation.'
env_new test-rule
{ issue 30 ready; } | issues
dispatch --once
ok "worker prompt: the test rule" grep -qF "$RULE" "$FAKE/worker.log"
ok "… and branch updates merge main, never rebase" grep -qF 'To bring in main, run `git merge origin/main` and push normally; never rebase or force-push' "$FAKE/worker.log"
ok "package and health prompts: the test rule" grep -qF "$RULE" <<<"$(lib common_rules)"
ok "… and merge, never rebase" grep -qF 'never rebase or force-push' <<<"$(lib common_rules)"

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
ok "both are documented in the rules template" eq "$(grep -cE "^# (PLANNER_EXTRA=''|PACKAGE_MIN_ISSUES=1)$" "$root/profiles/default/rules")" 2

echo "canccu-cost tests: $npass passed, $nfail failed"
(( nfail == 0 ))
