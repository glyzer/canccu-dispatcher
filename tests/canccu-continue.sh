#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-continue.sh — a worker that stops at its turn or time budget while it makes progress
# continues on its own (#127): up to CONTINUE_MAX runs, within the unit's USD budget; needs-you
# only without progress or once those are used up. A resume after the usage limit gets the rest of
# the unit's work budget.
. "$(dirname "$0")/lib/harness.sh"

# cenv <name> <state...>: issue 5 at work on PR 50 (head HB); its run (12 turns, $1.00, 3 min) has
# ended with the given exit status, its handoff its last message
cenv() {
  env_new "$1"
  { issue 5 in-progress; } | issues
  pr 50 5 "$HB" | prs
  state 5 phase=work "started=$NOW" pr=50 branch=5-thing "${@:2}"
}
wlast() { grep -- '--name #5 ' "$FAKE/worker.log" | tail -1; }
runs() { grep -c -- '--name #5 ' "$FAKE/worker.log"; }

# ---------------------------------------------------------------- progress: it continues

cenv cont-turns run_head="$HA"
last 5 'stopped: turn budget 250' $'Done: the parser. Left: the docs.'
dispatch --once
ok "a turn-budget stop with a new head on its PR: no needs-you" eq "$(grep -c 'needs-you' "$FAKE/gh.log") $(st 5 phase)" "0 work"
ok "… a continuation run starts at once" eq "$(runs)" 1
ok "… with fresh turns and minutes and the USD the unit has left" grep -qE ' turns=250 cost=79(\.0+)? min=150$' <<<"$(wlast)"
ok "… a fresh session with the run's handoff" eq "$(grep -c -- '--fresh' <<<"$(wlast)") $(grep -cF 'Left: the docs.' <<<"$(wlast)")" "1 1"
ok "… it is told which continuation it is and to push as it goes" \
  eq "$(grep -cF 'continuation 1 of 3' <<<"$(wlast)") $(grep -cF 'push at least every 30 turns' <<<"$(wlast)")" "1 1"
ok "… counted, and the PR's head kept for the next stop" eq "$(st 5 cont) $(st 5 run_head)" "1 $HB"
ok "… what it used is summed: turns, USD, seconds" eq "$(st 5 used)" "12 1.00 180"
ok "… logged" grep -qF "#5 stopped at its turn budget with progress (PR #50 at ${HB:0:7}); continuation 1 of 3" "$CANCCU_HOME/dispatch.log"

cenv cont-time run_head="$HA"
last 5 'stopped: time budget 150m' 'Left: tests.'
dispatch --once
ok "a time-budget stop with progress continues too" eq "$(runs) $(st 5 cont)" "1 1"

cenv cont-ready run_head="$HB" run_draft=true
last 5 'stopped: turn budget 250' 'Left: tests.'
dispatch --once
ok "the PR moved from draft to ready: progress" eq "$(runs) $(st 5 cont)" "1 1"

cenv cont-held run_head="$HA"
touch "$CANCCU_HOME/paused"
last 5 'stopped: turn budget 250' 'Left: tests.'
dispatch --once
ok "paused: the continuation waits" eq "$(runs) $(st 5 phase) $(grep -c 'needs-you' "$FAKE/gh.log")" "0 continue 0"
rm -f "$CANCCU_HOME/paused"
dispatch --once
ok "… and starts once the pause ends" eq "$(runs) $(st 5 phase) $(st 5 cont)" "1 work 1"

cenv cont-spend run_head="$HB" cont=2
printf '%s\tweb\t5\t1.00\tbuild\n' "$((NOW + 30))" > "$WORKERS_DIR/spend.log"
last 5 done 'PR ready.'
dispatch --once
ok "the spend log marks a continuation's run" grep -qP '\tcont=2(,|$)' "$WORKERS_DIR/spend.log"
ok "… a run that finished ends the chain" eq "$(st 5 cont)" ""

# ---------------------------------------------------------------- no progress, or nothing left

cenv cont-none run_head="$HB"
last 5 'stopped: turn budget 250' 'Left: everything.'
dispatch --once
ok "no new head: needs-you, saying so" \
  grep -qF '#5 needs-you: the worker stopped: stopped: turn budget 250, with no new pushed commits on PR #50' "$CANCCU_HOME/dispatch.log"
ok "… no continuation" eq "$(runs)" 0

cenv cont-nopr
echo '[]' > "$FAKE/prs.json"
last 5 'stopped: turn budget 250' 'Left: everything.'
dispatch --once
ok "no PR at all: needs-you" eq "$(runs) $(st 5 phase)" "0 needs-you"

cenv cont-cap run_head="$HA" cont=3
last 5 'stopped: turn budget 250' 'Left: docs.'
dispatch --once
ok "CONTINUE_MAX continuations used: needs-you, saying so" \
  grep -qF '#5 needs-you: the worker stopped: stopped: turn budget 250; its 3 continuations (CONTINUE_MAX) are used' "$CANCCU_HOME/dispatch.log"

cenv cont-usd run_head="$HA" "used=400 79.50 9000"
last 5 'stopped: turn budget 250' 'Left: docs.'
dispatch --once
ok "the unit's USD budget used up: needs-you, saying so" \
  grep -qF '#5 needs-you: the worker stopped: stopped: turn budget 250; the work budget of $80 is used ($80.50)' "$CANCCU_HOME/dispatch.log"

cenv cont-cost run_head="$HA"
last 5 'stopped: cost budget $80' 'Left: docs.'
dispatch --once
ok "a cost-budget stop: needs-you as before" eq "$(runs) $(st 5 phase)" "0 needs-you"

cenv cont-off run_head="$HA"
echo CONTINUE_MAX=0 >> "$CANCCU_HOME/config"
last 5 'stopped: turn budget 250' 'Left: docs.'
dispatch --once
ok "CONTINUE_MAX=0: needs-you at once" eq "$(runs) $(st 5 phase)" "0 needs-you"

# ---------------------------------------------------------------- the usage-limit resume

cenv limited-left "used=30 10 600"
state 5 phase=limited pr=50 branch=5-thing "used=30 10 600" "started=$NOW"
dispatch --once
ok "a resume after the usage limit gets the rest of the work budget, not BUDGET_RESUME" \
  grep -qE ' turns=220 cost=70(\.0+)? min=140$' <<<"$(wlast)"

cenv limited-spent
state 5 phase=limited pr=50 branch=5-thing "used=250 79 9000" "started=$NOW"
dispatch --once
ok "… never less than BUDGET_RESUME" grep -qE ' turns=80 cost=20(\.0+)? min=45$' <<<"$(wlast)"

echo "canccu-continue tests: $npass passed, $nfail failed"; (( nfail == 0 ))
