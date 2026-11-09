#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-snapshot2.sh — offline tests for the status snapshot's schema 2: steps, the
# package plan, the package fields of running / needs-you / queue items, events, usage; and that
# tests/fixtures/monitor/steps.json (the contract for the monitor's step view) has the writer's
# fields. Harness: tests/lib/harness.sh.
#   bash tests/canccu-snapshot2.sh [--write-fixture]   (the option rewrites the fixture from this run)
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

env_new snap2 STEP_BUDGET=4
# the roadmap: a done step before, the current one, the next one, an empty one, one later
{ jq -nc '{number: 11, title: "2 Setup", open_issues: 0, closed_issues: 3, due_on: null}'
  jq -nc '{number: 12, title: "3 Events", open_issues: 4, closed_issues: 1, due_on: null}'
  jq -nc '{number: 13, title: "4 Payments", open_issues: 4, closed_issues: 0, due_on: null}'
  jq -nc '{number: 14, title: "5 Reports", open_issues: 0, closed_issues: 0, due_on: null}'
  jq -nc '{number: 15, title: "6 Later", open_issues: 1, closed_issues: 0, due_on: null}'; } | jq -s . > "$FAKE/ms.json"
jq -nc '{number: 95, title: "Checkpoint: events", state: "OPEN", milestone: {title: "3 Events"}, labels: [{name: "checkpoint"}]}' | jq -s . > "$FAKE/cps.json"
{ issue 90 epic,needs-you "" "3 Events"; issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"
  issue 104 ready "" "3 Events"; issue 6 ready "Blocked by #104"; issue 107 ready "Blocked by #104" "3 Events"
  issue 110 ready "" "4 Payments"; issue 111 "" "" "4 Payments"; issue 112 blocked "" "4 Payments"
  issue 113 ready "Blocked by #110" "4 Payments"; issue 120 "" "" "6 Later"; } | issues
# the next step's blockers come from the issue's body, not a read per pass: this answer is never asked for
json b113.json '[{"number": 120, "state": "open"}]'; route 'api repos/example-org/web/issues/113/dependencies/blocked_by' b113.json
json c90.json '{"comments": []}'; route 'issue view 90 *' c90.json
PR_BRANCH=pkg-12-auth pr 50 101 "$HA" | jq '.closingIssuesReferences = [{number: 101}, {number: 103}]' | prs
mkdir -p "$CANCCU_HOME/steps" "$CANCCU_HOME/reviews"
cat > "$CANCCU_HOME/steps/12.plan-1.json" <<'P'
{"schema":1,"step":12,"wave":1,"packages":[
 {"name":"auth","issues":[101,103],"risk":"high","risk_reason":"sessions","areas":["src/auth/"],"depends_on":[]},
 {"name":"list","issues":[104],"risk":"low","risk_reason":"a list","areas":["src/web/"],"depends_on":["auth"]}]}
P
printf 'phase=running\nwave=1\nplan=%s\nplan_at=%s\nstarted_at=%s\ntitle=3 Events\nepic=90\ncheckpoint=95\nleft_out=107\nbudget_ny=1\n' \
  "$CANCCU_HOME/steps/12.plan-1.json" "$((NOW - 600))" "$((NOW - 3600))" > "$CANCCU_HOME/steps/12"
printf 'plan-12\npkg-12-auth\nreview-50\n' > "$CANCCU_HOME/steps/12.keys"
printf '%s\tweb\tplan-12\t2.00\n%s\tweb\treview-50\t3.00\n' "$((NOW - 100))" "$((NOW - 90))" > "$WORKERS_DIR/spend.log"
printf '%s\tfollow-up\t50\tsplit the parser\n' "$((NOW - 50))" > "$CANCCU_HOME/steps/12.notes"
state pkg-12-auth pkg=auth step=12 wave=1 "members=101 103" branch=pkg-12-auth risk=high risk_reason=sessions phase=review pr=50 \
  "review_sha=$HA" stage=review "started=$((NOW - 120))" color=1
