#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-steps2.sh — offline tests for the steps, part 2: waves, cross-step blockers,
# the health pass, the checkpoint, notes and the step budget. Harness: tests/lib/harness.sh.
#   bash tests/canccu-steps2.sh   one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

ms() { jq -nc --argjson n "$1" --arg t "$2" --argjson c "${3:-0}" '{number: $n, title: $t, open_issues: 0, closed_issues: $c, due_on: null}'; }
cpi() { jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" --arg l "${4:-}" '{number: $n, title: "Checkpoint \($n)", state: $s, milestone: {title: $m},
  labels: ([{name: "checkpoint"}] + ($l | split(",") | map(select(. != "")) | map({name: .})))}'; }
# senv <name> <closed issues> [config...]: step "3 Events" (milestone 12), epic 90, checkpoint 95 open
senv() {
  local n=$1 c=$2; shift 2
  env_new "$n" "$@"
  ms 12 "3 Events" "$c" | jq -s . > "$FAKE/ms.json"; cpi 95 OPEN "3 Events" | jq -s . > "$FAKE/cps.json"
  json c90.json '{"comments": []}'; route 'issue view 90 *' c90.json; route 'api -X PATCH *' empty.json
}
# wave <w> <plan json> [phase]: the step runs this plan
wave() {
  mkdir -p "$CANCCU_HOME/steps"; printf '%s\n' "$2" > "$CANCCU_HOME/steps/12.plan-$1.json"
  printf 'phase=%s\nwave=%s\nplan=%s\nstarted_at=%s\ntitle=3 Events\nepic=90\ncheckpoint=95\n' "${3:-running}" "$1" "$CANCCU_HOME/steps/12.plan-$1.json" "$((NOW - 3600))" > "$CANCCU_HOME/steps/12"
}
merged_pkg() { printf '%s\t%s\t1\t%s\tnormal\t%s\tmerged\n' "$1" "$2" "$3" "$4" >> "$CANCCU_HOME/steps/12.packages"; }
P2='{"schema":1,"step":12,"wave":1,"packages":[
  {"name":"a","issues":[101,103],"risk":"normal","risk_reason":"x","areas":[],"depends_on":[]},
  {"name":"b","issues":[104],"risk":"low","risk_reason":"y","areas":[],"depends_on":["a"]}]}'
plans() { grep -c -- '--key plan-12' "$FAKE/worker.log"; }
# planned <w> <plan json>: the running planner of wave w ended with this plan as its final message
# (a plan whose wave is not w is a mistake in the test: counted as a failure)
planned() {
  [ "$(jq -r .wave <<<"$2")" = "$1" ] || { nfail=$((nfail + 1)); echo "FAIL [$tname] planned $1: the plan is of wave $(jq -r .wave <<<"$2")"; }
  rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 done "$2"
}

# ---------------------------------------------------------------- waves (task 8)

senv waves 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"
  issue 104 ready "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
wave 1 "$P2"; state pkg-12-a pkg=a step=12 wave=1 "members=101 103" branch=pkg-12-a phase=work
live_lock pkg-12-a
dispatch --once
ok "waves: a package still running → no planner, its dependant waits" eq "$(plans) $(grep -c -- '--name #104' "$FAKE/worker.log")" "0 0"
ok "… an issue added mid-wave (105) is not started" not grep -q -- '#105' "$FAKE/worker.log"
rm -f "$WORKERS_DIR/web-pkg-12-a.lock" "$CANCCU_HOME/state/pkg-12-a"; merged_pkg pkg-12-a a "101 103" 50
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
dispatch --once
ok "waves: its dependency merged → the package of one starts next pass (key 104, branch 104-…)" \
  grep -qE -- '^--quiet --name #104 web 104 .*branch, 104-issue-104,' "$FAKE/worker.log"
ok "… still no planner while it runs" eq "$(plans)" 0
rm -f "$WORKERS_DIR/web-104.lock"; sed -i 's/^phase=.*/phase=needs-you/' "$CANCCU_HOME/state/104"
dispatch --once
ok "waves: all started packages merged or needs-you → a planner for wave 2" eq "$(plans) $(sed -n 's/^planner_wave=//p' "$CANCCU_HOME/steps/12")" "1 2"
ok "… covering what is left: the mid-wave issue, not the needs-you package's" eq "$(pissues)" "#105"
ok "… earlier packages listed for the planner" grep -qF '"name":"a","issues":[101,103],"outcome":"merged"' <<<"$(grep -- '--key plan-12' "$FAKE/worker.log" | tail -1)"

senv waves-blocked 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
wave 1 "$P2"; state pkg-12-a pkg=a step=12 wave=1 "members=101 103" branch=pkg-12-a phase=needs-you
dispatch --once
ok "waves: a package blocked behind a needs-you package does not hold the wave, but its issues wait for it" \
  eq "$(plans) $(pissues)" "1 #105"

# a package waiting for the user's accept holds only its dependants; the next wave is planned
# with what else is runnable, carries the unfinished packages, and an accept that comes later
# lets a dependant run in the wave it was carried into
# acc <n> <name> <pr>: package of one <n> waits for the accept of PR <pr> (open, head HA)
acc() {
  state "$1" pkg="$2" step=12 wave=1 "members=$1" branch="$1-x" phase=accept pr="$3" "accept_sha=$HA" "accept_at=$((NOW - 600))" "reason=manual: risk high"
  pr "$3" "$1" "$HA" | jq -s . > "$FAKE/prs.json"
}
# accepted <n> <name>: its PR merged after the accept: the package is finished and its issue closed
accepted() { rm -f "$CANCCU_HOME/state/$1"; echo '[]' > "$FAKE/prs.json"; merged_pkg "$1" "$2" "$1" 70; }
PA='{"schema":1,"step":12,"wave":1,"packages":[
  {"name":"a","issues":[101],"risk":"high","risk_reason":"x","areas":[],"depends_on":[]},
  {"name":"c","issues":[102],"risk":"low","risk_reason":"y","areas":[],"depends_on":[]}]}'
