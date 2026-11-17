#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-usage.sh — offline tests for the usage throttle and the weekly drain mode.
# Harness: tests/lib/harness.sh.
#   bash tests/canccu-usage.sh    one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# use <5-hour share> <weekly share> [project] [age s]: a usage reading written by a run
use() {
  local d="$CANCCU_ROOT/projects/${3:-canccu}/workers"; mkdir -p "$d"
  jq -n --argjson f "$1" --argjson w "$2" --argjson at "$((NOW - ${4:-60}))" --argjson r "$((NOW + 3600))" --argjson wr "$((NOW + 86400))" \
    '{at: $at, info: {status: "allowed", unifiedWindows: {five_hour: {utilization: ($f / 100), resetsAt: $r}, seven_day: {utilization: ($w / 100), resetsAt: $wr}}}}' > "$d/usage.json"
}

# ---------------------------------------------------------------- the source: the stream's rate_limit_event

env_new usage-stream
printf '%s\n' '{"type":"system","subtype":"init"}' \
  '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.42,"resetsAt":1920205800,"status":"allowed"},"seven_day":{"utilization":0.5,"resetsAt":1920286800,"status":"allowed"}}}}' \
  '{"type":"result","subtype":"success","total_cost_usd":0.01,"num_turns":1,"result":"ok"}' |
  python3 -I "$root/lib/canccu-stream.py" "$E/log" "$E/sum" 5 "$WORKERS_DIR/usage.json"
ok "usage: the stream's rate_limit_event is written to usage.json" \
  eq "$(jq -c '[.info.unifiedWindows.five_hour.utilization, .info.unifiedWindows.seven_day.resetsAt, (.at > 0)]' "$WORKERS_DIR/usage.json")" "[0.42,1920286800,true]"
ok "… the run's summary is unchanged" eq "$(jq -r .cost "$E/sum")" "0.01"

env_new usage-read
ok "usage: none at all → unknown, normal, nothing throttled" eq "$(lib usage_read) $(lib usage_state) $(lib usage_cap)" "- - - - - normal 3"
use 30 40; use 55 41 web 10
ok "usage: the newest reading over all projects counts" eq "$(lib usage_read | cut -d' ' -f1,2)" "55 41"
jq --argjson r "$((NOW - 5))" '.info.unifiedWindows.five_hour.resetsAt = $r' "$CANCCU_ROOT/projects/web/workers/usage.json" > "$E/u" && mv "$E/u" "$CANCCU_ROOT/projects/web/workers/usage.json"
ok "usage: a window past its reset counts as 0" eq "$(lib usage_read | cut -d' ' -f1,2)" "0 41"

# ---------------------------------------------------------------- USAGE_MAX_AGE_MIN: an old reading is unknown (#64)

env_new usage-stale
use 20 96 web $((7 * 3600))
ok "usage: weekly 96%, 7 hours old → unknown: normal, nothing throttled" \
  eq "$(lib usage_read) | $(lib usage_state) $(lib usage_cap)" "- - - - $((NOW - 7 * 3600)) | normal 3"
ok "… the text says how old the last reading is" eq "$(lib usage_text)" "usage unknown (last reading 7 h old)"
use 20 96 web 600
ok "… the same reading 10 minutes old → drain, the text ends with its age" \
  eq "$(lib usage_state) | $(lib usage_text)" "drain | draining (weekly 96%) (10 min old)"
use 20 50 web 600
ok "… a normal text gains the age too" eq "$(lib usage_text)" "5-hour 20% · weekly 50% (10 min old)"
use 20 96 web 600; touch -d "@$((NOW - 300))" "$CANCCU_HOME/dispatch.pid"
ok "… 10 minutes old but older than this dispatcher's start (dispatch.pid) → unknown" \
  eq "$(lib usage_state) | $(lib usage_text)" "normal | usage unknown (last reading 10 min old)"
env_new usage-stale-off USAGE_MAX_AGE_MIN=0
use 20 96 web $((7 * 3600))
ok "USAGE_MAX_AGE_MIN=0, no dispatch.pid: a 7-hour-old reading counts, as before" \
  eq "$(lib usage_state) | $(lib usage_text)" "drain | draining (weekly 96%) (7 h old)"

