#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-steps.sh — offline tests for the roadmap steps: the current step, the plan's
# validation, the planner, waves, cross-step blockers, the health pass, the checkpoint, notes and
# the step budget. Harness: tests/lib/harness.sh.
#   bash tests/canccu-steps.sh    one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ms <number> <title> [closed issues]: one open milestone (the API's shape)
ms() { jq -nc --argjson n "$1" --arg t "$2" --argjson c "${3:-0}" '{number: $n, title: $t, open_issues: 0, closed_issues: $c, due_on: null}'; }
# cpi <n> <OPEN|CLOSED> <milestone title>: a checkpoint issue
cpi() { jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" '{number: $n, title: "Checkpoint \($n)", state: $s, milestone: {title: $m}, labels: [{name: "checkpoint"}]}'; }
# cs <milestones json> <checkpoints json> <issues json> [phases json]: the current steps' milestone numbers
cs() { lib current_steps_pure "$1" "$2" "$3" "${4:-{\}}" | jq -c '[.[] | .milestone]'; }
M1=$(ms 11 "1 Skeleton" 4) M2=$(ms 12 "2 Contracts" 2) M3=$(ms 13 "3 Events") PT=$(ms 19 "Parallel tracks" 1)
W2=$(issue 21 ready "" "2 Contracts") W3=$(issue 31 ready "" "3 Events") WP=$(issue 91 ready "" "Parallel tracks")

# ---------------------------------------------------------------- the current step (task 3)

env_new step-current
ok "step: the lowest milestone with open work is current" \
  eq "$(cs "[$M1,$M2,$M3]" "[$(cpi 5 CLOSED "1 Skeleton")]" "[$W2,$W3]")" "[12]"
ok "step: an open checkpoint keeps its step current (the pause)" \
  eq "$(cs "[$M1,$M2]" "[$(cpi 5 OPEN "1 Skeleton")]" "[$W2]")" "[11]"
ok "step: a step whose checkpoint is closed is not current" \
  eq "$(cs "[$M1,$M2]" "[$(cpi 5 CLOSED "1 Skeleton")]" "[$W2]")" "[12]"
ok "step: epic and checkpoint issues are not work" \
  eq "$(cs "[$M1,$M2]" "[$(cpi 5 CLOSED "1 Skeleton")]" "[$(issue 7 epic "" "1 Skeleton"),$W2]")" "[12]"
ok "step: Parallel tracks runs alongside" \
  eq "$(lib current_steps_pure "[$M2,$PT]" "[]" "[$W2,$WP]" '{}' | jq -c '[.[] | [.milestone, .track]]')" '[[12,"main"],[19,"parallel"]]'
ok "step: a Parallel tracks checkpoint gates nothing" \
  eq "$(cs "[$PT,$M3]" "[$(cpi 6 OPEN "Parallel tracks")]" "[$WP,$W3]")" "[13,19]"
ok "step: an empty step with an open checkpoint is current (idle); the next waits" \
  eq "$(cs "[$M3,$(ms 14 "4 Later")]" "[$(cpi 8 OPEN "3 Events")]" "[$(issue 41 ready "" "4 Later")]")" "[13]"
ok "step: a step whose state is still running stays current" \
  eq "$(cs "[$M1,$M2]" "[]" "[$W2]" '{"11":"health"}')" "[11]"
ok "step: a done step is not current" eq "$(cs "[$M1,$M2]" "[]" "[$W2]" '{"11":"done"}')" "[12]"
ok "step: no milestone → no step (the fast lane only)" eq "$(cs "[]" "[]" "[$(issue 5 ready)]")" "[]"
ok "step: the step data: epic, checkpoint, work counts" \
  eq "$(lib current_steps_pure "[$M1]" "[$(cpi 5 OPEN "1 Skeleton")]" "[$(issue 7 epic "" "1 Skeleton"),$(issue 8 ready "" "1 Skeleton")]" '{}' |
        jq -c '.[0] | [.epic, .checkpoint.issue, .checkpoint.state, .work_open, .work_closed, .track]')" '[7,5,"open",1,4,"main"]'