senv waves-accept 1
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
wave 1 "$PA"; acc 101 a 70; merged_pkg 102 c 102 71
dispatch --once
ok "waves: the rest merged, one package waits for the accept → wave 1 is over, the planner plans wave 2" \
  eq "$(plans) $(sed -n 's/^planner_wave=//p' "$CANCCU_HOME/steps/12")" "1 2"
ok "… with the runnable issue only, not the waiting package's" eq "$(pissues)" "#105"
ok "… the waiting package is named for the planner (its name is taken)" \
    grep -qF '"name":"a","issues":[101],"outcome":"running"' <<<"$(grep -- '--key plan-12' "$FAKE/worker.log" | tail -1)"
planned 2 '{"schema":1,"step":12,"wave":2,"packages":[{"name":"d","issues":[105],"risk":"low","risk_reason":"z","areas":[],"depends_on":[]}]}'
dispatch --once
ok "… wave 2 runs: its package starts while the accept still waits" started 105
ok "… the waiting package is carried into the plan of wave 2" \
  eq "$(jq -c '[.packages[] | "\(.name):\(.carried_from // "-")"]' "$CANCCU_HOME/steps/12.plan-2.json")" '["d:-","a:1"]'
ok "… the plan comment marks it" grep -qF '| a (from wave 1) |' "$FAKE/gh.log"
ok "… and the accept still waits on its PR (nothing merged)" not grep -q '^pr merge 70' "$FAKE/gh.log"

PB='{"schema":1,"step":12,"wave":1,"packages":[
  {"name":"a","issues":[101],"risk":"high","risk_reason":"x","areas":[],"depends_on":[]},
  {"name":"b","issues":[104],"risk":"low","risk_reason":"y","areas":[],"depends_on":["a"]}]}'
senv waves-accept-dep 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
wave 1 "$PB"; acc 101 a 70
dispatch --once
ok "waves: a dependant of a waiting package is held: wave 2 gets only the independent issue" eq "$(plans) $(pissues)" "1 #105"
ok "… the planner sees the held dependant as unfinished (its name is taken), the waiting one once" \
  eq "$(grep -- '--key plan-12' "$FAKE/worker.log" | tail -1 | grep -oE '"name":"[ab]","issues":\[[0-9]+\],"outcome":"[a-z]+"' | tr '\n' ' ')" \
  '"name":"a","issues":[101],"outcome":"running" "name":"b","issues":[104],"outcome":"unfinished" '
planned 2 '{"schema":1,"step":12,"wave":2,"packages":[{"name":"d","issues":[105],"risk":"low","risk_reason":"z","areas":[],"depends_on":[]}]}'
dispatch --once
ok "… wave 2's package starts, the dependant does not" eq "$(started 105 && echo y) $(started 104 && echo y)" "y "
ok "… both are carried, with the dependency" \
  eq "$(jq -c '[.packages[] | "\(.name):\(.depends_on | join(","))"]' "$CANCCU_HOME/steps/12.plan-2.json")" '["d:","a:","b:a"]'
rm -f "$WORKERS_DIR/web-105.lock"; accepted 101 a
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 105 in-progress "" "3 Events"; } | issues
dispatch --once
ok "… the accept came and a merged → its dependant starts in wave 2" started 104
ok "… its state names wave 2" eq "$(st 104 wave)" 2

senv waves-accept-resume 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
wave 1 "$PB"; acc 101 a 70
dispatch --once
ok "waves: only a waiting package and its dependant left → wave over, idle, no planner" \
  eq "$(plans) $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "0 idle"
accepted 101 a
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
dispatch --once
ok "… the accept came → wave 1 goes on: the dependant starts in the wave it was planned in" \
  eq "$(started 104 && echo y) $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12") $(sed -n 's/^wave=//p' "$CANCCU_HOME/steps/12") $(st 104 wave)" "y running 1 1"
ok "… no planner" eq "$(plans)" 0

# a package behind a refused one is released (its issue goes to the planner); if the refused one
# can run again before the plan comes back, the released package is not carried a second time
PR2='{"schema":1,"step":12,"wave":1,"packages":[
  {"name":"r","issues":[201],"risk":"low","risk_reason":"x","areas":[],"depends_on":[]},
  {"name":"q","issues":[202],"risk":"low","risk_reason":"y","areas":[],"depends_on":["r"]}]}'
senv waves-released 0
{ issue 90 epic "" "3 Events"; issue 201 "" "" "3 Events"; issue 202 ready "" "3 Events"; } | issues
wave 1 "$PR2"
dispatch --once
ok "waves: behind a refused package → released, not held: the planner gets its issue" eq "$(plans) $(pissues)" "1 #202"
{ issue 90 epic "" "3 Events"; issue 201 ready "" "3 Events"; issue 202 ready "" "3 Events"; } | issues
planned 2 '{"schema":1,"step":12,"wave":2,"packages":[{"name":"e","issues":[202],"risk":"low","risk_reason":"z","areas":[],"depends_on":[]}]}'
dispatch --once
ok "… the refused one can run again: it is carried, the released one (its issue is in the new plan) is not" \
  eq "$(jq -c '[.packages[].name]' "$CANCCU_HOME/steps/12.plan-2.json")" '["e","r"]'

# review of #70, finding 1: a dependant with one merged and one waiting dependency keeps waiting
# for the waiting one (its carried depends_on names only carried packages), whichever comes first
PM='{"schema":1,"step":12,"wave":1,"packages":[
  {"name":"a","issues":[101],"risk":"low","risk_reason":"x","areas":[],"depends_on":[]},
  {"name":"x","issues":[102],"risk":"high","risk_reason":"y","areas":[],"depends_on":[]},
  {"name":"b","issues":[104],"risk":"low","risk_reason":"z","areas":[],"depends_on":["a","x"]}]}'