# ---------------------------------------------------------------- USAGE_SLOW: one run at a time over all projects

env_new usage-slow
use 60 10
{ issue 5 ready; issue 6 ready; } | issues
dispatch --once
ok "usage: 5-hour 60% → one run at a time; the fast lane counts too" eq "$(grep -c -- '^--quiet' "$FAKE/worker.log")" 1
ok "… the state is slow" eq "$(lib usage_state) $(lib usage_text)" "slow one run at a time (5-hour 60%) (1 min old)"
live_lock 5
mkdir -p "$CANCCU_ROOT/projects/web/workers"
dispatch --once
ok "… a second start is refused while one runs" eq "$(grep -c -- '^--quiet' "$FAKE/worker.log")" 1

# ---------------------------------------------------------------- USAGE_STOP: no run, the nudge, limited

env_new usage-stop
use 91 10
{ issue 5 in-progress; issue 6 ready; } | issues
state 5 phase=work "started=$NOW"; live_lock 5
dispatch --once
ok "usage: 5-hour 90% → no run starts" not started 6
ok "… the running worker gets a nudge file, once" eq "$(test -e "$WORKERS_DIR/web-5.nudge" && echo nudged) $(st 5 nudged)" "nudged 1"
dispatch --once
ok "… logged once" eq "$(grep -c 'asked to stop at a safe point' "$CANCCU_HOME/dispatch.log")" 1
rm -f "$WORKERS_DIR/web-5.lock"; last 5 done $'Done: the parser\nLeft: its tests\nNext step: test the parser\nHead: abc1234'
dispatch --once
ok "usage: a nudged worker that ends done → limited, back-off until the reset" \
  eq "$(st 5 phase) $(( $(cat "$CANCCU_ROOT/backoff") >= NOW + 3600 ))" "limited 1"
ok "… its final message is stored as its handoff (#82)" grep -qx 'Next step: test the parser' "$CANCCU_HOME/handoffs/5.md"
mkdir -p "$WORKERS_DIR/worktrees/web/issue-5" && touch "$WORKERS_DIR/worktrees/web/issue-5/.git"
printf 'abc1234 wip: the parser\n' > "$FAKE/gitlog"; printf ' src/parse.ts | 40 ++++\n 1 file changed\n' > "$FAKE/diffstat"
rm -f "$CANCCU_ROOT/backoff"; use 20 10
dispatch --once
l=$(grep -- '--name #5 ' "$FAKE/worker.log" | tail -1)
ok "… after the reset a fresh session, never --resume (#82)" grep -q -- '--name #5 --fresh web 5 Rules for this run: .* The usage limit has reset' <<<"$l"
ok "… with the handoff" grep -qF 'Next step: test the parser' <<<"$l"
ok "… the commit log" grep -qF 'abc1234 wip: the parser' <<<"$l"
ok "… and the diff stat" grep -qF 'src/parse.ts | 40' <<<"$l"
ok "… the handoff is used once" test ! -e "$CANCCU_HOME/handoffs/5.md"
ok "… and its nudge file is gone" test ! -e "$WORKERS_DIR/web-5.nudge"

# the hard limit hit before any nudge: no handoff, a fresh session that checks git status (#82)
env_new usage-hard
{ issue 5 in-progress; } | issues
mkdir -p "$CANCCU_HOME/handoffs"; echo 'Next step: an old one' > "$CANCCU_HOME/handoffs/5.md"
state 5 phase=work "started=$NOW"; last 5 error "Claude AI usage limit reached|$((NOW + 3600))"
dispatch --once
ok "usage: the hard limit → limited, no handoff kept" eq "$(st 5 phase) $(test -e "$CANCCU_HOME/handoffs/5.md" && echo kept)" "limited "
rm -f "$CANCCU_ROOT/backoff"
dispatch --once
l=$(grep -- '--name #5 ' "$FAKE/worker.log" | tail -1)
ok "… after the reset a fresh session" grep -q -- '--name #5 --fresh web 5 Rules for this run: .* The usage limit has reset' <<<"$l"
ok "… told to check git status for uncommitted work" grep -qF 'check git status for uncommitted work' <<<"$l"
ok "… no stale handoff" not grep -qF 'an old one' <<<"$l"

