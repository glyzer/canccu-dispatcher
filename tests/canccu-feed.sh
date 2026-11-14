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

# ---------------------------------------------------------------- the actions log's other writers (#186)

env_new actions-cmds
{ issue 5 in-progress; } | issues
cmd() { PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/$@" > "$E/out" 2>&1; }
cmd canccu-pause; cmd canccu-resume --usage; cmd canccu-stop 5; cmd canccu-run x
ok "canccu-pause, -resume, -stop and -run each write one line: actor, command, unit, result" eq "$(cut -f2- "$CANCCU_HOME/actions.log")" "po	canccu-pause	-	ok
po	canccu-resume --usage	-	ok
po	canccu-stop	5	ok
po	canccu-run	-	exit 2"
ok "… the time as the feed has it" eq "$(cut -f1 "$CANCCU_HOME/actions.log" | sort -u)" "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$CANCCU_HOME/actions.log"; mkdir "$CANCCU_HOME/actions.log"
cmd canccu-pause; rc=$?
ok "a failed actions-log write never fails the command" eq "$rc $(test -e "$CANCCU_HOME/paused" && echo paused)" "0 paused"

# ---------------------------------------------------------------- leader brief (#186)

env_new feed-brief LEADER=on
lib feed leader ask accept 5 50 https://example.invalid/50 "#5 accept: lead line" >/dev/null
lib feed po ask needs-you 6 - - "#6 needs-you: po line" >/dev/null
lib feed leader ask idle 7 - - "#7 sits in work" >/dev/null
lib feed_closed 3 work 7
for i in $(seq 12); do printf '2030-11-05T11:%02d:00Z\tpo\tcanccu-pause\t-\tok%s\n' "$i" "$i"; done > "$CANCCU_HOME/actions.log"
cp "$(EV)" "$E/ev.before"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-dispatcher" leader brief --project web 2>&1); rc=$?
ok "leader brief: exit 0, the status header first" eq "$rc $(head -1 <<<"$out" | cut -d' ' -f1)" "0 canccu-dispatcher"
ok "… the leader's open line under its heading" eq "$(sed -n '/^open for the leader:/,/^open for the product owner:/p' <<<"$out" | sed '1d;$d')" \
  "  1 · accept · 5 · PR 50 · #5 accept: lead line"
ok "… the product owner's under its own" eq "$(sed -n '/^open for the product owner:/,/^next:/p' <<<"$out" | sed '1d;$d')" \
  "  2 · needs-you · 6 · no PR · #6 needs-you: po line"
ok "… next: the queue as canccu-status lists it" grep -q '^  queue (fast lane, next 5 runnable): ' <<<"$out"
ok "… the last 10 actions-log lines, the newest last" eq "$(sed -n '/^actions (last 10):/,$p' <<<"$out" | sed '1d' | awk -F '\t' '{ print $5 }' | tr '\n' ' ')" \
  "ok3 ok4 ok5 ok6 ok7 ok8 ok9 ok10 ok11 ok12 "
ok "… and changes nothing: the feed as it was, no actions-log line" eq "$(cmp -s "$(EV)" "$E/ev.before"; echo $?) $(wc -l < "$CANCCU_HOME/actions.log")" "0 12"
env_new feed-brief-empty
out=$(PATH="$fb:$PATH" "$root/bin/canccu-dispatcher" leader brief 2>&1); rc=$?
ok "leader brief with no feed and no actions log: none under each heading" eq "$rc $(grep -c '^  none$' <<<"$out")" "0 3"

echo "canccu-feed tests: $npass passed, $nfail failed"
(( nfail == 0 ))