live_lock review-50; echo review > "$CANCCU_HOME/reviews/50.mode"; echo "$HA" > "$CANCCU_HOME/reviews/50.sha"
# runs the dispatcher did not start: an old install's kind=cc lock and a worker started by hand on an issue it does not manage
printf 'repo=web\nkey=77\nkind=cc\npid=%s\nwindow=\nstarted=%s\n' "$$" "$((NOW - 600))" > "$WORKERS_DIR/web-77.lock"
printf 'repo=web\nkey=55\nkind=worker\npid=%s\nwindow=\nstarted=%s\n' "$$" "$((NOW - 120))" > "$WORKERS_DIR/web-55.lock"
printf '%s #pkg-12-auth PR #50: reviewer started\n' "2030-11-05 11:58:00" > "$CANCCU_HOME/dispatch.log"
mkdir -p "$WORKERS_DIR"; jq -n --argjson at "$((NOW - 30))" '{at: $at, info: {unifiedWindows: {five_hour: {utilization: 0.42, resetsAt: 2019686400}, seven_day: {utilization: 0.5, resetsAt: 2019686400}}}}' > "$WORKERS_DIR/usage.json"
dispatch --once
S=$CANCCU_HOME/status.json
sj() { jq -r "$@" "$S" 2>/dev/null; }
ok "snapshot: schema 2" eq "$(sj .schema)" 2
ok "snapshot: the new top-level keys, typed" eq "$(sj '[(.steps|type), (.current_step|type), (.usage|type)] | join(" ")')" "array number object"
ok "snapshot: steps[]: the step" eq "$(sj '.steps[0] | [.milestone, .title, .track, .current, .phase, .wave, .epic, .checkpoint.issue, .checkpoint.state, .checkpoint.waiting] | map(tostring) | join(" ")')" \
  "12 3 Events main true running 1 90 95 open false"
ok "snapshot: steps[]: the budget" eq "$(sj '.steps[0].budget | [.usd, .limit, .runs_without_cost, .over] | map(tostring) | join(" ")')" "5 4 0 true"
ok "snapshot: steps[]: the plan" eq "$(sj '.steps[0].plan | [.wave, (.at|type), (.left_out|tostring)] | map(tostring) | join(" ")')" "1 number [107]"
ok "snapshot: steps[]: each package's stage and risk class" \
  eq "$(sj '[.steps[0].plan.packages[] | "\(.name):\(.key):\(.state):\(.risk):\(.risk_effective):\(.pr):\(.branch)"] | join(" ")')" \
  "auth:pkg-12-auth:review:high:high:50:pkg-12-auth list:104:blocked:low:low:null:null"
ok "snapshot: steps[]: health and notes" eq "$(sj '.steps[0] | [.health.state, .health.key, (.notes[0] | "\(.kind) \(.pr) \(.text)")] | join(" | ")')" \
  "n/a | pkg-12-health | follow-up 50 split the parser"
ok "snapshot: the current step" eq "$(sj .current_step)" 12
ok "snapshot: a running package: package, issues, risk, the lead issue" \
  eq "$(sj '.running[] | select(.key == "review-50") | [.package, (.issues|tostring), .risk, .issue, .kind] | map(tostring) | join(" ")')" "pkg-12-auth [101,103] high 101 review"
ok "snapshot: needs_you: the step budget, with step and kind" eq "$(sj '[.needs_you[] | select(.kind == "budget") | .issue, .step] | map(tostring) | join(" ")')" "90 12"
ok "… the epic is not listed again as a plain needs-you" eq "$(sj '[.needs_you[] | select(.issue == 90)] | length')" 1
ok "snapshot: queue lanes: the fast lane, then the step's packages" eq "$(sj '[.queue[] | "\(.lane):\(.issue):\(.package):\(.waits_on)"] | join(" ")')" \
  "fast:6:null:blocked by 104 step:104:104:depends on auth"
ok "snapshot: events carry the package" eq "$(sj '[.events[] | select(.package != null) | .package] | first')" pkg-12-auth
ok "snapshot: usage" eq "$(sj '.usage | [.five_hour, .seven_day, .state] | map(tostring) | join(" ")')" "42 50 normal"
# the step overview (the monitor's Roadmap), the runs the dispatcher did not start
ok "snapshot: step_overview: every open milestone in order, its place and work issues done/total" \
  eq "$(sj '[.step_overview[] | "\(.milestone):\(.place):\(.work_closed)/\(.work_open + .work_closed)"] | join(" ")')" \
  "11:done:3/3 12:current:1/5 13:next:0/4 14:later:0/0 15:later:0/1"