env_new usage-resume-on RESUME_ON=limited
use 20 10
{ issue 5 in-progress; } | issues
state 5 phase=limited
dispatch --once
ok "usage: RESUME_ON=limited brings the old resume back (#82)" grep -q -- '--name #5 web 5 Continue where you stopped' "$FAKE/worker.log"

# reviewers and planners cut off by the limit rerun fresh: the engine never resumes their keys (#82)
env_new usage-fresh-keys
mkdir -p "$E/wt"
for k in review-9 plan-3; do
  echo old-session > "$WORKERS_DIR/web-$k.id"
  printf 'repo=web\nkey=%s\nkind=worker\npid=\nwindow=\n' "$k" > "$WORKERS_DIR/web-$k.lock"
  PATH="$fb:$PATH" CODE_ROOT="$E/code" "$root/libexec/canccu-worker" __run web "$k" 5 1 2 "" "a prompt" "$E/wt" user > /dev/null 2>&1
  ok "usage: a $k run reruns in a fresh session" eq "$(grep -c -- '--resume' <<<"$(tail -1 "$FAKE/claude.args")")" 0
done

env_new usage-hook
out=$(echo '{}' | WORKER_NUDGE_FILE="$E/none" "$root/libexec/canccu-nudge-hook")
ok "usage: the nudge hook prints nothing without the file" eq "$out" ""
touch "$E/n"; out=$(echo '{}' | WORKER_NUDGE_FILE="$E/n" "$root/libexec/canccu-nudge-hook")
ok "… with it, the stop context for the run" eq "$(jq -r '.hookSpecificOutput | .hookEventName + ": " + (.additionalContext | test("without running tests.*Done:.*Left:.*Next step:.*Decisions made:.*Test state:.*Head:") | tostring)' <<<"$out")" "PostToolUse: true"
mkdir -p "$E/wt"; printf 'repo=web\nkey=7\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-7.lock"
PATH="$fb:$PATH" CODE_ROOT="$E/code" "$root/libexec/canccu-worker" __run web 7 5 1 2 "" "a prompt" "$E/wt" "" > /dev/null 2>&1
ok "usage: a worker run gets the hook in its settings" grep -qF 'canccu-nudge-hook' <<<"$(tail -1 "$FAKE/claude.args")"
printf 'repo=web\nkey=review-9\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-review-9.lock"
PATH="$fb:$PATH" CODE_ROOT="$E/code" "$root/libexec/canccu-worker" __run web review-9 5 1 2 "" "a prompt" "$E/wt" user > /dev/null 2>&1
ok "… an untrusted run (a review) does not" not grep -qF 'canccu-nudge-hook' <<<"$(tail -1 "$FAKE/claude.args")"

# review 3, finding 3: a nudged worker that ends after the reset it was nudged for: no back-off
env_new usage-late
use 20 10
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW" nudged=1 "nudge_reset=$((NOW - 60))"
rm -f "$WORKERS_DIR/web-5.lock"; last 5 done $'WIP pushed.\nNext action: x'
dispatch --once
ok "usage (review 3, finding 3): ended after its reset → no back-off for anyone, it continues" \
  eq "$(test -s "$CANCCU_ROOT/backoff" && echo backoff || echo none) $(grep -c -- '--name #5 --fresh web 5 Rules for this run: .* The usage limit has reset' "$FAKE/worker.log")" "none 1"

# ---------------------------------------------------------------- USAGE_WEEKLY_DRAIN: drain mode