ok "step: a failed milestones read: no step acts; the fast lane still starts" eq "$(
  env_new step-noread; { issue 5 ready; issue 101 ready "" "3 Events"; } | issues
  route 'api repos/example-org/web/milestones*' FAIL; dispatch --once
  grep -c -- '--key plan-' "$FAKE/worker.log"; started 5 && echo fast; ls "$CANCCU_HOME/steps" 2>/dev/null | wc -l)" "0
fast
0"

# ---------------------------------------------------------------- plan validation (task 4)

pv() { lib plan_validate "$root/tests/fixtures/plans/$1.json" "$(cat "$root/tests/fixtures/plans/input.json")" 12 2; }
ok "plan: a valid plan has no errors"   eq "$(pv valid | jq -c .errors)" "[]"
ok "plan: an issue twice"               eq "$(pv duplicate | jq -r '.errors[0]')" "issue #101 is in more than one package (auth-flow, event-list)"
ok "plan: an unknown issue"             eq "$(pv unknown | jq -r '.errors[0]')" "issue #999 is unknown (not an open, unblocked ready issue of this step)"
ok "plan: a cycle"                      eq "$(pv cycle | jq -r '.errors[0]')" "dependency cycle: a → b → a"
ok "plan: a missing risk"               eq "$(pv missing-risk | jq -r '.errors[0]')" "event-list: risk missing or not low|normal|high"
ok "plan: a bad or reserved name"       eq "$(pv bad-name | jq -r '.errors | join("; ")')" 'package 1: bad name "Auth Flow"; package 2: bad name "health"'
ok "plan: an unknown dependency"        eq "$(pv unknown-dep | jq -r '.errors[0]')" "event-list depends on unknown package nope"
ok "plan: a self dependency"            eq "$(pv self-dep | jq -r '.errors[0]')" "a depends on itself"
ok "plan: a left-out issue is no error" eq "$(pv left-out | jq -c '[.errors, .left_out]')" "[[],[107]]"
ok "plan: a fenced file is not JSON"    eq "$(pv fenced | jq -r '.errors[0]')" "not JSON"
ok "plan (#54 review): a file of two plans is not one plan" \
  eq "$(cat "$root/tests/fixtures/plans/valid.json" "$root/tests/fixtures/plans/valid.json" > "$T/twice.json"
        lib plan_validate "$T/twice.json" "$(cat "$root/tests/fixtures/plans/input.json")" 12 2 | jq -sc 'map(.errors)')" '[["not JSON"]]'
ok "plan (review 3, finding 2): no depends_on is an empty list: valid, and its package is listed" \
  eq "$(jq 'del(.packages[].depends_on) | .packages |= .[:1]' "$root/tests/fixtures/plans/valid.json" > "$T/nodeps.json"
        lib plan_validate "$T/nodeps.json" "$(cat "$root/tests/fixtures/plans/input.json")" 12 2 | jq -c .errors) $(
        mkdir -p "$CANCCU_HOME/steps"; echo "plan=$T/nodeps.json" > "$CANCCU_HOME/steps/12"; lib plan_packages 12 | cut -f1,2 | tr '\t' :)" \
  "[] auth-flow:101 103"
ok "plan: a name an earlier package used (review #45, finding 6)" \
  eq "$(lib plan_validate "$root/tests/fixtures/plans/valid.json" "$(jq -c '.earlier = [{name: "auth-flow"}]' "$root/tests/fixtures/plans/input.json")" 12 2 | jq -r '.errors[0]')" \
  "package name auth-flow was used by an earlier package"

# #54: values over 256 KiB (Linux takes at most 128 KiB per argument) still reach jq
BIGIS=$(jq -nc '[range(1; 301) | {number: (1000 + .), title: "Issue \(.)", labels: [{name: "ready"}], body: ("b" * 1024),
                 milestone: {title: "2 Contracts"}}]')