ok "snapshot: step_overview: the current step's open work issues, their status and package (no epic)" \
  eq "$(sj '[.step_overview[] | select(.milestone == 12) | .issues[] | "\(.issue):\(.status):\(.package):\(.waits_on)"] | join(" ")')" \
  "101:running:pkg-12-auth:null 103:running:pkg-12-auth:null 104:blocked:104:depends on auth 107:blocked:null:blocked by 104"
ok "snapshot: step_overview: the next step's issues, ready or waiting" \
  eq "$(sj '[.step_overview[] | select(.milestone == 13) | .issues[] | "\(.issue):\(.status):\(.waits_on)"] | join(" ")')" \
  "110:ready:null 111:blocked:no ready label 112:blocked:labelled blocked 113:blocked:blocked by 110"
ok "snapshot: step_overview: no GitHub read for a next-step issue's blockers" not grep -q 'issues/113/dependencies' "$FAKE/gh.log"
ok "snapshot: step_overview: the later steps list no issues" eq "$(sj '[.step_overview[] | select(.place == "later") | .issues | length] | add')" 0
ok "snapshot: step_overview: an issue's title and URL" \
  eq "$(sj '.step_overview[1].issues[0] | "\(.title) \(.url)"')" "Issue 101 https://github.com/example-org/web/issues/101"
ok "snapshot: repo_name: the clone's name, which a lock's repo= holds" eq "$(sj .repo_name)" web
ok "snapshot: other_runs: the live runs the dispatcher did not start, with key, kind and start" \
  eq "$(sj '[.other_runs[] | "\(.repo):\(.key):\(.kind):\(.started)"] | sort | join(" ")')" "web:55:worker:$((NOW - 120)) web:77:cc:$((NOW - 600))"
ok "canccu-status: lists them under other runs" \
  eq "$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1 | sed -n '/^other runs/,/^[a-z]/p' | grep -cE '^  (55 · worker|77 · cc) · [0-9]+[smhd]$')" 2
ok "canccu-status: … and not as the dispatcher's own" not grep -qE '^  #(55|77) ' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"
ok "canccu-status: a lock without kind= keeps its fields in place" grep -qE '^  88 · \? · [0-9]+[smhd]$' <<<"$(
  printf 'repo=web\nkey=88\npid=%s\nwindow=\nstarted=%s\n' "$$" "$((NOW - 7200))" > "$WORKERS_DIR/web-88.lock"
  PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"
rm -f "$WORKERS_DIR/web-88.lock"
ok "snapshot: an invalid plan → needs_you plan-invalid" eq "$(
  sed -i 's/^phase=running/phase=needs-you/; s/^budget_ny=1//' "$CANCCU_HOME/steps/12"; echo 'ny_reason=the plan of wave 2 is invalid: x' >> "$CANCCU_HOME/steps/12"
  dispatch --once; sj '[.needs_you[] | select(.kind == "plan-invalid") | .issue, .step, .reason] | map(tostring) | join(" | ")')" \
  "90 | 12 | step 3 Events: the plan of wave 2 is invalid: x"
ok "snapshot: a checkpoint waiting → needs_you checkpoint, milestone checkpoint ready" eq "$(
  sed -i 's/^phase=needs-you/phase=checkpoint/' "$CANCCU_HOME/steps/12"; echo "checkpoint_at=$NOW" >> "$CANCCU_HOME/steps/12"
  dispatch --once; sj '[(.needs_you[] | select(.kind == "checkpoint") | .issue), (.milestones[1].checkpoints[0].ready), .steps[0].checkpoint.waiting] | map(tostring) | join(" ")')" "95 true true"
ok "snapshot: a checkpoint waiting without its summary's link → the issue's URL" \
  eq "$(sj '.needs_you[] | select(.kind == "checkpoint") | .url')" "https://github.com/example-org/web/issues/95"
ok "snapshot: a checkpoint waiting → its url is the summary comment's link" eq "$(
  echo "checkpoint_url=https://github.com/example-org/web/issues/95#issuecomment-7" >> "$CANCCU_HOME/steps/12"
  dispatch --once; sj '.needs_you[] | select(.kind == "checkpoint") | .url')" "https://github.com/example-org/web/issues/95#issuecomment-7"