env_new usage-drain
use 20 92
{ issue 5 in-progress; issue 6 ready; issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; } | issues
jq -nc '{number: 12, title: "3 Events", open_issues: 2, closed_issues: 0}' | jq -s . > "$FAKE/ms.json"
json c90.json '{"comments": []}'; route 'issue view 90 *' c90.json
p=$(pr 50 5 "$HA"); printf '%s\n' "$p" | prs; json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
state 5 phase=check pr=50 "check_at=$NOW"
dispatch --once
ok "usage: weekly 92% → drain: no fast-lane, planner or package start" eq "$(started 6 && echo fast) $(grep -c -- '--key plan-' "$FAKE/worker.log")" " 0"
ok "… a PR in the pipeline still gets its review" grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… the text says draining" eq "$(lib usage_text)" "draining (weekly 92%) (1 min old)"
use 75 92
ok "usage (review 2, finding 6): drain mode keeps the USAGE_SLOW one-run cap" eq "$(lib usage_state) $(lib usage_cap)" "drain 1"
rm -f "$WORKERS_DIR/web-review-50.lock"; use 20 50
dispatch --once
ok "usage: weekly below the threshold again → drain ends, new work starts" started 6

# ---------------------------------------------------------------- status, snapshot and monitor

env_new usage-show
use 30 93
dispatch --once
ok "usage: the snapshot shows the shares and the state" \
  eq "$(jq -c '.usage | [.five_hour, .seven_day, .state, .text]' "$CANCCU_HOME/status.json")" '[30,93,"drain","draining (weekly 93%) (1 min old)"]'
