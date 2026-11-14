#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-feed.sh — the event feed, the heartbeat, the idle alarm and canccu-dispatcher wait
# (#83). Harness: tests/lib/harness.sh.
#   bash tests/canccu-feed.sh    one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

EV() { echo "$CANCCU_HOME/events"; }
lines() { if [ -e "$(EV)" ]; then wc -l < "$(EV)"; else echo 0; fi; }
field() { awk -F '\t' -v n="$1" -v c="$2" 'NR == n { print $c }' "$(EV)"; }
waitcmd() { PATH="$fb:$PATH" timeout 20 "$root/bin/canccu-dispatcher" wait "$@"; }

# ---------------------------------------------------------------- the writer

env_new feed-writer
( lib feed po ask accept 5 50 https://example.invalid/50 one > "$E/a" ) &
( lib feed leader ask idle 6 - - two > "$E/b" ) &
wait
ok "feed: two writers at once get ids 1 and 2" eq "$(sort -n "$E/a" "$E/b" | tr '\n' ' ')" "1 2 "
ok "… as two lines with those ids" eq "$(cut -f2 "$(EV)" | sort -n | tr '\n' ' ')" "1 2 "
long=$(printf 'x%.0s' $(seq 300))
lib feed po ask needs-you 7 - - $'a\tb'"$long" >/dev/null
ok "feed: a tab in the text becomes a space; one field of 200" eq "$(awk -F '\t' 'NR == 3 { print NF, length($9), substr($9, 1, 3) }' "$(EV)")" "9 200 a b"
ok "feed: the line has the contract's fields" eq "$(field 1 1)|$(field 1 3)|$(field 1 4)|$(field 1 5)|$(field 1 6)" \
  "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)|$(field 1 3)|ask|$(field 1 5)|$(field 1 6)"
ok "feed: CANCCU_DRY writes nothing" eq "$(CANCCU_DRY=1 lib feed po ask idle 8 - - x; lines)" 3

# ---------------------------------------------------------------- the writers: no repeats, settling

env_new feed-accept
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 "$HA" green | prs
state 5 phase=check pr=50 "check_at=$NOW"
lib st_set 5 phase=accept pr=50 accept_sha="$HA" "accept_at=$NOW" "reason=manual: changes .github/ (.github/workflows/ci.yml)"
ok "a unit entering accept writes one accept line" eq "$(lines) $(field 1 5) $(field 1 3) $(field 1 4) $(field 1 6) $(field 1 7)" "1 accept po ask 5 50"
ok "… and stores its id" eq "$(st 5 ev_id)" 1
dispatch --once
ok "… the next pass, still waiting, writes nothing" eq "$(lines)" 1
lib st_set 5 phase=merging
ok "… the accept landing writes one closed line" eq "$(lines) $(field 2 5) $(field 2 3) $(field 2 4)" "2 closed - info"
ok "… that closes it" eq "$(field 2 9)" "closes 1: merging"
ok "… and the id goes" eq "$(st 5 ev_id)" ""

env_new feed-quiet
{ issue 5 ready; } | issues
dispatch --once
ok "a started worker writes no line" eq "$(started 5 && echo started) $(lines)" "started 0"
env_new feed-quiet-done
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 done 'all pushed'
pr 50 5 "$HA" pending | prs
dispatch --once
ok "… nor a worker done" eq "$(grep -c '#5 worker done' "$CANCCU_HOME/dispatch.log") $(lines)" "1 0"

env_new feed-needs-you
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 'stopped: time budget 150m' 'I was still running tests'
dispatch --once
ok "a run that ends by a budget writes one run-ended line" eq "$(lines) $(field 1 5) $(field 1 3)" "1 run-ended po"

# a unit's state that goes without a phase write still settles its items
env_new feed-gone
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 "$HA" green | prs
state 5 phase=check pr=50 "check_at=$NOW"
lib st_set 5 phase=accept pr=50 accept_sha="$HA" "accept_at=$NOW" "reason=manual: users see it: web/pages/a.tsx"
json pr50.json '{"state": "MERGED", "title": "feat: thing"}'; route 'pr view 50 *' pr50.json
json issue5.json '{"state": "CLOSED", "labels": [{"name": "in-progress"}]}'; route 'issue view 5 *' issue5.json
echo '[]' > "$FAKE/issues.json"; echo '[]' > "$FAKE/prs.json"
dispatch --once
ok "a unit in accept whose PR is merged by hand: its state goes" test ! -e "$CANCCU_HOME/state/5"
ok "… and its accept line settles" eq "$(grep -cP '\tcloses 1: ' "$(EV)")" 1
env_new feed-forget
state 5 phase=needs-you ev_id=3 idle_ev=4
lib st_rm 5
ok "st_rm: one closed line per item the unit held" eq "$(cut -f5,6,9 "$(EV)" | tr '\t\n' '| ')" "closed|5|closes 3: gone closed|5|closes 4: gone "

# ---------------------------------------------------------------- the idle alarm

env_new feed-idle IDLE_ALARM_MIN=60
{ issue 5 in-progress; } | issues
pr 50 5 "$HA" pending | prs
state 5 phase=check pr=50 "check_at=$NOW" "phase_at=$((NOW - 61 * 60))"
dispatch --once
ok "an idle unit past IDLE_ALARM_MIN writes one idle line" eq "$(lines) $(field 1 5)" "1 idle"
ok "… saying where it sits" eq "$(field 1 9)" "#5 sits in check for 61 min with nothing running"
ok "… and stores it" eq "$(st 5 idle_ev)" 1
dispatch --once
ok "… once" eq "$(lines)" 1
env_new feed-idle-young IDLE_ALARM_MIN=60
{ issue 5 in-progress; } | issues
pr 50 5 "$HA" pending | prs
state 5 phase=check pr=50 "check_at=$NOW" "phase_at=$((NOW - 30 * 60))"
dispatch --once
ok "… a unit under IDLE_ALARM_MIN writes none" eq "$(lines)" 0

# ---------------------------------------------------------------- wait

env_new feed-wait
touch -d "@$NOW" "$CANCCU_HOME/heartbeat"
lib feed leader ask idle 6 - - first >/dev/null
lib feed po ask accept 5 50 - second >/dev/null
out=$(waitcmd --ack 0); rc=$?
ok "wait: a new line → printed, exit 0" eq "$rc $(cut -f2 <<<"$out")" "0 1"
out=$(waitcmd --owner po --ack 0); rc=$?
ok "wait --owner: a line of another owner is skipped" eq "$rc $(cut -f2,3 <<<"$out")" "0 2"$'\t'po
( sleep 1; lib feed po ask plan 7 - - third >/dev/null ) &
out=$(waitcmd --owner po); rc=$?
wait
ok "wait: without --ack, only a line after its start" eq "$rc $(cut -f2 <<<"$out")" "0 3"
touch -d "@$((NOW - 11 * 60))" "$CANCCU_HOME/heartbeat"
out=$(waitcmd --ack 3); rc=$?
ok "wait: a heartbeat 11 minutes old → exit 3" eq "$rc" 3
ok "… saying so" eq "$out" "heartbeat stale: 11 min; the dispatcher may be down"

# ---------------------------------------------------------------- the hand-over (#183)

pings() { grep -cE -- "$1" <(paste <(cut -f2 "$FAKE/gh.env") "$FAKE/gh.log" | grep -P '^reviewer\t' | cut -f2-); }
HO='#5 passed to the product owner: the leader did not acknowledge it in 60 min'
# ho_unit <minutes>: unit 5 in accept for the leader since <minutes>, its accept line id 1
ho_unit() {
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 "$HA" green | prs
  lib feed leader ask accept 5 50 https://example.invalid/50 "#5 accept: plan tier" >/dev/null
  state 5 phase=accept pr=50 accept_sha="$HA" "accept_at=$NOW" "reason=manual: plan tier" owner=leader ev_id=1 \
    "phase_at=$((NOW - $1 * 60))"
}

env_new feed-handover LEADER=on LEADER_ACCEPTS=technical PING_KINDS=all
ho_unit 61
dispatch --once
ok "hand-over: a leader's accept unacked for 61 min → owner po" eq "$(st 5 owner)" po
ok "… one handover line for po" eq "$(lines) $(field 2 3) $(field 2 4) $(field 2 5) $(field 2 6) $(field 2 7) $(field 2 8)" \
  "2 po ask handover 5 50 https://github.com/example-org/web/pull/50"
ok "… saying why" eq "$(field 2 9)" "$HO"
ok "… stored as the unit's item" eq "$(st 5 ev_id)" 2
ok "… and logged" eq "$(grep -cF "$HO" "$CANCCU_HOME/dispatch.log")" 1
ok "… not pinged in the pass that hands it over" eq "$(pings '^issue comment 5 ')" 0
dispatch --once
ok "… the next ping pass pings it" eq "$(pings '^issue comment 5 -R example-org/web --body @octo PR #50 waits for your accept')" 1
ok "… and a second pass writes nothing new" eq "$(lines) $(st 5 owner)" "2 po"

env_new feed-handover-acked LEADER=on LEADER_ACCEPTS=technical PING_KINDS=all
ho_unit 61
waitcmd --owner leader --ack 1 >/dev/null
ok "wait --owner leader --ack: the ack is recorded" eq "$(lib kv_get "$CANCCU_HOME/feed.open" feed leader_ack)" 1
waitcmd --owner leader --ack 0 >/dev/null
waitcmd --owner po --ack 7 >/dev/null
waitcmd --ack 8 >/dev/null
ok "… a lower one, or another owner's, leaves it" eq "$(lib kv_get "$CANCCU_HOME/feed.open" feed leader_ack)" 1
dispatch --once
ok "hand-over: the same item acked → stays the leader's" eq "$(st 5 owner) $(lines)" "leader 1"

env_new feed-handover-young LEADER=on LEADER_ACCEPTS=technical PING_KINDS=all
ho_unit 59
dispatch --once
ok "hand-over: 59 min → no change" eq "$(st 5 owner) $(lines)" "leader 1"

env_new feed-handover-off LEADER=off PING_KINDS=all
ho_unit 61
dispatch --once
ok "hand-over: LEADER=off → nothing" eq "$(lines) $(grep -c 'passed to the product owner' "$CANCCU_HOME/dispatch.log")" "1 0"

echo "canccu-feed tests: $npass passed, $nfail failed"
(( nfail == 0 ))