BIGPK=$(jq -nc '[range(1; 301) | {name: "p\(.)", issues: [1000 + .], risk: "low", risk_reason: ("r" * 1024), areas: [], depends_on: []}]')
ok "#54: the values are over 256 KiB" eq "$(( ${#BIGIS} > 262144 && ${#BIGPK} > 262144 ))" 1
ok "#54: current_steps_pure takes 300 issues with 1 KiB bodies" eq "$(cs "[$M1,$M2]" "[$(cpi 5 CLOSED "1 Skeleton")]" "$BIGIS")" "[12]"
ok "#54: plan_validate takes a large input" \
  eq "$(lib plan_validate "$root/tests/fixtures/plans/valid.json" "$(jq -c --slurpfile is <(printf '%s' "$BIGIS") '.issues += $is[0]' \
          "$root/tests/fixtures/plans/input.json")" 12 2 | jq -c '[.errors, (.left_out | length)]')" "[[],300]"
ok "#54: carry_kept takes a large plan" \
  eq "$(lib carry_kept "$(jq -c '{packages: (. + [{name: "x", issues: [201]}])}' <<<"$BIGPK")" \
          '[{"name":"e","issues":[201],"depends_on":[]},{"name":"f","issues":[202],"depends_on":[]}]' | jq -c 'map(.name)')" '["f"]'
ok "#54: plan_carry takes a large carried list" \
  eq "$(lib plan_carry '{"packages":[{"name":"e","issues":[201],"depends_on":[]}]}' "$BIGPK" | jq '.packages | length')" 301
ok "#54: plan_allowed takes a large carried list" eq "$(lib plan_allowed 12 "$BIGPK" | jq '.carried | length')" 300
ok "#54 (review): a package the snapshot cannot look up again is left out, not a stub" \
  eq "$(mkdir -p "$CANCCU_HOME/steps"
        jq -nc '{packages: [{name: "ok", issues: [101], risk: "low"}, {name: "a\\b", issues: [102], risk: "low"}]}' > "$T/esc.json"
        printf 'plan=%s\nwave=1\n' "$T/esc.json" > "$CANCCU_HOME/steps/12"; lib eval '. "$root/lib/canccu-snapshot.sh"; snap_packages 12' | jq -c '[.packages[].name]')" '["ok"]'

# ---------------------------------------------------------------- the planner (task 5)

# stepenv <name> [config...]: step "3 Events" (milestone 12): epic 90, checkpoint 95, ready 101 103 104
stepenv() {
  env_new "$@"
  ms 12 "3 Events" 0 | jq -s . > "$FAKE/ms.json"
  cpi 95 OPEN "3 Events" | jq -s . > "$FAKE/cps.json"
  { issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
  json c90.json '{"comments": [], "labels": [{"name": "epic"}]}'; route 'issue view 90 *' c90.json
  route 'api -X PATCH *' empty.json
}
# planned <w> <plan json>: the running planner of wave w ended with this plan as its final message
planned() { rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 done "$2"; }
PLAN='{"schema":1,"step":12,"wave":1,"packages":[
  {"name":"auth-flow","issues":[101,103],"risk":"high","risk_reason":"sessions","areas":["src/auth/"],"depends_on":[]},
  {"name":"list","issues":[104],"risk":"low","risk_reason":"a list","areas":["src/web/"],"depends_on":["auth-flow"]}]}'

stepenv planner
dispatch --once
ok "planner: ready issues and no plan → the planner starts, untrusted, in its own worktree" \
  grep -qF -- "--key plan-12 --dir $WORKERS_DIR/worktrees/web/plan-12 --name plan#12 --untrusted web " "$FAKE/worker.log"