PD='{"schema":1,"step":12,"wave":2,"packages":[{"name":"d","issues":[105],"risk":"low","risk_reason":"z","areas":[],"depends_on":[]}]}'
senv waves-merged-dep 1
{ issue 90 epic "" "3 Events"; issue 102 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
wave 1 "$PM"; merged_pkg 101 a 101 50; acc 102 x 70
dispatch --once
ok "waves (finding 1): merged + waiting dependency → the dependant is held from wave 2" eq "$(plans) $(pissues)" "1 #105"
planned 2 "$PD"; dispatch --once
ok "… carried with only the carried dependency left" \
  eq "$(jq -c '[.packages[] | "\(.name):\(.depends_on | join(","))"]' "$CANCCU_HOME/steps/12.plan-2.json")" '["d:","x:","b:x"]'
rm -f "$WORKERS_DIR/web-105.lock" "$CANCCU_HOME/state/105"; merged_pkg 105 d 105 51
{ issue 90 epic "" "3 Events"; issue 102 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"
  issue 106 ready "" "3 Events"; } | issues
dispatch --once
ok "… wave 2's own package merged before the accept → the wave-3 planner still does not get the dependant" eq "$(plans) $(pissues)" "2 #106"
planned 3 '{"schema":1,"step":12,"wave":3,"packages":[{"name":"f","issues":[106],"risk":"low","risk_reason":"z","areas":[],"depends_on":[]}]}'
dispatch --once
ok "… still not started" not started 104
accepted 102 x
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 106 in-progress "" "3 Events"; } | issues
dispatch --once
ok "… the accept came → the dependant starts, in wave 3" eq "$(started 104 && echo y) $(st 104 wave)" "y 3"

senv waves-merged-dep-race 1
{ issue 90 epic "" "3 Events"; issue 102 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
wave 1 "$PM"; merged_pkg 101 a 101 50; acc 102 x 70
dispatch --once
accepted 102 x
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
planned 2 "$PD"; dispatch --once
ok "waves (finding 1): the accept came while the planner ran → the dependant is carried with no dependency left and starts in wave 2" \
  eq "$(jq -c '[.packages[] | "\(.name):\(.depends_on | join(","))"]' "$CANCCU_HOME/steps/12.plan-2.json") $(started 104 && echo y) $(st 104 wave)" '["d:","b:"] y 2'

# finding 2: carrying never leaves a dependency on a package that is not in the plan
ok "waves (finding 2, review 3): a carried package whose issue is in the new plan is dropped, and so is (transitively) every carried one behind it" \
  eq "$(lib plan_carry '{"packages":[{"name":"e","issues":[201],"depends_on":[]},{"name":"f","issues":[300],"depends_on":[]}]}' \
         '[{"name":"p","issues":[201],"depends_on":[]},{"name":"q","issues":[202],"depends_on":["p"]},{"name":"u","issues":[203],"depends_on":["q"]},{"name":"v","issues":[204],"depends_on":["gone"]}]' |
        jq -c '[.packages[] | "\(.name):\(.depends_on | join(","))"]')" '["e:","f:","v:"]'
ok "… for validation, a dropped carried package is no known dependency (a plan depending on it is invalid)" \
  eq "$(lib carry_kept '{"packages":[{"name":"e","issues":[201],"depends_on":["q"]}]}' \
         '[{"name":"p","issues":[201],"depends_on":[]},{"name":"q","issues":[202],"depends_on":["p"]},{"name":"r","issues":[205],"depends_on":[]}]' | jq -c 'map(.name)')" '["r"]'

# fix-check of #70: depends_on is optional in a plan; carrying never fails on a package without it
ok "waves (fix-check): plan_carry takes a package with no depends_on (wave 1, nothing carried)" \
  eq "$(lib plan_carry '{"packages":[{"name":"e","issues":[201]}]}' '[]' | jq -c '[.packages[] | "\(.name):\(.depends_on | join(","))"]')" '["e:"]'
senv waves-nodeps 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
wave 1 '{"schema":1,"step":12,"wave":1,"packages":[{"name":"a","issues":[101],"risk":"high","risk_reason":"x","areas":[]}]}'; acc 101 a 70
ok "… carried_packages reads a stored package with no depends_on" \
  eq "$(lib eval 'fetch; fetch_steps; carried_packages 12' | jq -c '[.[] | "\(.name):\(.depends_on | join(","))"]')" '["a:"]'
dispatch --once
planned 2 '{"schema":1,"step":12,"wave":2,"packages":[{"name":"d","issues":[105],"risk":"low","risk_reason":"z","areas":[]}]}'
dispatch --once
ok "… a wave planned with no depends_on anywhere carries it and runs, no needs-you" \
  eq "$(jq -c '[.packages[] | "\(.name):\(.depends_on | join(","))"]' "$CANCCU_HOME/steps/12.plan-2.json" 2>/dev/null) $(started 105 && echo y) $(grep -c '^issue comment 90 .*Needs you' "$FAKE/gh.log")" '["d:","a:"] y 0'

# review 3, finding 1: the accept lands while the planner runs; the plan depends on that package
# (as the prompt allows): a dependency on an earlier package merged since counts as met
senv waves-dep-merged-meanwhile 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
wave 1 "$PB"; acc 101 a 70
dispatch --once
accepted 101 a
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
planned 2 '{"schema":1,"step":12,"wave":2,"packages":[{"name":"d","issues":[105],"risk":"low","risk_reason":"z","areas":[],"depends_on":["a"]}]}'
dispatch --once
ok "waves (review 3, finding 1): a dependency on a package merged during planning is met: the plan is valid, d and b start" \
  eq "$(sed -n 's/^wave=//p' "$CANCCU_HOME/steps/12") $(grep -c 'Needs you' "$FAKE/gh.log") $(started 105 && echo y) $(started 104 && echo y)" "2 0 y y"
ok "… the met dependency is dropped from the stored plan" \
  eq "$(jq -c '[.packages[] | "\(.name):\(.depends_on | join(","))"]' "$CANCCU_HOME/steps/12.plan-2.json")" '["d:","b:"]'

