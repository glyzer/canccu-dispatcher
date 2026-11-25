#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-cirerun.sh — the rerun of a red head's failed jobs: its waits are bounded and logged
# once, and only a GitHub Actions job URL gives a job id (the harness: tests/lib/harness.sh).
. "$(dirname "$0")/lib/harness.sh"

wt5() { mkdir -p "$WORKERS_DIR/worktrees/web/issue-5" && touch "$WORKERS_DIR/worktrees/web/issue-5/.git"; }
rrenv() {   # rrenv <name>: issue 5 is in check; PR 50 has red CI (job 77 of run 700), main is in
  env_new "$@"
  { issue 5 in-progress; } | issues
  pr 50 5 $HA red | jq '.statusCheckRollup[0].detailsUrl = "https://github.com/example-org/web/actions/runs/700/job/77"' | prs
  state 5 phase=check pr=50 "check_at=$NOW"
  wt5; echo 5-thing > "$FAKE/branch"; echo 0 > "$FAKE/behind"
  printf 'test\tRun tests\t2030-11-05T10:00:00Z FAIL tests/a.sh: expected 2, got 3\n' > "$FAKE/joblog"
  route 'run view --job 77 *' joblog
  json ok.json '{}'; route 'run rerun *' ok.json
}

# GitHub keeps refusing the rerun as "already running": a wait of at most 10 minutes, logged once
rrenv refused-bounded; : > "$FAKE/routes"; route 'run rerun *' RERUN_REFUSED
dispatch --once; dispatch --once
ok "a refused rerun is logged once over two passes (warn_once)" \
  eq "$(grep -c 'rerun of run 700 refused (still running)' "$CANCCU_HOME/dispatch.log")" 1
ok "… waiting: no needs-you, no fix run" eq "$(grep -c needs-you "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "0 0"
echo "ci_wait_at=$HA:$((NOW - 700))" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "refused for more than 10 minutes → needs-you naming the check, no fix run" \
  eq "$(grep -c 'CI is red on PR #50; its failed jobs could not be rerun for 10 minutes: run 700 (test)' "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "1 0"

# a job of the same run still running: the wait is bounded by CI_WAIT_MIN from check_at, not by 10 minutes
rrenv busy-bounded
pr 50 5 $HA red | jq '.statusCheckRollup[0].detailsUrl = "https://github.com/example-org/web/actions/runs/700/job/77"
  | .statusCheckRollup += [{name: "lint", status: "IN_PROGRESS", conclusion: "", detailsUrl: "https://github.com/example-org/web/actions/runs/700/job/78"}]' | prs
state 5 phase=check pr=50 "check_at=$((NOW - 660))"
dispatch --once
ok "a job still running after 11 minutes keeps waiting: no needs-you, no fix run, no rerun" \
  eq "$(grep -c needs-you "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log") $(grep -c '^run rerun' "$FAKE/gh.log")" "0 0 0"
state 5 phase=check pr=50 "check_at=$((NOW - 91 * 60))"
dispatch --once
ok "… still running after 90 minutes → needs-you, no fix run" \
  eq "$(grep -c "still has jobs running after 90 min" "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "1 0"
ok "… needs-you clears ci_wait_at" eq "[$(st 5 ci_wait_at)]" "[]"

# a refused rerun parks after 600 s; the needs-you lifted on the same head does not park again at once
rrenv refused-lifted; : > "$FAKE/routes"; route 'run rerun *' RERUN_REFUSED
echo "ci_wait_at=$HA:$((NOW - 700))" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "a refused rerun → needs-you after 600 s" eq "$(grep -c 'could not be rerun for 10 minutes' "$FAKE/gh.log")" 1
state 5 phase=check pr=50 "check_at=$NOW"
dispatch --once
ok "… lifted on the same head: it waits again, no second needs-you" \
  eq "$(grep -c 'could not be rerun for 10 minutes' "$FAKE/gh.log") $(st 5 phase)" "1 check"

# only /actions/runs/<id>/job/<id> is a job id: another CI's URL with /job/<n> is no Actions job
ok "ci_failed: a check URL that only contains /job/<n> has no run and no job id" \
  eq "$(lib eval 'PRS=$(jq -n "[{number: 50, statusCheckRollup: [{name: \"ext\", status: \"COMPLETED\", conclusion: \"FAILURE\", detailsUrl: \"https://ci.example.com/job/99\"}]}]"); ci_failed 50')" "$(printf '\text\tFAILURE\t')"

# a cancelled check whose cancel was not its time limit (a hand cancel, or an annotation lookup that
# fails) stays "CI (cancelled)" and is rerun like a failed one; a failed lookup is not cached
cancelled() {   # cancelled <name> [lookup fail]
  rrenv "$1"
  pr 50 5 $HA red | jq '.statusCheckRollup = [{name: "CI", status: "COMPLETED", conclusion: "CANCELLED", completedAt: "2030-11-05T10:12:00Z",
    detailsUrl: "https://github.com/example-org/web/actions/runs/700/job/77"}]' | prs
  if [ "${2:-}" = fail ]; then route 'fail:api repos/example-org/web/check-runs/77/annotations' x
  else json ann.json '[{"message": "The run was canceled by octo."}]'; route 'api repos/example-org/web/check-runs/77/annotations*' ann.json; fi
}
cancelled cancel-lookup-fails fail
dispatch --once
ok "a cancelled check, its annotation lookup failing → rerun, named as cancelled" \
  eq "$(grep -c '^run rerun 700 --failed' "$FAKE/gh.log") $(grep -c 'CI red on .* (CI (cancelled)); failed jobs rerun' "$CANCCU_HOME/dispatch.log")" "1 1"
ok "… the fix run says nothing of a time limit" not grep -q 'time limit' "$FAKE/worker.log"
cancelled cancel-by-hand
dispatch --once
ok "a hand cancel (an annotation without the time limit) → rerun, named as cancelled" \
  eq "$(grep -c '^run rerun 700 --failed' "$FAKE/gh.log") $(grep -c 'CI red on .* (CI (cancelled)); failed jobs rerun' "$CANCCU_HOME/dispatch.log")" "1 1"
ok "… the result is false, kept for the job" \
  eq "$(lib eval 'PRS='"'"'[{"number": 50, "statusCheckRollup": [{"name": "CI", "status": "COMPLETED", "conclusion": "CANCELLED", "detailsUrl": "https://github.com/example-org/web/actions/runs/700/job/77"}]}]'"'"'; ci_timeouts_load 50; echo "${CI_TIMEDOUT[77]:-unset}"')" false

echo "canccu-cirerun tests: $npass passed, $nfail failed"
(( nfail == 0 ))
