#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-health-review.sh — offline tests for the bugs the 2030-11-06 health review of the
# dispatcher found. Harness: tests/lib/harness.sh.
#   bash tests/canccu-health-review.sh   one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

ms() { jq -nc --argjson n "$1" --arg t "$2" --argjson c "${3:-0}" '{number: $n, title: $t, open_issues: 0, closed_issues: $c, due_on: null}'; }
cpi() { jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" '{number: $n, title: "Checkpoint \($n)", state: $s, milestone: {title: $m}, labels: [{name: "checkpoint"}]}'; }
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
P2='{"schema":1,"step":12,"wave":1,"packages":[
  {"name":"a","issues":[101,103],"risk":"normal","risk_reason":"x","areas":[],"depends_on":[]},
  {"name":"b","issues":[104],"risk":"low","risk_reason":"y","areas":[],"depends_on":["a"]}]}'
stepv() { sed -n "s/^$1=//p" "$CANCCU_HOME/steps/12" | tail -1; }

# ---------------------------------------------------------------- 10: the harness's environment

ok "harness: no inherited GH_CONFIG_DIR, CANCCU_GH_OWNER or GIT_CONFIG_* (a canccu tmux session sets them empty)" \
  eq "$(env | grep -cE '^(GH_CONFIG_DIR|CANCCU_GH_OWNER|GIT_CONFIG_[A-Z_0-9]*)=')" 0

# ---------------------------------------------------------------- 1: the digest without DIGEST_ISSUE

env_new digest-noissue DIGEST_HOUR_UTC=6 DIGEST_ISSUE=
{ issue 8 needs-you; } | issues
dispatch --dry-run
ok "digest: no DIGEST_ISSUE → --dry-run says it would not post" grep -qF "would: write $CANCCU_HOME/digest/2030-11-05.md (DIGEST_ISSUE is empty: not posted)" "$E/out"
dispatch --once
f="$CANCCU_HOME/digest/2030-11-05.md"
ok "… the file is written" test -s "$f"
ok "… and never posted" eq "$(grep -c '^issue comment .*--body-file' "$FAKE/gh.log")" 0
ok "… logged as not posted" grep -q 'digest written; DIGEST_ISSUE is empty: not posted' "$CANCCU_HOME/dispatch.log"

env_new digest-retry DIGEST_HOUR_UTC=6
{ issue 8 needs-you; } | issues
echo 'fail:issue comment' >> "$FAKE/routes"
dispatch --once
f="$CANCCU_HOME/digest/2030-11-05.md"
ok "digest: a failed post keeps no file, so the next pass posts again" test ! -e "$f"
ok "… logged" grep -q 'digest: posting on #42 failed; retrying next pass' "$CANCCU_HOME/dispatch.log"
sed -i '/^fail:issue comment$/d' "$FAKE/routes"; : > "$FAKE/gh.log"
dispatch --once
ok "… posted on the next pass" has gh.log "issue comment 42 -R example-org/web --body-file $f"

# ---------------------------------------------------------------- 2: state writes

env_new kv-race
for i in $(seq 1 30); do lib st_set 7 "k$i=v$i" & done; wait
ok "st_set: 30 writers at once lose no key" eq "$(grep -c '^k[0-9]*=' "$CANCCU_HOME/state/7")" 30
ok "… one line per key" eq "$(grep -c . "$CANCCU_HOME/state/7")" 30
ok "… the state dir lists only the unit" eq "$(lib managed | tr '\n' ' ')" "7 "
lib st_set 7 k1=new k2=new2 k1=last
ok "st_set: several keys in one call, the last value of a key wins" eq "$(st 7 k1) $(st 7 k2) $(grep -c '^k1=' "$CANCCU_HOME/state/7")" "last new2 1"
lib st_rm 7
ok "st_rm: the unit is gone (its hidden lock file stays)" eq "$(ls "$CANCCU_HOME/state") $(lib managed)" " "

# canccu-stop sets phase=stopped after the pass read phase=work: the reap leaves it alone
env_new stop-race
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=stopped "started=$NOW" pr=50 review_sha=$HA
last 5 'crashed (exit 137)' killed
lib eval '. "$_canccu_lib/canccu-pipeline.sh"; fetch; reap_worker 5; reap_review 5; reap_answer 5'
ok "stop race: a worker, reviewer or answerer stopped by canccu-stop is never reaped as a failure" \
  eq "$(st 5 phase) $(grep -c 'needs-you' "$FAKE/gh.log")" "stopped 0"