# the fixture for the monitor's step view: the same keys as what the writer writes
F=$root/tests/fixtures/monitor/steps.json
[ "${1:-}" = --write-fixture ] && jq --argjson now "$NOW" '.pass.at = $now' "$S" > "$F"
keys() { jq -c "[$1 | paths | map(if type == \"number\" then 0 else . end) | join(\".\")] | unique" "$2"; }
for part in '.other_runs[0]' '.step_overview[1]' '.step_overview[1].issues[0]' '.steps[0]' '.steps[0].plan.packages[0]' '.running[0]' '.needs_you[0]' '.queue[0]' '.usage' '.events[0]'; do
  ok "fixture steps.json: $part has the writer's fields" eq "$(keys "$part | del(.. | nulls)? // $part" "$F" | jq -c 'map(split(".")[0]) | unique')" \
    "$(keys "$part | del(.. | nulls)? // $part" "$S" | jq -c 'map(split(".")[0]) | unique')"
done
ok "fixture steps.json: schema 2" eq "$(jq .schema "$F")" 2

# a step without a notes file yet: no notes, and nothing in dispatch.log
rm -f "$CANCCU_HOME/steps/12.notes"; : > "$CANCCU_HOME/dispatch.log"; dispatch --once
ok "snapshot: a step without a notes file has no notes" eq "$(sj '.steps[0].notes | tostring')" "[]"
ok "… and dispatch.log has no error for it" not grep -F "12.notes" "$CANCCU_HOME/dispatch.log"

# (the monitor's inbox): where a needs-you unit parked, a unit's CI state and its CI wait cap,
# a needs-you unit's issues, repeated events folded
env_new snap62
{ issue 201 in-progress; issue 202 in-progress; issue 203 in-progress; issue 101 in-progress; issue 103 in-progress
  issue 204 in-progress; issue 205 in-progress; issue 206 in-progress; } | issues
{ pr 60 201 "$HA" pending; pr 61 202 "$HA" none; pr 62 203 "$HA" pending; pr 64 204 "$HA" red; pr 66 206 "$HA" pending
  PR_BRANCH=pkg-12-auth pr 50 101 "$HA" | jq '.closingIssuesReferences = [{number: 101}, {number: 103}]'; } | prs
state 201 phase=check pr=60 "check_at=$((NOW - 100 * 60))" color=1
state 202 phase=check pr=61 "check_at=$((NOW - 120))" color=2
state 203 phase=check pr=62 "check_at=$((NOW - 12 * 60))" stage=fixcheck color=3
# the review's findings: why check_pr stopped decides the stage, not the phase
state 204 phase=check pr=64 "check_at=$((NOW - 60))" color=5
state 205 phase=check "check_at=$((NOW - 60))" color=6
state 206 phase=check pr=66 "check_at=$((NOW - 100 * 60))" stage=fixing color=7
state pkg-12-auth pkg=auth step=12 wave=1 "members=101 103" phase=accept pr=50 "accept_at=$((NOW - 600))" "reason=manual: risk high" "accept_sha=$HA" color=4
for i in 1 2 3 4 5; do printf '2030-11-05 11:5%s:00 #50 PR #55: review post failed (try %s): GraphQL: no repo\n' "$i" "$i"; done > "$CANCCU_HOME/dispatch.log"
printf '2030-11-05 11:59:30 #50 PR #55: review posted\n' >> "$CANCCU_HOME/dispatch.log"
dispatch --once; S=$CANCCU_HOME/status.json
ok "snapshot #62: a unit parked at CI pending too long → needs_you stage ci" \
  eq "$(sj '.needs_you[] | select(.issue == 201) | "\(.kind) \(.stage) \(.issues)"')" "needs-you ci [201]"
ok "snapshot #62: an accept parks at merge, with the package's issues" \
  eq "$(sj '.needs_you[] | select(.kind == "accept") | "\(.issue) \(.pr) \(.stage) \(.issues)"')" "101 50 merge [101,103]"
ok "snapshot #62: running: a PR with no checks → ci none, its wait cap NO_CHECKS_MIN" \
  eq "$(sj '.running[] | select(.issue == 202) | "\(.pipeline) \(.ci) \(.minutes) \(.min_cap) \(.review_verdict)"')" "no-checks none 2 10 null"
ok "snapshot #62: running: a fix round waiting on CI is at the CI step (its cap CI_WAIT_MIN), the review asked for changes" \
  eq "$(sj '.running[] | select(.issue == 203) | "\(.pipeline) \(.ci) \(.minutes) \(.min_cap) \(.review_verdict)"')" "ci pending 12 90 changes"