ok "usage: canccu-status shows them" grep -qx 'usage: draining (weekly 93%) (1 min old)' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"
if [ -x "$MON_VENV/bin/python" ]; then
  out=$("$MON_VENV/bin/python" -I "$root/lib/canccu-monitor.py" --file "$CANCCU_HOME/status.json" --once --width 160 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
  ok "usage: the monitor's header shows 'draining (weekly 93%)'" grep -qF 'draining (weekly 93%)' <<<"$out"
else ok "usage: the monitor needs rich (the suite fails rather than skips)" false; fi

# ---------------------------------------------------------------- canccu-resume --usage (#110)

# usage_env <name>: a back-off in the future and a reading at 100 % in projects a and b
usage_env() {
  env_new "$1"
  local q; for q in a b; do
    mkdir -p "$CANCCU_ROOT/projects/$q"; cp "$CANCCU_HOME/config" "$CANCCU_HOME/rules" "$CANCCU_ROOT/projects/$q/"; use 100 50 "$q"
  done
  echo "$((NOW + 3600))" > "$CANCCU_ROOT/backoff"
}
usage_env resume-usage
ok "usage: at 100 % nothing starts" eq "$(lib usage_cap)" 0
PATH="$fb:$PATH" "$root/bin/canccu-resume" --usage --project a > "$E/out" 2> "$E/err"
ok "canccu-resume --usage: the back-off and every project's reading are gone" \
  eq "$(ls "$CANCCU_ROOT/backoff" "$CANCCU_ROOT"/projects/*/workers/usage.json 2>/dev/null | wc -l)" 0
ok "… said in project a's log" grep -qF 'usage limit cleared (canccu-resume --usage): runs start again' "$CANCCU_ROOT/projects/a/dispatch.log"
ok "… runs start again" eq "$(lib usage_cap)" "$(lib eval 'echo "$TOTAL_CAP"')"
ok "… nothing on stderr" eq "$(cat "$E/err")" ""

usage_env resume-plain
PATH="$fb:$PATH" "$root/bin/canccu-resume" --project a > "$E/out" 2> "$E/err"
ok "canccu-resume without --usage: the back-off and the readings stay" \
  eq "$(ls "$CANCCU_ROOT/backoff" "$CANCCU_ROOT"/projects/*/workers/usage.json 2>/dev/null | wc -l)" 3
ok "… nothing on stderr" eq "$(cat "$E/err")" ""

# ---------------------------------------------------------------- pacing (#216 D6)

# puse <weekly share> <days to the weekly reset> [age s]: a reading of project web
puse() {
  mkdir -p "$WORKERS_DIR"
  jq -n --argjson w "$1" --argjson at "$((NOW - ${3:-60}))" --argjson wr "$((NOW + $2 * 86400))" \
    '{at: $at, info: {unifiedWindows: {five_hour: {utilization: 0.1, resetsAt: ($at + 3600)}, seven_day: {utilization: ($w / 100), resetsAt: $wr}}}}' > "$WORKERS_DIR/usage.json"
}
plog() { grep -c -- "$1" "$CANCCU_HOME/dispatch.log"; }
env_new pace-cap PACE=cap
puse 60 4
ok "pace: weekly 60%, 3 of 7 days gone → 60 43 17" eq "$(lib pace_read)" "60 43 17"
ok "PACE=cap ahead: usage_cap is PACE_CAP (1)" eq "$(lib usage_cap)" 1
dispatch --once; dispatch --once
ok "… the ahead line once over two passes" \
  eq "$(plog 'pace: weekly usage 60% is 17 points ahead of the week (43% gone, PACE_MARGIN 10); PACE=cap: at most 1 run(s) at once over all projects')" 1
ok "… kept in pace" grep -qx "since=$NOW" "$CANCCU_HOME/pace"
ok "… no hold line in the feed (cap)" not grep -q 'hold' "$CANCCU_HOME/events"
puse 45 4
ok "weekly 45%: usage_cap is TOTAL_CAP again" eq "$(lib usage_cap)" 3
dispatch --once; dispatch --once
ok "… the back-on-pace line once" eq "$(plog 'pace: back on pace (weekly 45%, 43% of the week gone); PACE=cap no longer limits runs')" 1
ok "… pace removed" not test -e "$CANCCU_HOME/pace"
ok "pacing never writes CAP or TOTAL_CAP" not grep -qE '^(TOTAL_)?CAP=1' "$CANCCU_HOME/config"

env_new pace-pause PACE=pause
{ issue 5 in-progress; issue 6 ready; } | issues
state 5 phase=limited
puse 60 4
ok "PACE=pause ahead: draining, usage_cap unchanged" eq "$(lib draining && echo drain) $(lib usage_cap)" "drain 3"
dispatch --once
ok "… nothing new starts" not started 6
ok "… the stopped run resumes, as under the weekly drain: started work finishes" eq "$(st 5 phase)" work
ok "… a hold line (info) in the feed" grep -qP '\t-\tinfo\thold\t.*pace: weekly usage 60% is ahead of the week; nothing new starts until it is back on pace$' "$CANCCU_HOME/events"
puse 45 4
dispatch --once
ok "… back on pace: its closed line" grep -qP '\tclosed\t.*: back on pace$' "$CANCCU_HOME/events"
ok "… the new issue starts" started 6

# PACE changed while ahead: the effect follows the new mode each pass, logged once, and the hold
# line goes with pause (and comes back with it)
env_new pace-switch PACE=pause
puse 60 4; dispatch --once
sed -i 's/^PACE=.*/PACE=cap/' "$CANCCU_HOME/config"; dispatch --once; dispatch --once
ok "PACE pause → cap while ahead: the change logged once, the mode kept" \
  eq "$(plog 'pace: PACE is now cap while 17 points ahead: at most 1 run(s) at once over all projects') $(sed -n 's/^mode=//p' "$CANCCU_HOME/pace") $(grep -c "^since=$NOW$" "$CANCCU_HOME/pace")" "1 cap 1"
ok "… the hold line is closed" grep -qP '\tclosed\t.*: PACE is now cap$' "$CANCCU_HOME/events"
sed -i 's/^PACE=.*/PACE=pause/' "$CANCCU_HOME/config"; dispatch --once
ok "… back to pause: the hold line again" \
  eq "$(grep -cP '\t-\tinfo\thold\t.*nothing new starts until it is back on pace$' "$CANCCU_HOME/events") $(plog 'pace: PACE is now pause while 17 points ahead: nothing new starts')" "2 1"

env_new pace-notify PACE=notify
puse 60 4
dispatch --once
ok "PACE=notify ahead: no limit" eq "$(lib usage_cap) $(lib draining && echo drain)" "3 "
ok "… the line says notice only" eq "$(plog 'PACE=notify: notice only')" 1

env_new pace-stale PACE=cap
puse 60 4; dispatch --once
puse 60 4 $((7 * 3600))
ok "a stale reading while ahead: no limit" eq "$(lib usage_cap)" 3
dispatch --once; dispatch --once
ok "… the pace state cleared, logged once, no back-on-pace line" \
  eq "$(plog 'pace: the weekly reading is stale or unknown; PACE=cap limits nothing until a fresh one') $(plog 'back on pace') [$([ -e "$CANCCU_HOME/pace" ] && echo kept)]" "1 0 []"
# PACE=pause: the hold line closes with the stale reading, so feed, digest and canccu-status
# --pace say what happens (nothing held)
env_new pace-stale-pause PACE=pause
puse 60 4; dispatch --once
puse 60 4 $((7 * 3600)); dispatch --once
ok "PACE=pause, the reading goes stale while ahead: nothing held, the hold line closed (reading stale)" \
  eq "[$(lib pace_holds && echo hold)] $(grep -cP '\tclosed\t.*: reading stale$' "$CANCCU_HOME/events")" "[] 1"
ok "… canccu-status --pace: unknown, on pace" eq "$(PATH="$fb:$PATH" "$root/bin/canccu-status" --pace 2>&1 | head -2)" "weekly usage unknown (no fresh reading)
PACE=pause · margin 10 · on pace"
puse 60 4; dispatch --once
ok "… a fresh reading still ahead: ahead again, the hold line back" \
  eq "$(grep -c "^since=$NOW$" "$CANCCU_HOME/pace") $(grep -cP '\t-\tinfo\thold\t.*nothing new starts until it is back on pace$' "$CANCCU_HOME/events")" "1 2"

env_new pace-off
puse 60 4; dispatch --once
ok "PACE=off (the default): no line, no limit" eq "$(plog 'pace:') $(lib usage_cap) $([ -e "$CANCCU_HOME/pace" ] && echo file)" "0 3 "

# ---------------------------------------------------------------- canccu-status --pace (#216 D5)

statuspace() { PATH="$fb:$PATH" "$root/bin/canccu-status" --pace 2>&1; }
env_new pace-report PACE=cap
puse 60 4; dispatch --once
printf '%s\tweb\t5\t1.50\n%s\tweb\t6\t?\n%s\tweb\t7\t2.25\n%s\ttools\t8\t9.00\n%s\tweb\t9\t4.00\n' \
  "$((NOW - 3600))" "$((NOW - 7200))" "$((NOW - 86400))" "$((NOW - 3600))" "$((NOW - 8 * 86400))" > "$WORKERS_DIR/spend.log"
ok "canccu-status --pace: the weekly line, the PACE line, the spend per day" eq "$(statuspace)" "weekly 60% · 43% of the week gone · 17 points ahead · resets 2030-11-09T12:00:00Z
PACE=cap · margin 10 · ahead since 2030-11-05T12:00:00Z: at most 1 run(s) at once over all projects
spend of this project's runs, last 7 days (UTC), newest first:
  2030-11-05 \$1.50 (2 runs)
  2030-11-04 \$2.25 (1 runs)
  2030-11-03 \$0.00 (0 runs)
  2030-11-02 \$0.00 (0 runs)
  2030-11-01 \$0.00 (0 runs)
  2030-10-31 \$0.00 (0 runs)
  2030-10-30 \$0.00 (0 runs)"
puse 30 4; dispatch --once
ok "… behind the week: points behind, on pace" eq "$(statuspace | head -2)" "weekly 30% · 43% of the week gone · 13 points behind · resets 2030-11-09T12:00:00Z
PACE=cap · margin 10 · on pace"
env_new pace-report-none
ok "… no reading: weekly usage unknown" eq "$(statuspace | head -2)" "weekly usage unknown (no fresh reading)
PACE=off · margin 10 · on pace"

echo "canccu-usage tests: $npass passed, $nfail failed"
(( nfail == 0 ))