# review 3, finding 2: a dependant that can start while the planner runs starts at once
senv waves-start-while-planning 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
wave 1 "$PB"; acc 101 a 70
dispatch --once
accepted 101 a
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
dispatch --once
ok "waves (review 3, finding 2): the accept came while the planner runs → the dependant starts, no wait for the plan" \
  eq "$(started 104 && echo y) $(plans) $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "y 1 planning"
planned 2 "$PD"; dispatch --once
ok "… the plan comes back: the running dependant is carried, wave 2's package starts" \
  eq "$(jq -c '[.packages[].name]' "$CANCCU_HOME/steps/12.plan-2.json") $(started 105 && echo y)" '["d","b"] y'

# review 3: a rejected plan is kept for the lead
senv waves-rejected-kept 0
{ issue 90 epic "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
dispatch --once
planned 1 '{"schema":1,"step":12,"wave":1,"packages":[{"name":"d","issues":[105],"risk":"low","risk_reason":"z","areas":[],"depends_on":["nope"]}]}'
dispatch --once
ok "waves (review 3): an invalid plan → needs-you, the plan kept as plan-1.rejected.json, no plan-1.json" \
  eq "$(grep -c 'the plan of wave 1 is invalid: d depends on unknown package nope' "$FAKE/gh.log") $(jq -c '.packages[0].depends_on' "$CANCCU_HOME/steps/12.plan-1.rejected.json" 2>/dev/null) $(test -e "$CANCCU_HOME/steps/12.plan-1.json" && echo file)" '1 ["nope"] '

# finding 3: a planner started without a wave check (the lead removed needs-you) never gets the
# issues of a package of the current plan that could start
senv waves-retry-pending 0
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
wave 1 "$P2" needs-you; printf 'ny_at=%s\n' "$((NOW - 600))" >> "$CANCCU_HOME/steps/12"; merged_pkg pkg-12-a a "101 103" 50
dispatch --once
ok "waves (finding 3): needs-you removed → the planner, without the issue of the package that can start" eq "$(plans) $(pissues)" "1 #105"

# finding 4: a carry that fails is the lead's (needs-you), never a half-written plan or a new planner
senv waves-carry-fails 0
{ issue 90 epic "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
wave 1 '{"schema":1,'
dispatch --once
planned 2 "$PD"; dispatch --once
ok "waves (finding 4): the unfinished packages cannot be read → needs-you, no plan-2 file" \
  eq "$(grep -c '^issue comment 90 .*the plan of wave 2 could not take over the unfinished packages' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/steps/12.plan-2.json" && echo file)" "1 "
{ issue 90 epic,needs-you "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
dispatch --once
ok "… and no new planner" eq "$(plans)" 1

# finding 5: a new package may depend on a carried one; it waits for its merge
senv waves-dep-carried 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
wave 1 "$PB"; acc 101 a 70
dispatch --once
ok "waves (finding 5): the planner is told it may depend on an unfinished earlier package" \
  grep -qF 'may depend on an earlier package that is not merged yet' <<<"$(grep -- '--key plan-12' "$FAKE/worker.log" | tail -1)"
planned 2 '{"schema":1,"step":12,"wave":2,"packages":[{"name":"d","issues":[105],"risk":"low","risk_reason":"z","areas":[],"depends_on":["a"]}]}'
dispatch --once
ok "… a plan depending on the carried package is valid (wave 2, no needs-you; over at once: all wait on a); d waits" \
  eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12") $(sed -n 's/^wave=//p' "$CANCCU_HOME/steps/12") $(started 105 && echo y)" "idle 2 "
accepted 101 a
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
dispatch --once
ok "… merged → both its dependants start" eq "$(started 104 && echo y) $(started 105 && echo y)" "y y"

# finding 6: an idle step goes on only for a package that can start, not each time a waiting one
# leaves the accept (a push sends it back to review)
senv waves-no-flip 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
wave 1 "$PB"; acc 101 a 70
dispatch --once
sed -i 's/^phase=accept/phase=check/' "$CANCCU_HOME/state/101"
dispatch --once
ok "waves (finding 6): the waiting package went back to review → the step stays idle, no \"goes on\"" \
  eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12") $(grep -c 'goes on' "$CANCCU_HOME/dispatch.log")" "idle 0"

senv waves-accept-health 1
{ issue 90 epic "" "3 Events"; issue 101 in-progress,awaiting-accept "" "3 Events"; } | issues
wave 1 "$PA"; acc 101 a 70; merged_pkg 102 c 102 71
dispatch --once; dispatch --once
ok "waves: the last package waits for the accept → no health pass yet, no planner" \
  eq "$(grep -c -- '--key pkg-12-health' "$FAKE/worker.log") $(plans) $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "0 0 idle"
accepted 101 a; ms 12 "3 Events" 2 | jq -s . > "$FAKE/ms.json"
{ issue 90 epic "" "3 Events"; } | issues
dispatch --once
ok "… merged → the health pass starts" grep -qF -- '--key pkg-12-health' "$FAKE/worker.log"

# mid-step, an issue's last blocker (an epic, a checkpoint) is closed without a merge: the
# issue becomes ready and the next wave's planner gets it
senv waves-unblocked 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"; issue 104 ready "" "3 Events"
  issue 106 blocked "" "3 Events"; } | issues
json deps106.json '[{"number": 80, "state": "closed"}, {"number": 95, "state": "closed"}]'
route 'api repos/example-org/web/issues/106/dependencies/blocked_by' deps106.json
wave 1 "$P2"; state pkg-12-a pkg=a step=12 wave=1 "members=101 103" branch=pkg-12-a phase=needs-you
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/106"   # the dispatcher's own labels
dispatch --once
ok "waves: an issue unblocked mid-step (blockers closed, no merge) → ready" has gh.log "issue edit 106 -R example-org/web --remove-label blocked --add-label ready"
ok "… and the next wave's planner includes it (not #104: it waits for its needs-you dependency)" eq "$(plans) $(pissues)" "1 #106"

senv waves-idle 0
{ issue 90 epic "" "3 Events"; issue 106 "" "" "3 Events"; } | issues
wave 1 '{"schema":1,"step":12,"wave":1,"packages":[{"name":"a","issues":[101],"risk":"low","risk_reason":"x","areas":[],"depends_on":[]}]}'
merged_pkg 101 a 101 50
dispatch --once
ok "waves: nothing ready left, an open issue not released → idle, no planner" eq "$(plans) $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "0 idle"
{ issue 90 epic "" "3 Events"; issue 106 ready "" "3 Events"; } | issues
dispatch --once
ok "… it becomes ready → the planner" eq "$(plans)" 1

# ---------------------------------------------------------------- cross-step blockers (lead's change 2)

env_new xblock
jq -s . > "$FAKE/ms.json" < <(ms 12 "2 Contracts"; ms 13 "3 Events")
{ issue 20 epic "" "2 Contracts"; issue 21 ready "Blocked by #31" "2 Contracts"; issue 22 ready "" "2 Contracts"
  issue 31 ready "" "3 Events"; } | issues
json c20.json '{"comments": []}'; route 'issue view 20 *' c20.json
dispatch --once
ok "cross-step: the epic gets needs-you: step 2 waits on #31 in step 3" \
  grep -q '^issue comment 20 .*step 2 Contracts waits on #31 in step 3 Events: it blocks #21' "$FAKE/gh.log"
ok "… labelled" grep -q '^issue edit 20 -R example-org/web --add-label needs-you' "$FAKE/gh.log"
ok "… the dispatcher's line ends with the epic's URL" grep -qE 'waits on #31 in step 3 Events \(it blocks #21\) · https://github.com/example-org/web/issues/20$' "$E/out"
ok "… nothing starts for #21; its step plans the rest" eq "$(pissues)" "#22"
{ issue 20 epic,needs-you "" "2 Contracts"; issue 21 ready "Blocked by #31" "2 Contracts"; issue 22 in-progress "" "2 Contracts"
  issue 31 ready "" "3 Events"; } | issues
dispatch --once
ok "… said once" eq "$(grep -c 'waits on #31' "$FAKE/gh.log")" 1
{ issue 20 epic,needs-you "" "2 Contracts"; issue 21 ready "Blocked by #31" "2 Contracts"; issue 22 in-progress "" "2 Contracts"
  issue 31 ready "" "2 Contracts"; } | issues
dispatch --once
ok "cross-step: the blocker moved into the step → the epic's needs-you goes" grep -q '^issue edit 20 -R example-org/web --remove-label needs-you' "$FAKE/gh.log"

# ---------------------------------------------------------------- the health pass (task 9)

senv health 3
{ issue 90 epic "" "3 Events"; } | issues
touch "$FAKE/comment-urls"
dispatch --once
ok "health: every work issue closed → one health package starts" grep -qF -- '--name health#12 --key pkg-12-health' "$FAKE/worker.log"
ok "… no Closes line, Package: health, the checklist" grep -qF 'no `Closes` line' "$FAKE/worker.log"
ok "… phase health" eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" health
rm -f "$WORKERS_DIR/web-pkg-12-health.lock"; last pkg-12-health done $'all clean\nHealth: nothing to do'
dispatch --once
ok "health: nothing to do → skipped, then the checkpoint: needs-you and the summary" \
  eq "$(sed -n 's/^health=//p' "$CANCCU_HOME/steps/12") $(grep -c '^issue edit 95 -R example-org/web --add-label needs-you' "$FAKE/gh.log") $(grep -c '^issue comment 95 .*Checkpoint.*Label this issue `checkpoint-ok`' "$FAKE/gh.log")" "skipped 1 1"
ok "… the summary comment's link is kept for the monitor" \
  eq "$(sed -n 's/^checkpoint_url=//p' "$CANCCU_HOME/steps/12")" "https://github.com/example-org/web/issues/95#issuecomment-95"
ok "… the dispatcher's checkpoint line ends with it" \
  grep -qE 'step 3 Events: checkpoint #95 waits for checkpoint-ok · https://github.com/example-org/web/issues/95#issuecomment-95$' "$E/out"
ok "… a dry run's would: line for the summary goes to stdout, as mut's do" \
  grep -q '^  would: gh issue comment 95 -R example-org/web ' <<<"$(CANCCU_DRY=1 lib comment_issue_url 95 x)"
dispatch --once
ok "… the health state is gone" test ! -e "$CANCCU_HOME/state/pkg-12-health"
ok "health: done once per step" eq "$(grep -c -- '--key pkg-12-health' "$FAKE/worker.log")" 1

senv health-old 3
{ issue 90 epic "" "3 Events"; issue 7 in-progress "" "3 Events"; } | issues
state 7 phase=check pr=70
dispatch --once
ok "health: not while an old per-issue unit of the step is open" not grep -q -- 'pkg-12-health' "$FAKE/worker.log"

# ---------------------------------------------------------------- the checkpoint (task 9)

# cpenv <name> [checkpoint labels]: step 12 waits at checkpoint 95; step 13 has a ready issue; #5 is fast-lane
cpenv() {
  senv "$1" 3
  jq -s . > "$FAKE/ms.json" < <(ms 12 "3 Events" 3; ms 13 "4 Later")
  cpi 95 OPEN "3 Events" "${2:-}" | jq -s . > "$FAKE/cps.json"
  { issue 90 epic "" "3 Events"; issue 41 ready "" "4 Later"; issue 5 ready; } | issues
  wave 1 "$P2" checkpoint; printf 'health=merged\ncheckpoint_at=%s\n' "$NOW" >> "$CANCCU_HOME/steps/12"
}
cpenv cp-wait
dispatch --once
ok "checkpoint: the next step's packages and planner do not start while it waits" not grep -q -- '--key plan-13' "$FAKE/worker.log"
ok "checkpoint: the fast lane still runs during the pause" started 5
cpenv cp-ok checkpoint-ok
json ev95.json "$(jq -n --arg t 2030-11-05T13:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "octo"}, created_at: $t}]')"
route 'api --paginate repos/example-org/web/issues/95/events' ev95.json
dispatch --once
ok "checkpoint: checkpoint-ok by the user → closed by the dispatcher, the step done" \
  eq "$(grep -c '^issue close 95 ' "$FAKE/gh.log") $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "1 done"
cpi 95 CLOSED "3 Events" checkpoint-ok | jq -s . > "$FAKE/cps.json"
dispatch --once
ok "… and the next step is current: its planner starts" grep -q -- '--key plan-13' "$FAKE/worker.log"
cpenv cp-other checkpoint-ok
json ev95.json "$(jq -n --arg t 2030-11-05T13:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "someone"}, created_at: $t}]')"
route 'api --paginate repos/example-org/web/issues/95/events' ev95.json
dispatch --once
ok "checkpoint: checkpoint-ok added by another login → ignored" eq "$(grep -c '^issue close 95 ' "$FAKE/gh.log") $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "0 checkpoint"
# the checkpoint waiting for checkpoint-ok is the product owner's: its own ping (canccu
# PING_KINDS has checkpoint), on the checkpoint, linking the summary comment
CPLINE='@octo this checkpoint waits for your `checkpoint-ok`: read the summary (https://github.com/example-org/web/issues/95#issuecomment-95), then label this issue `checkpoint-ok`, or close it.'
cpenv cp-ping
{ issue 90 epic "" "3 Events"; issue 95 checkpoint,needs-you "" "3 Events"; } | issues
echo 'checkpoint_url=https://github.com/example-org/web/issues/95#issuecomment-95' >> "$CANCCU_HOME/steps/12"
dispatch --once
ok "checkpoint waiting for checkpoint-ok → one ping, on the checkpoint" eq "$(grep -c '^issue comment 95 -R example-org/web --body @octo' "$FAKE/gh.log")" 1
ok "… its own line, linking the summary comment" has gh.log "issue comment 95 -R example-org/web --body $CPLINE"
ok "… nothing else pinged" eq "$(grep -c '^issue comment .* --body @octo' "$FAKE/gh.log")" 1
ok "… recorded as checkpoint" eq "$(cat "$CANCCU_HOME/pings/95" 2>/dev/null)" checkpoint
dispatch --once
ok "… not again on the next pass" eq "$(grep -c '^issue comment 95 -R example-org/web --body @octo' "$FAKE/gh.log")" 1
cpenv cp-ping-nolabel
{ issue 90 epic "" "3 Events"; issue 95 checkpoint "" "3 Events"; } | issues
dispatch --once
ok "checkpoint: its needs-you label did not land → pinged all the same; no summary link: \"above\"" \
  has gh.log 'issue comment 95 -R example-org/web --body @octo this checkpoint waits for your `checkpoint-ok`: read the summary above, then label'
cpenv cp-ping-ok checkpoint-ok
{ issue 90 epic "" "3 Events"; issue 95 checkpoint,needs-you,checkpoint-ok "" "3 Events"; } | issues
json ev95.json "$(jq -n --arg t 2030-11-05T13:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "octo"}, created_at: $t}]')"
route 'api --paginate repos/example-org/web/issues/95/events' ev95.json
dispatch --once
ok "checkpoint already labelled checkpoint-ok: no ping (this pass acts on it)" \
  eq "$(grep -c '^issue comment 95 -R example-org/web --body @octo' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/pings/95"; echo $?)" "0 1"
