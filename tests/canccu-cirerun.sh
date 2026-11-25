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

# a job of the run that never ends holds the rerun the same way
rrenv busy-bounded
pr 50 5 $HA red | jq '.statusCheckRollup[0].detailsUrl = "https://github.com/example-org/web/actions/runs/700/job/77"
  | .statusCheckRollup += [{name: "lint", status: "IN_PROGRESS", conclusion: "", detailsUrl: "https://github.com/example-org/web/actions/runs/700/job/78"}]' | prs
dispatch --once
ok "a run with a job still running → waits, the start of the wait is kept" eq "$(grep -c needs-you "$FAKE/gh.log") [$(st 5 ci_wait_at | cut -d: -f1)]" "0 [$HA]"
echo "ci_wait_at=$HA:$((NOW - 700))" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "… still running after 10 minutes → needs-you, no fix run" \
  eq "$(grep -c 'could not be rerun for 10 minutes: run 700' "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "1 0"

# only /actions/runs/<id>/job/<id> is a job id: another CI's URL with /job/<n> is no Actions job
ok "ci_failed: a check URL that only contains /job/<n> has no run and no job id" \
  eq "$(lib eval 'PRS=$(jq -n "[{number: 50, statusCheckRollup: [{name: \"ext\", status: \"COMPLETED\", conclusion: \"FAILURE\", detailsUrl: \"https://ci.example.com/job/99\"}]}]"); ci_failed 50')" "$(printf '\text\tFAILURE\t')"

echo "canccu-cirerun tests: $npass passed, $nfail failed"
(( nfail == 0 ))