# ---------------------------------------------------------------- 3: the health pass's labels on the epic

# hpenv <name> <phase> <PR state> [epic labels]: the health pass of step 12, at <phase>, PR #60 gone
hpenv() {
  senv "$1" 3
  { issue 90 "epic${4:+,$4}" "" "3 Events"; } | issues
  wave 1 "$P2" health; echo 'health=running' >> "$CANCCU_HOME/steps/12"
  state pkg-12-health pkg=health step=12 health=1 members= branch=pkg-12-health risk=high "phase=$2" pr=60 \
    "accept_sha=$HA" "accept_at=$NOW" "merge_sha=$HA" "merge_at=$NOW" "check_at=$NOW"
  json pv60.json "{\"state\": \"$3\", \"title\": \"health\", \"body\": \"\"}"; route 'pr view 60 *' pv60.json
}
for ph in check accept merging; do
  hpenv "health-closed-$ph" "$ph" CLOSED awaiting-accept
  dispatch --once
  ok "health ($ph): its PR closed → no needs-you on the epic" not grep -qE '^issue (edit 90 .*--add-label needs-you|comment 90 .*Needs you)' "$FAKE/gh.log"
  ok "… the health pass ends and the checkpoint follows" eq "$(stepv health) $(stepv phase)" "closed checkpoint"
  dispatch --once
  ok "… finished: the epic's awaiting-accept goes" has gh.log "issue edit 90 -R example-org/web --remove-label awaiting-accept"
  ok "… the unit is gone" test ! -e "$CANCCU_HOME/state/pkg-12-health"
done
hpenv health-merged accept MERGED awaiting-accept
dispatch --once
ok "health: a high-risk health PR accepted and merged → the epic's awaiting-accept goes" \
  eq "$(stepv health) $(grep -c '^issue edit 90 -R example-org/web --remove-label awaiting-accept' "$FAKE/gh.log")" "merged 1"
hpenv health-ny-merged needs-you MERGED needs-you
dispatch --once
ok "health: its needs-you on the epic goes when its PR merges by hand" has gh.log "issue edit 90 -R example-org/web --remove-label needs-you"
hpenv health-ny-step needs-you MERGED needs-you
echo 'STEP_BUDGET=1' >> "$CANCCU_HOME/config"; echo 'budget_ny=1' >> "$CANCCU_HOME/steps/12"
echo pkg-12-health > "$CANCCU_HOME/steps/12.keys"; printf '%s\tweb\tpkg-12-health\t5.00\n' "$((NOW - 100))" > "$WORKERS_DIR/spend.log"
dispatch --once
ok "… but stays while the step has its own (the budget)" hasnt gh.log "issue edit 90 -R example-org/web --remove-label needs-you"

# ---------------------------------------------------------------- 4: earlier packages for the planner

senv earlier 0
{ issue 90 epic "" "3 Events"; issue 101 in-progress "" "3 Events"; issue 104 in-progress "" "3 Events"; } | issues
wave 1 "$P2"
state pkg-12-a pkg=a step=12 wave=1 "members=101 103" branch=pkg-12-a phase=needs-you pr=50
state 104 pkg=b step=12 wave=1 members=104 branch=104-issue-104 phase=work
state pkg-12-health pkg=health step=12 health=1 members= branch=pkg-12-health phase=work
printf 'pkg-12-z\tz\t1\t105\tnormal\t49\tmerged\n' > "$CANCCU_HOME/steps/12.packages"
out=$(lib eval 'fetch; fetch_steps; planner_earlier 12')
ok "planner: earlier packages name the finished ones" grep -qF '{"name":"z","issues":[105],"outcome":"merged","pr":49}' <<<"$out"
ok "… and those still managed (needs-you, running), so their names are never reused" \
  eq "$(jq -c '[.[] | select(.name != "z") | "\(.name) \(.issues | join(",")) \(.outcome) \(.pr)"] | sort' <<<"$out")" \
  '["a 101,103 needs-you 50","b 104 running null"]'

# ---------------------------------------------------------------- 5: canccu-review reads GitHub

env_new review-reads
{ issue 5 in-progress,needs-you; } | issues
p=$(pr 50 5 $HA green "" false $'Tier: fix\nDecisions made: none'); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "lib/a.sh", "changes": 12}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
state 5 phase=needs-you pr=50 post_ny=1
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 50 > "$E/out" 2>&1
ok "canccu-review: a small Tier: fix PR gets a medium review" eq "$(cat "$CANCCU_HOME/reviews/50.effort" 2>/dev/null)" medium
ok "… a failed post's needs-you label goes" has gh.log "issue edit 5 -R example-org/web --remove-label needs-you"