ok "snapshot #62: red CI → needs_you stage ci (not review)" eq "$(sj '.needs_you[] | select(.issue == 204) | .stage')" ci
ok "snapshot #62: the worker finished without a PR → needs_you stage work" eq "$(sj '.needs_you[] | select(.issue == 205) | .stage')" work
ok "snapshot #62: CI pending past its cap in a fix round → needs_you stage ci (not fix-check)" \
  eq "$(sj '.needs_you[] | select(.issue == 206) | "\(.stage) \(.reason)"')" "ci CI on PR #66 is still pending after 90 min"
ok "snapshot #62: events: a repeat that differs only in a try number folds into one row with its count" \
  eq "$(sj '[.events[] | select(.issue == 50) | "\(.count) \(.first_at - .at) \(.text)"] | join(" | ")')" \
  "5 -240 #50 PR #55: review post failed (try 5): GraphQL: no repo | 1 0 #50 PR #55: review posted"
st201=$(st 201 ny_stage)
ok "state #62: needs_you records the stage it parked at (ny_stage)" eq "$st201" ci

# #54: each read over Linux's 128 KiB per-argument limit (300 issues with 1 KiB bodies and long
# titles, 300 checkpoints with long titles): the step logic and the snapshot still work
env_new snap54
jq -nc '[{number: 12, title: "3 Events", open_issues: 300, closed_issues: 0, due_on: null}]' > "$FAKE/ms.json"
jq -nc '[range(1; 301) | {number: (1000 + .), title: ("Checkpoint \(.) " + ("c" * 1024)), state: "CLOSED", milestone: null,
         labels: [{name: "checkpoint"}]}]' > "$FAKE/cps.json"
jq -nc '[range(1; 301) | {number: (100 + .), title: ("Issue \(.) " + ("t" * 512)), labels: [], body: ("b" * 1024),
         milestone: {title: "3 Events"}}]' > "$FAKE/issues.json"
# the step's plan (one merged package with a 300 KiB reason) and 300 notes of 1 KiB
mkdir -p "$CANCCU_HOME/steps"
jq -nc '{schema: 1, step: 12, wave: 1, packages: [{name: "big", issues: [101], risk: "low", risk_reason: ("r" * 307200),
         areas: [], depends_on: []}]}' > "$CANCCU_HOME/steps/12.plan-1.json"
printf 'phase=running\nwave=1\nplan=%s\nplan_at=%s\nstarted_at=%s\ntitle=3 Events\n' \
  "$CANCCU_HOME/steps/12.plan-1.json" "$((NOW - 600))" "$((NOW - 3600))" > "$CANCCU_HOME/steps/12"
printf 'pkg-12-big\tbig\t1\t101\tlow\t50\tmerged\n' > "$CANCCU_HOME/steps/12.packages"
jq -rn --arg at "$((NOW - 50))" 'range(300) | "\($at)\tfollow-up\t50\t" + ("n" * 1024)' > "$CANCCU_HOME/steps/12.notes"
dispatch --once; S=$CANCCU_HOME/status.json
ok "#54: the reads are over 256 KiB" eq "$(( $(wc -c < "$FAKE/issues.json") > 262144 && $(wc -c < "$FAKE/cps.json") > 262144 ))" 1
ok "#54: no jq call runs into the argument limit" not grep -q 'Argument list too long' "$E/out" "$CANCCU_HOME/dispatch.log"
ok "#54: the step logic acts: the step is current" eq "$(sj '[.pass.ok, .current_step, (.stale | length)] | map(tostring) | join(" ")')" "true 12 0"
ok "#54: the snapshot holds the milestones, the step's plan, notes and issues" \
  eq "$(sj '[.milestones[0].title, .steps[0].milestone, (.steps[0].plan.packages[0].risk_reason | length), (.steps[0].notes | length),
             (.step_overview[0].issues | length)] | map(tostring) | join(" ")')" "3 Events 12 307200 300 300"
route 'issue list -R example-org/web -s open*' FAIL
dispatch --once
ok "#54: a pass that cannot read GitHub keeps the large previous snapshot" \
  eq "$(sj '[.pass.ok, (.step_overview[0].issues | length), (.stale | index("steps") != null)] | map(tostring) | join(" ")')" "false 300 true"

echo "canccu-snapshot2 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