cpenv cp-ping-done
{ issue 90 epic "" "3 Events"; issue 95 checkpoint,needs-you "" "3 Events"; } | issues
sed -i 's/^phase=.*/phase=done/' "$CANCCU_HOME/steps/12"
dispatch --once
ok "a checkpoint whose step is not waiting on it: the plain needs-you (not a canccu kind: no ping)" \
  eq "$(grep -c '^issue comment 95 -R example-org/web --body @octo' "$FAKE/gh.log")" 0
# review of #76, finding 1: a checkpoint-ok the dispatcher ignores (another login, or added before
# the summary) leaves the step waiting: the checkpoint still pings
cpenv cp-ping-ok-other checkpoint-ok
{ issue 90 epic "" "3 Events"; issue 95 checkpoint,needs-you,checkpoint-ok "" "3 Events"; } | issues
json ev95.json "$(jq -n --arg t 2030-11-05T13:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "someone"}, created_at: $t}]')"
route 'api --paginate repos/example-org/web/issues/95/events' ev95.json
dispatch --once
ok "checkpoint-ok added by another login (ignored): the checkpoint still pings" \
  eq "$(grep -c '^issue comment 95 -R example-org/web --body @octo this checkpoint waits' "$FAKE/gh.log") $(cat "$CANCCU_HOME/pings/95" 2>/dev/null)" "1 checkpoint"