ok "… its prompt names the ready, unblocked, unmanaged step issues" eq "$(pissues)" "#101, #103, #104"
ok "… and gives it no directory (no --add-dir of the project's)" not grep -q "WORKER_ADD_DIRS=.*$CANCCU_HOME" "$FAKE/worker.envdump"
ok "… the prompt carries the rules and the schema" grep -qF 'never split an issue, never create one' "$FAKE/worker.log"
ok "… phase planning" eq "$(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" planning
dispatch --once
ok "planner: no second planner while it runs" eq "$(grep -c -- '--key plan-12' "$FAKE/worker.log")" 1
planned 1 "$PLAN"; dispatch --once
ok "planner: a valid plan → wave 1 running" eq "$(sed -n 's/^phase=//p;s/^wave=//p' "$CANCCU_HOME/steps/12" | tr '\n' ' ')" "running 1 "
ok "… one comment on the epic with both markers" grep -q '^issue comment 90 .*canccu-plan.*canccu-dispatch' "$FAKE/gh.log"
ok "… the package with no dependency starts" grep -qF -- "--name pkg#auth-flow --key pkg-12-auth-flow --dir $WORKERS_DIR/worktrees/web/pkg-12-auth-flow --keep-session web pkg-12-auth-flow " "$FAKE/worker.log"
ok "… its dependant waits" not grep -q -- '--name #104' "$FAKE/worker.log"
ok "… every member in progress, ready removed" eq "$(grep -cE '^issue edit (101|103) -R example-org/web --add-label in-progress --remove-label ready' "$FAKE/gh.log")" 2
ok "… the package state" eq "$(cat "$CANCCU_HOME/state/pkg-12-auth-flow" | grep -E '^(members|branch|risk)=' | sort | tr '\n' ' ')" "branch=pkg-12-auth-flow members=101 103 risk=high "
ok "… the budget scaled by 2 issues" grep -qE 'pkg-12-auth-flow .* turns=500 cost=160 min=300$' "$FAKE/worker.log"
ok "… the package prompt: subagents without their reviews, Closes lines, Package and Risk" \
  grep -qF 'skip their review steps' "$FAKE/worker.log"
ok "… the planner's key and the package's are charged to the step" eq "$(tr '\n' ' ' < "$CANCCU_HOME/steps/12.keys")" "plan-12 pkg-12-auth-flow "

# the plan comment is edited in place on the next wave
json c90.json "$(jq -n --arg b "x $(printf '<!-- canccu-plan -->')"$'\n\n<!-- canccu-dispatch -->' '{comments: [{author: {login: "octo"}, body: $b, url: "https://github.com/example-org/web/issues/90#issuecomment-777"}]}')"
lib eval 'fetch; post_plan 12' >/dev/null 2>&1
ok "planner: the next wave edits the same comment (PATCH), not a second one" grep -q '^api -X PATCH repos/example-org/web/issues/comments/777 ' "$FAKE/gh.log"
# … and the edited body shows a path under $HOME as ~/…, like every posted text
pf=$(sed -n 's/^plan=//p' "$CANCCU_HOME/steps/12" | tail -1)
jq '.packages[0].risk_reason = "touches /home/someone/code/web/src/auth"' "$pf" > "$pf.tmp" && mv "$pf.tmp" "$pf"
: > "$FAKE/gh.log"
lib eval 'HOME=/home/someone; fetch; post_plan 12' >/dev/null 2>&1
ok "planner: the PATCH body shows a \$HOME path as ~/" grep -qF 'touches ~/code/web/src/auth' <(grep '^api -X PATCH' "$FAKE/gh.log")
ok "… and has no /home/" not grep -q /home/ <(grep '^api -X PATCH' "$FAKE/gh.log")

# review #45, finding 1: the untrusted planner never decides which issues are eligible
# (a) it plans an issue it was not given (not ready): unknown, nothing starts
stepenv planner-allowlist
{ issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; issue 104 ready "" "3 Events"
  issue 200 "" "" "3 Events"; } | issues
dispatch --once
planned 1 '{"schema":1,"step":12,"wave":1,"packages":[{"name":"x","issues":[200],"risk":"low","risk_reason":"x","areas":[],"depends_on":[]}]}'
dispatch --once
ok "planner (finding 1): an issue it was not given is unknown → needs-you" \
  grep -q '^issue comment 90 .*the plan of wave 1 is invalid: issue #200 is unknown' "$FAKE/gh.log"
