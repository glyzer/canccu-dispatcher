#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-reviewbudget.sh — a review or fix-check run that stopped at its budget with no valid
# verdict is retried once per head as one full review (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

budgetenv() {   # budgetenv <name> <mode>: the run of PR 50 at HA, in <mode>, has stopped with no file
  env_new "$1"
  { issue 5 in-progress; } | issues
  p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
  state 5 phase=review pr=50 review_sha=$HA "started=$NOW" rounds=0 "review_mode=$2" stage=fixcheck reviewed_sha=$HB
  last review-50 'stopped: time budget 15m' "ran out"
  RF=$CANCCU_HOME/reviews/50/$HA.md; mkdir -p "${RF%/*}"
}
full_reviews() { grep -c -- '--key review-50 .*Write your review to the file' "$FAKE/worker.log"; }

budgetenv budget-fixcheck fixcheck
dispatch --once
ok "a fix-check stopped at its time budget with no file → one full review of the head" eq "$(full_reviews)" 1
ok "… review_retry is the head, the mode a full review" eq "$(st 5 review_retry) $(st 5 review_mode) $(st 5 phase)" "$HA review review"
ok "… no needs-you" eq "$(grep -c needs-you "$FAKE/gh.log")" 0
ok "… logged" grep -qF "#5 PR #50: the fix-check stopped at its budget with no verdict; one full review of ${HA:0:7}" "$CANCCU_HOME/dispatch.log"
rm -f "$WORKERS_DIR/web-review-50.lock"; last review-50 'stopped: time budget 15m' "ran out again"
dispatch --once
ok "the second stop on the same head → needs-you, no third run" \
  eq "$(grep -c 'left no review ending in' "$FAKE/gh.log") $(full_reviews)" "1 1"

budgetenv budget-reviewer review
dispatch --once
ok "a full review stopped at its turn budget is retried once too" eq "$(full_reviews) $(st 5 review_retry)" "1 $HA"
ok "… logged as the reviewer" grep -qF "#5 PR #50: the reviewer stopped at its budget with no verdict" "$CANCCU_HOME/dispatch.log"

echo "canccu-reviewbudget tests: $npass passed, $nfail failed"
(( nfail == 0 ))
