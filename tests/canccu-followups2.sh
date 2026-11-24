#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-followups2.sh — offline tests for the review follow-ups of #222, second part: the
# reviews and findings, the feed and leader, the config (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# a worker running the tests exports its WORKER_* settings: the harness drops them
ok "no WORKER_* variable of the caller reaches a test" eq "$(compgen -v WORKER_ | tr '\n' ' ')" ""

# ---------------------------------------------------------------- reviews and findings

env_new nonelist
F=$E/review.md
printf 'Blocking:\n- none\nNon-blocking: (none)\nPre-existing:\n* n/a.\nFindings: 0 blocking, 0 non-blocking, 0 pre-existing\nReview verdict: pass %s\n' "$HA" > "$F"
ok "a list item or heading text that says none is no item: the count line matches" eq "$(lib file_verdict "$F" "$HA")" pass
printf 'I read it all.\nReview verdict: pass %s\n' "$HA" > "$F"
ok "review_miss: a file with no finding block or count line says so" eq "$(lib review_miss "$F")" "no finding block or count line"
printf 'Blocking:\n- [correctness] a.sh:1 — off\n  Evidence: x\nFindings: 0 blocking, 0 non-blocking, 0 pre-existing\nReview verdict: pass %s\n' "$HA" > "$F"
ok "review_miss: a count line that does not match" eq "$(lib review_miss "$F")" "the count line does not match the items"
printf 'Blocking:\n- [security] a.sh:4 — the token is logged again\n  Evidence: line 4 echoes it\nNon-blocking:\nnone\nPre-existing:\nnone\nFindings: 1 blocking, 0 non-blocking, 0 pre-existing\nReview verdict: changes %s\n' "$HA" > "$F"
ok "a settled security finding still blocks" \
  eq "$(lib eval "REVIEW_SETTLED=\$'security\ta.sh\t3-5' _review_awk eff < '$F'")" "1 0 0 0 security"
printf 'Blocking:\n1. a.sh:1 off\nNon-Blocking:\n- a nit\n- another\nReview verdict: changes %s\n' "$HA" > "$F"
ok "findings_count of a hand-posted review reads Non-Blocking: in any case" eq "$(lib findings_count "$F" "$HA")" "1 2"
ok "the reviewer rules class any wrong behaviour as correctness" \
  grep -qF 'Any wrong behaviour (a wrong result, a crash, a hang, a leak) is `correctness`' <<<"$(lib eval 'echo "$REVIEW_RULES"')"

# ---------------------------------------------------------------- feed and leader

EV() { echo "$CANCCU_HOME/events"; }
lines() { if [ -e "$(EV)" ]; then wc -l < "$(EV)"; else echo 0; fi; }
field() { awk -F '\t' -v n="$1" -v c="$2" 'NR == n { print $c }' "$(EV)"; }
waitcmd() { PATH="$fb:$PATH" timeout 20 "$root/bin/canccu-dispatcher" wait "$@"; }
ackv() { lib kv_get "$CANCCU_HOME/feed.open" feed leader_ack; }

env_new ack-cap LEADER=on
touch -d "@$NOW" "$CANCCU_HOME/heartbeat"
lib feed leader ask idle 6 - - one >/dev/null; lib feed leader ask idle 7 - - two >/dev/null
waitcmd --owner leader --ack 99999 >/dev/null
ok "wait --owner leader --ack 99999: the ack is capped at the last id" eq "$(ackv)" 2
lib kv_set "$CANCCU_HOME/feed.open" feed leader_ack=500
ok "a stale ack above the last id (the events file reset) is cleared" eq "$(lib feed_ack) [$(ackv)]" "0 []"

# a leader's idle line unacked for 61 min passes to the product owner like an accept
env_new idle-handover LEADER=on LEADER_ACCEPTS=technical PING_KINDS=all
{ issue 5 in-progress; } | issues
pr 50 5 "$HA" pending | prs
CANCCU_NOW=$((NOW - 61 * 60)) lib feed leader ask idle 5 50 - "#5 sits in check for 60 min with nothing running" >/dev/null
state 5 phase=check pr=50 "check_at=$NOW" "phase_at=$((NOW - 121 * 60))" idle_ev=1
dispatch --once
ok "an idle line of the leader's unacked for 61 min → closed, a handover line for po" \
  eq "$(field 3 5) $(field 3 9)|$(field 2 3) $(field 2 5)|$(st 5 idle_ev)" "closed closes 1: passed to the product owner|po handover|2"
dispatch --once
ok "… once" eq "$(lines)" 3

# ---------------------------------------------------------------- config

env_new cfg-words
ok "PING_KINDS=plan,question: both kinds ping, others not" \
  eq "$(lib eval '. "$root/lib/canccu-ping.sh"; PING_KINDS=plan,question; for k in plan question accept; do ping_kind_on $k && echo -n "$k "; done')" "plan question "
env_new cfg-stamp
touch -d "@$NOW.1" "$CANCCU_HOME/config"; a=$(lib canccu_cfg_stamp)
touch -d "@$NOW.2" "$CANCCU_HOME/config"
ok "the reload stamp sees a change in the same second" not eq "$(lib canccu_cfg_stamp)" "$a"

# ---------------------------------------------------------------- planner and packages

env_new plan-areas
pvo() {
  printf '%s\n' "$1" > "$E/ov.json"
  lib plan_validate "$E/ov.json" "$(jq -c '.carried = [{name: "r"}]' "$root/tests/fixtures/plans/input.json")" 12 2 "$2" | jq -c .errors
}
ovp() { jq -nc --argjson a "$1" '{schema: 1, step: 12, wave: 2, packages: [{name: "n", issues: [101], risk: "low", risk_reason: "x", areas: $a, depends_on: []}]}'; }
for a in . ./ /; do
  ok "a running package's root area '$a' overlaps every new area" \
    eq "$(pvo "$(ovp '["lib/x.sh"]')" "[{\"name\":\"r\",\"areas\":[\"$a\"]}]")" '["n overlaps running r in lib/x.sh"]'
done
ok "… a new package's root area overlaps a running one's" \
  eq "$(pvo "$(ovp '["."]')" '[{"name":"r","areas":["lib/a"]}]')" '["n overlaps running r in lib/a"]'
printf '%s\n' '{"packages":[{"name":"a","areas":["lib/a"]},{"name":"b","areas":["lib/b"]},{"name":"c","areas":["lib/c"]}]}' > "$E/plan.json"
ok "running_areas: the live carried packages (blocked, pending) count, a dead one not" \
  eq "$(lib eval "step_get() { echo '$E/plan.json'; }
    plan_states() { printf 'a\trunning\t1\t101\tk1\nb\tblocked\t1\t102\tk2\nc\tclosed\t0\t103\tk3\n'; }
    running_areas 12")" '[{"name":"a","areas":["lib/a"]},{"name":"b","areas":["lib/b"]}]'

echo "canccu-followups2 tests: $npass passed, $nfail failed"; (( nfail == 0 ))
