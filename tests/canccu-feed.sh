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
cmd() { PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/$1" "${@:2}" > "$E/out" 2>&1; }
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
ok "… one handover line for po, written first" eq "$(lines) $(field 2 3) $(field 2 4) $(field 2 5) $(field 2 6) $(field 2 7) $(field 2 8)" \
  "3 po ask handover 5 50 https://github.com/example-org/web/pull/50"
ok "… then the leader's line closed" eq "$(field 3 5) $(field 3 6) $(field 3 9)" "closed 5 closes 1: passed to the product owner"
ok "… saying why" eq "$(field 2 9)" "$HO"
ok "… stored as the unit's item" eq "$(st 5 ev_id)" 2
ok "… leader brief no longer lists the leader's line" \
  eq "$(lib eval '. "$root/lib/canccu-brief.sh"; brief_open leader; brief_open po' | cut -d' ' -f3-5)" "none
2 · handover"
ok "… and logged" eq "$(grep -cF "$HO" "$CANCCU_HOME/dispatch.log")" 1
ok "… not pinged in the pass that hands it over" eq "$(pings '^issue comment 5 ')" 0
dispatch --once
ok "… the next ping pass pings it" eq "$(pings '^issue comment 5 -R example-org/web --body @octo For the product owner: PR #50 waits for your accept')" 1
ok "… and a second pass writes nothing new" eq "$(lines) $(st 5 owner)" "3 po"

env_new feed-handover-noid LEADER=on LEADER_ACCEPTS=technical PING_KINDS=all
ho_unit 61
lib eval 'feed() { return 1; }; feed_handover'
ok "hand-over: an ask that returns no id leaves the leader's line open and the owner as it was" \
  eq "$(st 5 owner) $(st 5 ev_id) $(lines)" "leader 1 1"

env_new feed-leader-first
lib feed leader ask idle 6 - - two >/dev/null
lib feed leader ask idle 7 - - three >/dev/null
ok "wait --owner leader without --ack, never acked: the lines queued before the first start are delivered" \
  eq "$(waitcmd --owner leader | cut -f2)" 1

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

env_new feed-handover-rekind LEADER=on LEADER_ACCEPTS=technical PING_KINDS=all
ho_unit 120
printf 'ev_at=%s\n' "$((NOW - 59 * 60))" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "hand-over: a phase 2 h old, its item's line 59 min → no change" eq "$(st 5 owner) $(lines)" "leader 1"
printf 'ev_at=%s\n' "$((NOW - 61 * 60))" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "… its line 61 min → owner po" eq "$(st 5 owner)" po

env_new feed-handover-off LEADER=off PING_KINDS=all
ho_unit 61
dispatch --once
ok "hand-over: LEADER=off → nothing" eq "$(lines) $(grep -c 'passed to the product owner' "$CANCCU_HOME/dispatch.log")" "1 0"

# ---------------------------------------------------------------- watch and stall (#216 D5)

watchcmd() { PATH="$fb:$PATH" CANCCU_WAIT_EVERY=1 timeout 30 "$root/bin/canccu-dispatcher" watch "$@"; }
stallcmd() { PATH="$fb:$PATH" timeout 30 "$root/bin/canccu-dispatcher" stall; }
env_new feed-watch
touch -d "@$NOW" "$CANCCU_HOME/heartbeat"
L=$CANCCU_HOME/dispatch.log
printf '%s\n' "2030-11-05T11:00:00Z #5: PR #50 awaiting accept (an old line)" "2030-11-05T11:00:01Z #5 started" > "$L"
echo "an old note" > "$E/extra"
( sleep 2; echo "2030-11-05T12:00:00Z #6: PR #60 awaiting accept" >> "$L"; echo "2030-11-05T12:00:01Z #7 started" >> "$L"
  sleep 1; echo "2030-11-05T12:00:02Z step 4 Search is done: checkpoint #95" >> "$L" ) &
out=$(watchcmd --settle 3); rc=$?
wait
ok "watch: the first run prints no old line; the matching lines after the settle, exit 0" \
  eq "$rc|$out" "0|2030-11-05T12:00:00Z #6: PR #60 awaiting accept"$'\n'"2030-11-05T12:00:02Z step 4 Search is done: checkpoint #95"
ok "… the offsets kept in watch.offsets" grep -qP "^\Q$L\E\t$(stat -c %s "$L")$" "$CANCCU_HOME/watch.offsets"
( sleep 2; echo "a new note" >> "$E/extra" ) &
SECONDS=0; out=$(watchcmd --settle 100 --file "$E/extra"); rc=$?
wait
ok "watch --file: a new line of the file exits at once; no old line, no log line seen before" eq "$rc|$out|$(( SECONDS < 20 ))" "0|a new note|1"
echo "2030-11-05T12:10:00Z step 4 Search: checkpoint #95 waits for checkpoint-ok" >> "$L"
out=$(watchcmd --settle 1); rc=$?
ok "watch: a second run starts at the saved offsets" eq "$rc|$out" "0|2030-11-05T12:10:00Z step 4 Search: checkpoint #95 waits for checkpoint-ok"
printf '2030-11-05T12:20:00Z #8: PR #80 awaiting accept\n2030-11-05T12:20:01Z #9 needs-you: x' > "$L"
out=$(watchcmd --settle 1); rc=$?
ok "watch: a shorter file restarts at 0; a line without its newline waits" eq "$rc|$out" "0|2030-11-05T12:20:00Z #8: PR #80 awaiting accept"
touch -d "@$((NOW - 11 * 60))" "$CANCCU_HOME/heartbeat"
out=$(watchcmd --settle 1); rc=$?
ok "watch: a heartbeat 11 minutes old → exit 3, saying so" eq "$rc|$out" "3|heartbeat stale: 11 min; the dispatcher may be down"

env_new feed-stall
mkdir -p "$CANCCU_HOME/steps"; printf 'phase=running\ntitle=4 Search\n' > "$CANCCU_HOME/steps/12"
printf 'phase=done\ntitle=3 Import\n' > "$CANCCU_HOME/steps/11"
touch -d "@$((NOW - 3 * 3600 - 60))" "$CANCCU_HOME/dispatch.log"
json prs.json '[{"number":50,"author":{"login":"octo"},"mergeable":"CONFLICTING"},{"number":51,"author":{"login":"octo"},"mergeable":"MERGEABLE"},{"number":52,"author":{"login":"review-bot"},"mergeable":"CONFLICTING"}]'
json runs.json "$(jq -n --arg a "$(date -u -d "@$((NOW - 61 * 60))" +%FT%TZ)" --arg b "$(date -u -d "@$((NOW - 30 * 60))" +%FT%TZ)" \
  '[{databaseId: 7001, workflowName: "CI", startedAt: $a}, {databaseId: 7002, workflowName: "CI", startedAt: $b}]')"
three="stall: PR #50 conflicts with main (no CI runs until it merges main)
stall: CI run 7001 (CI) in progress for 61 min
stall: dispatch.log silent for 3 h while step 4 Search is running"
out=$(stallcmd); rc=$?
ok "stall: one line per kind, exit 0" eq "$rc|$out" "0|$three"
json runs.json "$(jq '[.[0]]' "$FAKE/runs.json")"   # run 7002 would pass 60 min in the hour
out=$(CANCCU_NOW=$((NOW + 3600)) stallcmd)
ok "… an hour later: none" eq "$out" ""
out=$(CANCCU_NOW=$((NOW + 3 * 3600)) stallcmd)
ok "… 3 hours later: all three again" eq "$out" "$(sed -e 's/for 61 min/for 241 min/' -e 's/for 3 h/for 6 h/' <<<"$three")"
rm -f "$CANCCU_HOME/stall.seen"; route 'run list*' FAIL
out=$(stallcmd 2>/dev/null); rc=$?
ok "stall: a gh error skips that kind only" eq "$rc|$(grep -c '^stall: ' <<<"$out")|$(grep -c 'CI run [0-9]' <<<"$out")" "0|2|0"

echo "canccu-feed tests: $npass passed, $nfail failed"
(( nfail == 0 ))