ok "… the dispatcher's line ends with the epic's URL" grep -qE 'needs-you: the plan of wave 1 is invalid: .* · https://github.com/example-org/web/issues/90$' "$E/out"
ok "… #200 is never built" not grep -qE -- '--name (#200|pkg#x) ' "$FAKE/worker.log"
# (b) review 2, finding 1: a planner that plants symlinks (and a FIFO) where it can write: the
# dispatcher reads only its final message, writes nowhere it can reach, and remakes its worktree
stepenv planner-symlink
cp "$CANCCU_HOME/config" "$E/config.before"
# what an earlier planner left in its worktree: links to the config, a FIFO
W=$WORKERS_DIR/worktrees/web/plan-12; mkdir -p "$W"; : > "$W/.git"
ln -s "$CANCCU_HOME/config" "$W/wave-1.json"; ln -s "$CANCCU_HOME/config" "$W/input-1.json"; mkfifo "$W/plan.fifo"
mkdir -p "$CANCCU_HOME/plans" "$E/trap"; ln -s "$E/trap" "$CANCCU_HOME/plans/12"
dispatch --once
ok "planner (review 2, finding 1): its worktree is made afresh (the old one removed first)" grep -qF "worktree remove --force $W" "$FAKE/git.log"
planned 1 "$PLAN"
timeout 60 bash -c 'PATH="$1:$PATH" CANCCU_WORKER="$1/worker" "$2/bin/canccu-dispatch" --once > /dev/null 2>&1' _ "$fb" "$root"; rc=$?
ok "… the pass is not blocked and takes the plan from the final message" eq "$rc $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "0 running"
ok "… the plan in use is the dispatcher's own copy" eq "$(sed -n 's/^plan=//p' "$CANCCU_HOME/steps/12")" "$CANCCU_HOME/steps/12.plan-1.json"
ok "… nothing was written through a planted link: the config is unchanged" cmp -s "$CANCCU_HOME/config" "$E/config.before"
ok "… and the dispatcher wrote nothing through the old plans/ link" eq "$(find "$E/trap" -mindepth 1 | wc -l)" 0
# (c) an issue that stops being eligible after the plan (its ready label removed) is not built
stepenv planner-recheck CAP=1
dispatch --once
planned 1 '{"schema":1,"step":12,"wave":1,"packages":[{"name":"a","issues":[104],"risk":"low","risk_reason":"x","areas":[],"depends_on":[]}]}'
live_lock 5; dispatch --once   # the plan is taken; no slot to start it
{ issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; issue 104 "" "" "3 Events"; } | issues
rm -f "$WORKERS_DIR/web-5.lock"; dispatch --once
ok "planner (finding 1): a planned issue no longer ready is not started" not grep -q -- '--name #104 ' "$FAKE/worker.log"
ok "… its package is refused, so the wave is over and the rest is planned again" \
  eq "$(lib eval 'fetch; fetch_steps; package_status 12 a') $(grep -c -- '--key plan-12' "$FAKE/worker.log")" "refused 2"

stepenv planner-bad
dispatch --once; planned 1 '{"schema":1,"step":12,"wave":1,"packages":[{"name":"a","issues":[101,999],"risk":"low","risk_reason":"x","areas":[],"depends_on":[]}]}'
dispatch --once
ok "planner: an invalid plan → the step needs-you on the epic with the reason" \
  grep -q '^issue comment 90 .*the plan of wave 1 is invalid: issue #999 is unknown' "$FAKE/gh.log"