cpenv cp-ping-ok-early checkpoint-ok
{ issue 90 epic "" "3 Events"; issue 95 checkpoint,needs-you,checkpoint-ok "" "3 Events"; } | issues
json ev95.json "$(jq -n --arg t 2030-11-05T10:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "octo"}, created_at: $t}]')"
route 'api --paginate repos/example-org/web/issues/95/events' ev95.json
dispatch --once
ok "checkpoint-ok by the user before the summary (ignored): the checkpoint still pings" \
  eq "$(grep -c '^issue comment 95 -R example-org/web --body @octo this checkpoint waits' "$FAKE/gh.log") $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "1 checkpoint"
# non-blocking: open is read from the checkpoint list (the one checkpoint_tick reads), not only
# from the open issues (their newest 300)
cpenv cp-ping-old
dispatch --once
ok "a waiting checkpoint missing from the open-issue list but open among the checkpoints: pinged" \
  eq "$(grep -c '^issue comment 95 -R example-org/web --body @octo this checkpoint waits' "$FAKE/gh.log")" 1

cpenv cp-closed; cpi 95 CLOSED "3 Events" | jq -s . > "$FAKE/cps.json"
dispatch --once
ok "checkpoint: closed by the user → the step done" eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" done

# ---------------------------------------------------------------- notes and the step budget (task 11)