# ---------------------------------------------------------------- 6 and 7: the planner while the step is stopped, dry-run

# stopenv <name>: step 12 planning wave 1 (issue 103); its epic #90 is closed: a stop (said on the
# checkpoint #95)
stopenv() {
  senv "$1" 0
  { issue 95 checkpoint "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
  mkdir -p "$CANCCU_HOME/steps"
  printf 'phase=planning\nwave=0\nstarted_at=%s\ntitle=3 Events\nepic=90\ncheckpoint=95\nplan_issues=103 \nplanner_wave=1\nplanner_started=%s\n' \
    "$((NOW - 3600))" "$((NOW - 60))" > "$CANCCU_HOME/steps/12"
  printf '101\ta\t1\t101\tnormal\t50\tmerged\n' > "$CANCCU_HOME/steps/12.packages"
  live_lock plan-12
}
stops() { grep -c '^issue comment 95 .*Nothing of this step starts' "$FAKE/gh.log"; }
PLAN_C='{"schema":1,"step":12,"wave":1,"packages":[{"name":"c","issues":[103],"risk":"low","risk_reason":"x","areas":[],"depends_on":[]}]}'
stopenv stop-planner
dispatch --once
ok "stop: the step stops while its planner runs" eq "$(stops) $(stepv ny_kind)" "1 stop"
rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 done "$PLAN_C"
dispatch --once; dispatch --once
ok "stop: the planner ends with a valid plan while stopped → no second stop comment" eq "$(stops)" 1
ok "… the stop and its reason stay; the wave waits for it" \
  eq "$(stepv phase) $(stepv ny_kind) $(stepv ny_from)" "needs-you stop running"
ok "… the reason is kept" grep -q '^ny_reason=its epic #90 is closed while the step runs' "$CANCCU_HOME/steps/12"

stopenv stop-planner-invalid
dispatch --once
rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 done 'not a plan'
dispatch --once; dispatch --once
ok "stop: an invalid plan while stopped → the lead is told, the stop is not posted again" \
  eq "$(stops) $(grep -c '^issue comment 95 .*the plan of wave 1 is invalid' "$FAKE/gh.log") $(stepv ny_kind)" "1 1 stop"
{ issue 90 epic,needs-you "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
dispatch --once
ok "… the stop resolved: the step waits on the invalid plan, with its reason, no new planner" \
  eq "$(stepv phase) $(grep -c -- '--key plan-12' "$FAKE/worker.log")" "needs-you 0"
ok "… its reason" grep -q '^ny_reason=the plan of wave 1 is invalid' "$CANCCU_HOME/steps/12"

stopenv dry-planner
rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 done "$PLAN_C"
{ issue 90 epic "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
echo 'old warning' > "$CANCCU_HOME/.warned-steps"
mkdir -p "$E/tmp"
TMPDIR=$E/tmp dispatch --dry-run
ok "dry-run: a reaped planner's plan is read" grep -q 'wave 1 planned: c' "$E/out"
ok "… no temp file is left behind" eq "$(ls -A "$E/tmp")" ""
ok "… .warned-steps is kept (dry-run writes nothing)" test -e "$CANCCU_HOME/.warned-steps"

# ---------------------------------------------------------------- 8 and 9: prompts and labels

senv labels 0
state pkg-12-a pkg=a step=12 wave=1 "members=101 103" branch=pkg-12-a phase=work stage=fixing
state pkg-12-health pkg=health step=12 health=1 members= branch=pkg-12-health phase=work
mkdir -p "$CANCCU_HOME/steps"; printf 'title=3 Events\n' > "$CANCCU_HOME/steps/12"
out=$(lib fixcheck_prompt 50 pkg-12-a "$HA" "$HB" /f low findings)
ok "fix-check prompt: a package's PR closes its issues" grep -qF "PR #50 (package a: closes #101, #103), head $HB" <<<"$out"
ok "… never #pkg-…" not grep -qF '#pkg-' <<<"$out"
out=$(lib fixcheck_prompt 60 pkg-12-health "$HA" "$HB" /f low findings)
ok "fix-check prompt: the health pass closes no issue" grep -qF 'PR #60 (the health pass of step 3 Events: closes no issue)' <<<"$out"
ok "run label: the planner" eq "$(lib run_label plan-12)" "planner of step 3 Events"
live_lock pkg-12-a
ok "canccu-status: a running package shows its stage" grep -qE '^  #pkg-12-a fixing ' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"

# ---------------------------------------------------------------- never cleaned up

env_new cleanup-question
state 5 phase=merging pr=50 how=auto merge_sha=$HA
json pr50.json '{"state": "MERGED", "title": "feat: thing"}'; route 'pr view 50 *' pr50.json
json issue5.json '{"state": "CLOSED", "labels": [{"name": "in-progress"}]}'; route 'issue view 5 *' issue5.json
mkdir -p "$CANCCU_HOME/questions"; echo 'poll or push?' > "$CANCCU_HOME/questions/5.txt"
dispatch --once
ok "cleanup: a finished unit's question file goes" test ! -e "$CANCCU_HOME/questions/5.txt"

senv cleanup-plan-wt 3
cpi 95 CLOSED "3 Events" | jq -s . > "$FAKE/cps.json"
{ issue 90 epic "" "3 Events"; } | issues
wave 1 "$P2" checkpoint; printf 'health=merged\ncheckpoint_at=%s\n' "$NOW" >> "$CANCCU_HOME/steps/12"
mkdir -p "$WORKERS_DIR/worktrees/web/plan-12"
dispatch --once
ok "cleanup: the step done → its planner's worktree is removed" \
  eq "$(stepv phase) $(grep -c "^-C $E/code/web worktree remove --force $WORKERS_DIR/worktrees/web/plan-12$" "$FAKE/git.log")" "done 1"

# ---------------------------------------------------------------- code vs docs

# a step's stop is reported as a stop, not as an invalid plan
stopenv snap-stop
dispatch --once
S=$CANCCU_HOME/status.json
ok "snapshot: a stopped step → needs_you needs-you naming the stop" \
  eq "$(jq -r '[.needs_you[] | select(.step == 12) | "\(.kind) | \(.reason)"] | join(" ; ")' "$S")" \
  "needs-you | step 3 Events stopped: its epic #90 is closed while the step runs"

# canccu-ship refuses an issue the dispatcher does not manage (and that is not in progress)
env_new ship-unmanaged
{ issue 7 ready; } | issues
pr 70 7 $HA | prs
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 7 > "$E/out" 2>&1
ok "canccu-ship: a PR closing an issue nobody manages is not ours" \
  eq "$(grep -c '^pr merge' "$FAKE/gh.log") $(grep -c 'not ours: #7 is not managed by the dispatcher' "$E/out")" "0 1"
env_new ship-adoptable
{ issue 7 in-progress; } | issues
pr 70 7 $HA | prs
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 7 > "$E/out" 2>&1
ok "… an in-progress issue's PR (the next pass adopts it) ships" has gh.log "pr merge 70 -R example-org/web --auto --match-head-commit $HA"

# ---------------------------------------------------------------- review of #63 (non-blocking 2, 3, 5)

# a health pass whose recorded PR is still open but not ours (another branch) is not silently held
hpenv health-pr-foreign check CLOSED
PR_BRANCH=other pr 60 0 "$HA" | prs
dispatch --once
ok "health: its recorded PR still open but not ours → needs-you, not a silent wait" \
  grep -q '^issue comment 90 .*the worker finished without an open PR' "$FAKE/gh.log"

# a stop arriving while the step waits on an invalid plan: the plan's reason comes back after it
stopenv stop-over-plan
rm -f "$WORKERS_DIR/web-plan-12.lock"
sed -i 's/^phase=planning/phase=needs-you/; /^planner_started=/d' "$CANCCU_HOME/steps/12"
echo 'ny_reason=the plan of wave 1 is invalid: x' >> "$CANCCU_HOME/steps/12"
{ issue 95 checkpoint "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
dispatch --once
ok "stop over a plan's needs-you: the stop is raised" eq "$(stepv ny_kind)" stop
S=$CANCCU_HOME/status.json
ok "… the snapshot names the stop, then the plan" \
  grep -qF 'step 3 Events stopped: its epic #90 is closed while the step runs; then: the plan of wave 1 is invalid: x' \
  <<<"$(jq -r '.needs_you[] | select(.step == 12) | .reason' "$S")"
{ issue 90 epic,needs-you "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
dispatch --once
ok "… the stop resolved: the step waits on the plan again, with its reason" \
  eq "$(stepv phase) $(stepv ny_reason) $(grep -c -- '--key plan-12' "$FAKE/worker.log")" \
  "needs-you the plan of wave 1 is invalid: x 0"

echo "canccu-health-review tests: $npass passed, $nfail failed"
(( nfail == 0 ))