ok "… nothing starts" not grep -q -- '--name pkg#' "$FAKE/worker.log"
ok "… labelled" grep -q '^issue edit 90 -R example-org/web --add-label needs-you' "$FAKE/gh.log"
{ issue 90 "epic,needs-you" "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
dispatch --once
ok "… while it carries needs-you, no planner" eq "$(grep -c -- '--key plan-12' "$FAKE/worker.log")" 1
{ issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
json c90.json "$(jq -n '{comments: [{author: {login: "octo"}, createdAt: "2030-11-05T13:00:00Z", body: "put 101 alone"}]}')"
dispatch --once
ok "planner: needs-you removed → it plans again with the lead's comment" eq "$(grep -c -- '--key plan-12' "$FAKE/worker.log") $(grep -- '--key plan-12' "$FAKE/worker.log" | tail -1 | grep -o 'The lead adds: put 101 alone')" "2 The lead adds: put 101 alone"

stepenv planner-none
dispatch --once; rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 "stopped: turn budget 60"
dispatch --once
ok "planner: it stopped without a plan → needs-you" grep -q '^issue comment 90 .*the planner of wave 1 ended without a plan' "$FAKE/gh.log"
stepenv planner-prose
dispatch --once; planned 1 $'Here is the plan:\n```json\n'"$PLAN"$'\n```'
dispatch --once
ok "planner: a final message that is not only the JSON plan → needs-you, not JSON" grep -q '^issue comment 90 .*the plan of wave 1 is invalid: not JSON' "$FAKE/gh.log"

stepenv planner-usage
dispatch --once; rm -f "$WORKERS_DIR/web-plan-12.lock"; last plan-12 "error" "Claude AI usage limit reached|$((NOW + 600))"
dispatch --once
ok "planner: the usage limit → back-off, no needs-you" eq "$(test -s "$CANCCU_ROOT/backoff" && echo backoff) $(grep -c 'needs-you' "$FAKE/gh.log")" "backoff 0"
rm -f "$CANCCU_ROOT/backoff"; dispatch --once
ok "… plans again after it" eq "$(grep -c -- '--key plan-12' "$FAKE/worker.log")" 2

stepenv planner-cap CAP=1
{ issue 5 ready; issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; } | issues
dispatch --once
ok "planner: CAP 1 and a fast-lane issue → the fast lane goes first, the planner waits" eq "$(started 5 && echo fast) $(grep -c -- '--key plan-12' "$FAKE/worker.log")" "fast 0"

stepenv planner-dry
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" CANCCU_DRY=1 "$root/bin/canccu-dispatch" --dry-run > "$E/out" 2>&1
ok "planner: --dry-run starts nothing and writes no step state" eq "$(grep -c . "$FAKE/worker.log") $(ls "$CANCCU_HOME/steps" 2>/dev/null | wc -l)" "0 0"
ok "… it says it would start the planner" grep -q 'would: start planner plan#12' "$E/out"
ok "… it prints the current step" grep -q '^  3 Events · ' "$E/out"
ok "… and writes no step state" test ! -e "$CANCCU_HOME/steps/12"

# review 3, finding 1: a stop raised while the planner runs holds the wave that planner brings
stepenv planner-stopped
dispatch --once
{ issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; issue 104 ready "" "3 Events"
  issue 105 ready "" "3 Events"; } | issues
printf 'x\tz\t0\t105\tlow\t49\tmerged\n' > "$CANCCU_HOME/steps/12.packages"   # a finished package's issue is open again
dispatch --once
planned 1 "$PLAN"; dispatch --once
ok "planner (review 3, finding 1): the plan of a stopped step starts nothing" \
  eq "$(grep -c -- '--name pkg#' "$FAKE/worker.log") $(sed -n 's/^ny_from=//p' "$CANCCU_HOME/steps/12") $(sed -n 's/^phase=//p' "$CANCCU_HOME/steps/12")" "0 running needs-you"
{ issue 90 epic,needs-you "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; issue 104 ready "" "3 Events"; } | issues
dispatch --once
ok "… once the stop is resolved the wave runs and the label goes" \
  eq "$(grep -c -- '--name pkg#auth-flow' "$FAKE/worker.log") $(grep -c '^issue edit 90 -R example-org/web --remove-label needs-you' "$FAKE/gh.log")" "1 1"

# #107: a step waits on needs-you with nothing to answer on (no epic, no checkpoint): the pass asks
# for no unit's state with an empty key, so no shell error reaches stderr or the log
stepenv ny-noissue
echo '[]' > "$FAKE/cps.json"
{ issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
mkdir -p "$CANCCU_HOME/steps"; printf 'phase=needs-you\nny_kind=\nny_reason=the plan is invalid\nny_at=%s\n' "$NOW" > "$CANCCU_HOME/steps/12"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2> "$E/err"
ok "a needs-you step with no epic or checkpoint: nothing on stderr" eq "$(cat "$E/err")" ""
ok "… no shell error in the log" not grep -qE 'read error|unbound variable' "$CANCCU_HOME/dispatch.log"

echo "canccu-steps tests: $npass passed, $nfail failed"
(( nfail == 0 ))