senv notes 0
lib collect_notes 12 50 $'Closes #101\nFollow-up: split the parser\n- **Roadmap note:** step 4 needs a new screen\nFollow-up:   split   the parser'
lib collect_notes 12 51 $'Follow-up: Split the parser\nFollow-up: add a cache'
ok "notes: Follow-up and Roadmap note lines kept, de-duplicated" eq "$(cut -f2- "$CANCCU_HOME/steps/12.notes" | tr '\t' '|' | tr '\n' ' ')" \
  "follow-up|50|split the parser roadmap|50|step 4 needs a new screen follow-up|51|add a cache "
mkdir -p "$CANCCU_HOME/steps"; printf 'title=3 Events\n' > "$CANCCU_HOME/steps/12"
out=$(lib eval 'echo "$(digest_notes)"')
ok "notes: listed for the digest" grep -qF -- '- 3 Events · roadmap: step 4 needs a new screen (PR #50)' <<<"$out"
ok "notes: no issue is ever created" not grep -q 'issue create' "$FAKE/gh.log"

senv budget 0 STEP_BUDGET=5
{ issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; issue 5 ready; } | issues
mkdir -p "$CANCCU_HOME/steps"; printf 'phase=idle\nstarted_at=%s\nwave=0\n' "$((NOW - 3600))" > "$CANCCU_HOME/steps/12"
printf 'plan-12\npkg-12-a\nreview-50\n' > "$CANCCU_HOME/steps/12.keys"
printf '%s\tweb\tplan-12\t2.00\n%s\tweb\treview-50\t3.50\n%s\tweb\t5\t9.00\n%s\tweb\tpkg-12-a\t?\n' "$((NOW - 100))" "$((NOW - 90))" "$((NOW - 80))" "$((NOW - 70))" > "$WORKERS_DIR/spend.log"
ok "budget: the step's runs are summed, others are not" eq "$(lib step_spend 12)" "5.50 1"
dispatch --once
ok "budget: at the limit no new run of the step starts" eq "$(grep -c -- '--key plan-12' "$FAKE/worker.log")" 0
ok "… the epic gets needs-you, with the amount" grep -q '^issue comment 90 .*reached STEP_BUDGET (\$5.50 of \$5)' "$FAKE/gh.log"
ok "… the dispatcher's line ends with the epic's URL" grep -qE 'reached STEP_BUDGET .* · https://github.com/example-org/web/issues/90$' "$E/out"
ok "… the fast lane is not charged and keeps running" started 5
dispatch --once
ok "… said once" eq "$(grep -c 'reached STEP_BUDGET' "$FAKE/gh.log")" 1
echo "STEP_BUDGET=50" >> "$CANCCU_HOME/config"
{ issue 90 epic,needs-you "" "3 Events"; issue 101 ready "" "3 Events"; } | issues
dispatch --once
ok "budget: raising STEP_BUDGET clears the epic's needs-you and the planner starts" \
  eq "$(grep -c '^issue edit 90 -R example-org/web --remove-label needs-you' "$FAKE/gh.log") $(grep -c -- '--key plan-12' "$FAKE/worker.log")" "1 1"

# ---------------------------------------------------------------- review #45 findings 2-5, 7, 8

# finding 2: a package's review is charged to its step, and held at STEP_BUDGET
# rvenv <name> [config...]: package pkg-12-a (101) in check with a green PR #50 on its branch
rvenv() {
  senv "$@"
  { issue 90 epic "" "3 Events"; issue 101 in-progress "" "3 Events"; } | issues
  wave 1 '{"schema":1,"step":12,"wave":1,"packages":[{"name":"a","issues":[101],"risk":"normal","risk_reason":"x","areas":[],"depends_on":[]}]}'
  state 101 pkg=a step=12 wave=1 members=101 branch=101-issue-101 risk=normal phase=check pr=50 "check_at=$NOW"
  p=$(PR_BRANCH=101-issue-101 pr 50 101 "$HA"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
}
rvenv budget-review 0
dispatch --once
ok "budget (finding 2): a package's review run is charged to its step" \
  eq "$(grep -c -- '--key review-50' "$FAKE/worker.log") $(grep -cx 'review-50' "$CANCCU_HOME/steps/12.keys")" "1 1"
rvenv budget-review-held 0 STEP_BUDGET=5
printf 'pkg-12-a\n' > "$CANCCU_HOME/steps/12.keys"; printf '%s\tweb\tpkg-12-a\t6.00\n' "$((NOW - 100))" > "$WORKERS_DIR/spend.log"
dispatch --once
ok "budget (finding 2): at STEP_BUDGET the package's review does not start" not grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… said once in the log" eq "$(grep -c 'review of PR #50 held: step 3 Events reached STEP_BUDGET' "$CANCCU_HOME/dispatch.log")" 1

# finding 3: a package whose issues were closed without a merged PR is final
senv closed-pkg 0
{ issue 90 epic "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
wave 1 "$P2"; printf 'pkg-12-a\ta\t1\t101 103\tnormal\t50\tclosed\n' > "$CANCCU_HOME/steps/12.packages"
dispatch --once
ok "packages (finding 3): a package closed without a merge is never started again" not grep -q -- '--key pkg-12-a ' "$FAKE/worker.log"
ok "… its status is closed, and the wave is over" \
  eq "$(lib eval 'fetch; fetch_steps; package_status 12 a') $(sed -n 's/^planner_wave=//p' "$CANCCU_HOME/steps/12")" "closed 2"

# review 2: what the dispatcher does not handle on its own stops the step: needs-you, one line,
# nothing starts; the step goes on once the lead sorted it out
stops() { grep -c '^issue comment 90 .*Nothing of this step starts' "$FAKE/gh.log"; }
senv stop-done-work 3
cpi 95 CLOSED "3 Events" | jq -s . > "$FAKE/cps.json"
{ issue 90 epic "" "3 Events"; issue 105 ready "" "3 Events"; } | issues
wave 1 "$P2" done; printf 'done_at=%s\nhealth=merged\n' "$NOW" >> "$CANCCU_HOME/steps/12"
dispatch --once; dispatch --once
ok "stop: a done step with new open work → epic needs-you, once, with what it found" \
  eq "$(stops) $(grep -c '^issue comment 90 .*the step was done and has new open work: #105' "$FAKE/gh.log")" "1 1"
ok "… nothing starts for it" not grep -q -- '--key plan-12' "$FAKE/worker.log"
{ issue 90 epic,needs-you "" "3 Events"; } | issues
dispatch --once
ok "… the issue moved away: the step is done again, the label goes" \
  eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12") $(grep -c '^issue edit 90 -R example-org/web --remove-label needs-you' "$FAKE/gh.log")" "done 1"
senv stop-cp-open 3
{ issue 90 epic "" "3 Events"; } | issues
wave 1 "$P2" done; printf 'done_at=%s\n' "$NOW" >> "$CANCCU_HOME/steps/12"
dispatch --once
ok "stop: a done step's checkpoint open again → needs-you, not closed by the dispatcher" \
  eq "$(grep -c '^issue comment 90 .*checkpoint #95 is open again, but the step was done' "$FAKE/gh.log") $(grep -c '^issue close 95' "$FAKE/gh.log")" "1 0"
senv stop-epic-closed 0
cpi 95 OPEN "3 Events" | jq -s . > "$FAKE/cps.json"
{ issue 95 checkpoint "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
wave 1 "$P2"
dispatch --once
ok "stop: its epic closed while the step runs → the checkpoint gets needs-you" \
  eq "$(grep -c '^issue comment 95 .*its epic #90 is closed while the step runs' "$FAKE/gh.log") $(grep -c -- '--name #104 ' "$FAKE/worker.log")" "1 0"

# review 2, finding 2: the step stays current until its health pass started, also when nothing may start
senv health-due 3
echo '[]' > "$FAKE/cps.json"
jq -s . > "$FAKE/ms.json" < <(ms 12 "3 Events" 3; ms 13 "4 Later")
{ issue 90 epic "" "3 Events"; issue 41 ready "" "4 Later"; } | issues
wave 1 "$P2"; merged_pkg pkg-12-a a "101 103" 50; merged_pkg 104 b 104 51
touch "$CANCCU_HOME/paused"; dispatch --once; dispatch --once
ok "health (review 2, finding 2): paused when the last wave ends → health-due, the step stays current" \
  eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12") $(test -e "$CANCCU_HOME/steps/13" && echo next || echo none)" "health-due none"
rm -f "$CANCCU_HOME/paused"; dispatch --once
ok "… the health pass starts once it may" grep -q -- '--key pkg-12-health' "$FAKE/worker.log"
rm -f "$WORKERS_DIR/web-pkg-12-health.lock"; last pkg-12-health done $'Health: nothing to do'
dispatch --once
ok "… with no open checkpoint the step skips the pause, logged" grep -q 'step 3 Events is done: it has no open checkpoint, so it skips the checkpoint pause' "$CANCCU_HOME/dispatch.log"

# finding 5: a failed close of the checkpoint is retried; the step is not done before it went through
cpenv cp-close-fails checkpoint-ok
json ev95.json "$(jq -n --arg t 2030-11-05T13:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "octo"}, created_at: $t}]')"
route 'api --paginate repos/example-org/web/issues/95/events' ev95.json; echo 'fail:issue close' >> "$FAKE/routes"
dispatch --once
ok "checkpoint (finding 5): the close failed → the step is not done" eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" checkpoint
sed -i '/^fail:issue close$/d' "$FAKE/routes"; dispatch --once
ok "… the next pass closes it and the step is done" eq "$(grep -c '^issue close 95 ' "$FAKE/gh.log") $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "2 done"

# finding 7: a step with no epic and no checkpoint stays in needs-you after an invalid plan
senv no-epic 0
echo '[]' > "$FAKE/cps.json"
{ issue 101 ready "" "3 Events"; } | issues
dispatch --once
rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 done '{"schema":1,"step":12,"wave":1,"packages":[]}'
dispatch --once; dispatch --once; dispatch --once
ok "planner (finding 7): no epic or checkpoint → it stays needs-you, no new planner" \
  eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12") $(grep -c -- '--key plan-12' "$FAKE/worker.log")" "needs-you 1"
ok "… the lead is told the step needs an epic or a checkpoint, once" eq "$(grep -c 'has no epic or checkpoint to answer on' "$CANCCU_HOME/dispatch.log")" 1

# finding 8: the health pass's PR closed without merging ends the health pass; the checkpoint follows
senv health-closed 3
{ issue 90 epic "" "3 Events"; } | issues
wave 1 "$P2" health; echo 'health=running' >> "$CANCCU_HOME/steps/12"
state pkg-12-health pkg=health step=12 health=1 branch=pkg-12-health risk=normal phase=needs-you pr=60
json pv60.json '{"state": "CLOSED"}'; route 'pr view 60 *' pv60.json
dispatch --once
ok "health (finding 8): a health PR closed without merging → health closed, the checkpoint summary follows" \
  eq "$(sed -n 's/^health=//p' "$CANCCU_HOME/steps/12") $(grep -c '^issue comment 95 .*PR #60 closed without merging' "$FAKE/gh.log")" "closed 1"
dispatch --once
ok "… the health unit is finished" test ! -e "$CANCCU_HOME/state/pkg-12-health"

echo "canccu-steps2 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
