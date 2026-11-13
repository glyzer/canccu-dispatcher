#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-pane.sh — the pane output, colours, spend, the status snapshot and the monitor (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- clean pane output

env_new clean-output
{ issue 3 ready; issue 4 ready; issue 6 blocked "Blocked by #5"; } | issues
state 5 phase=merging pr=50 how=auto merge_sha=$HA
json pr50.json '{"state": "MERGED", "title": "feat: thing"}'; route 'pr view 50 *' pr50.json
json issue5.json '{"state": "CLOSED", "labels": [{"name": "in-progress"}]}'; route 'issue view 5 *' issue5.json
route 'api repos/example-org/web/issues/4/dependencies/blocked_by' FAIL
mkdir -p "$WORKERS_DIR/worktrees/web/issue-5"; touch "$WORKERS_DIR/worktrees/web/issue-5/.git"
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/6"   # the dispatcher's own labels
touch "$FAKE/noisy"
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --dry-run 2>/dev/null)
ok "--dry-run still prints what it would do" grep -q '^  would: ' <<<"$out"
dispatch --once
ok "clean output: the pass merged, unblocked and started (it had things to say)" \
  eq "$(grep -cE '#5 merged|#6 unblocked|#3 started' "$E/out")" 3
ok "clean output: every line in the pane is one of the dispatcher's own" not grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ' "$E/out"
ok "… gh's URLs went to dispatch.log" grep -qF '  │ https://github.com/example-org/web/issues/' "$CANCCU_HOME/dispatch.log"
ok "… so did gh's merge-queue note" grep -qF '  │ ✓ Pull request' "$CANCCU_HOME/dispatch.log"
ok "… and git's Deleted branch" grep -qF '  │ Deleted branch issue-5-thing' "$CANCCU_HOME/dispatch.log"
ok "… and the stderr of a read" grep -qF '  │ warning: noisy git' "$CANCCU_HOME/dispatch.log"
ok "… the writes still ran" has git.log "branch -D issue-5-thing"

# ---------------------------------------------------------------- colour per issue

env_new colours
for n in 5 6 7; do state "$n" phase=work; done
ok "colour: the lowest free index" eq "$(lib claim_color 5; st 5 color)" 0
ok "colour: stable" eq "$(lib claim_color 5; st 5 color) $(lib issue_color 5)" "0 0"
ok "colour: the next issue the next index" eq "$(lib claim_color 6; st 6 color)" 1
ok "colour: without claim, nothing is assigned" eq "$(lib issue_color 7)$(st 7 color)" ""
rm "$CANCCU_HOME/state/5"   # closed: finish_issue removes the state file
ok "colour: freed on close and given again" eq "$(lib claim_color 7; st 7 color)" 0
ok "colour: the ANSI 256 code of the palette" eq "$(lib color_code 6)" 208

env_new colours-full CAP=3
for n in 1 2 3 4 5 6; do state "$n" phase=work "color=$((n - 1))"; touch -d "@$((NOW - 1000 + n))" "$CANCCU_HOME/state/$n"; done
for n in 1 2 3; do live_lock "$n"; done
touch -d "@$((NOW - 5000))" "$CANCCU_HOME/state/5"   # #5 has waited longest; #1 is older but runs
touch -d "@$((NOW - 6000))" "$CANCCU_HOME/state/1"
state 7 phase=work
ok "colour: all 6 held → the longest-waiting issue that is not running gives its up" eq "$(lib claim_color 7; st 7 color) $(st 5 color)" "4 -"
ok "colour: the running issues keep theirs, all different" eq "$(st 1 color) $(st 2 color) $(st 3 color) $(st 7 color)" "0 1 2 4"
ok "colour: the one that gave up gets none until it claims again" eq "$(lib color_code 5)" ""

env_new colours-all-running CAP=7
for n in 1 2 3 4 5 6; do state "$n" phase=work "color=$((n - 1))"; live_lock "$n"; done
state 7 phase=work
ok "colour: every holder running (CAP above 6) → shared, with a warning" eq "$(lib claim_color 7 >/dev/null; st 7 color)" 1
ok "… the warning is logged once" grep -q 'more than 6 issues run at once: some share a colour' "$CANCCU_HOME/dispatch.log"

env_new colours-start CAP=3
{ issue 30 ready; issue 31 ready; issue 32 ready; } | issues
dispatch --once
ok "colour: three issues started in one pass get three colours" eq "$(st 30 color) $(st 31 color) $(st 32 color)" "0 1 2"

env_new colours-pane
state 5 phase=work color=1
e=$'\e'
ok "pane colour: the issue number in its colour (forced terminal)" \
  eq "$(lib eval 'CANCCU_FORCE_COLOR=1 log "#5 worker done"')" "2030-11-05T12:00:00Z ${e}[38;5;208m#5${e}[0m worker done"
ok "pane colour: a needs-you line is red" grep -qF "${e}[31m needs-you: x${e}[0m" <<<"$(lib eval 'CANCCU_FORCE_COLOR=1 log "#5 needs-you: x"')"
ok "pane colour: a merged line is green" grep -qF "${e}[32m merged (PR #50, auto)" <<<"$(lib eval 'CANCCU_FORCE_COLOR=1 log "#5 merged (PR #50, auto)"')"
ok "pane colour: NO_COLOR → plain" not grep -q "$e" <<<"$(lib eval 'CANCCU_FORCE_COLOR=1 NO_COLOR=1 log "#5 needs-you: x"')"
ok "pane colour: not a terminal → plain" not grep -q "$e" <<<"$(lib log "#5 needs-you: x")"
ok "dispatch.log has no escape codes" not grep -q "$e" "$CANCCU_HOME/dispatch.log"
ok "… and has the lines" eq "$(grep -c '#5 ' "$CANCCU_HOME/dispatch.log")" 5

# the dispatcher's needs-you and awaiting-accept lines end with the item's link (the monitor's URL)
env_new log-urls
{ issue 5 in-progress; issue 6 in-progress; } | issues; pr 50 6 "$HA" | prs
state 5 phase=work; state 6 phase=review pr=50
ok "log: a needs-you line ends with the issue's URL" \
  grep -qE '#5 needs-you: CI is red · https://github.com/example-org/web/issues/5$' <<<"$(lib needs_you 5 "CI is red")"
ok "log: an awaiting-accept line ends with the PR's URL" \
  grep -qE '#6 PR #50: awaiting accept \(manual: x\) · https://github.com/example-org/web/pull/50$' <<<"$(lib eval "fetch; to_accept 6 50 'manual: x' $HA")"

env_new colours-tmux CAP=3
{ issue 30 ready; } | issues
mkdir -p "$E/tmuxw"
cat > "$E/tmuxw/tmux" <<'EOF2'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE/tmux.log"
case $1 in list-windows) printf '@7 lead\n@9 #30\n@11 #3\n' ;; esac
exit 0
EOF2
chmod +x "$E/tmuxw/tmux"
PATH="$E/tmuxw:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1
ok "tmux: the run's window gets the issue's colour" grep -qx 'set-option -w -t @9 window-status-style fg=colour33' "$FAKE/tmux.log"
ok "tmux: … and only that window, only window options" eq "$(grep -c '^set' "$FAKE/tmux.log") $(grep -c '^set-option -w -t @9 ' "$FAKE/tmux.log")" "2 2"
: > "$FAKE/tmux.log"; rm -f "$WORKERS_DIR"/*.lock; rm -rf "$CANCCU_HOME/state"
NO_COLOR=1 PATH="$E/tmuxw:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1
ok "tmux: NO_COLOR → no window style" not grep -q '^set' "$FAKE/tmux.log"

# ---------------------------------------------------------------- spend and progress

env_new spend
printf '%s\tweb\t5\t1.25\n%s\tweb\treview-50\t0.50\n%s\tweb\t4\t9.00\n%s\tother\t5\t7.00\n%s\tweb\t6\t?\n%s\tweb\t7\t?\n' \
  "$((NOW - 3600))" "$((NOW - 60))" "$((NOW - 86400))" "$((NOW - 60))" "$((NOW - 30))" "$((NOW - 86400))" > "$WORKERS_DIR/spend.log"
ok "spend: today's rows of this repo, exact, and today's runs without a cost apart" eq "$(lib spend_today)" "1.75 1"
rm "$WORKERS_DIR/spend.log"
ok "spend: no log → 0.00, none without a cost" eq "$(lib spend_today)" "0.00 0"
printf '\n=== 2030-11-05 11:00:00 web#5 "5 do it" session-id x · budget 250t/$80/150m · claude-opus-5-5\n[t1] hello\n[t2] → Bash ls\n│ out\n=== exit: done\n=== 2030-11-05 11:30:00 web#5 "5 fix" resume x · budget 80t/$20/45m · claude-opus-5-5\n[t1] again\n[t7] → Edit f\n│ done\n' > "$WORKERS_DIR/web-5.log"
ok "progress: the latest attempt's turns and caps" eq "$(lib run_progress 5)" "7 80 45"
printf '=== 2030-11-05 11:00:00 web#6 "6 x" session-id x · budget 60t/$15/40m\n' > "$WORKERS_DIR/web-6.log"
ok "progress: no turn yet → 0" eq "$(lib run_progress 6)" "0 60 40"
ok "progress: no log → nothing" eq "$(lib run_progress 9)" ""
# the real engine writes the spend line: a fake claude run that costs $0.42
mkdir -p "$E/cb" "$E/code/web/.git" "$E/wd"
sed 's/"total_cost_usd":0/"total_cost_usd":0.42/' "$fb/claude" > "$E/cb/claude"; chmod +x "$E/cb/claude"
printf 'repo=web\nkey=9\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-9.lock"
(cd "$E/wd" && PATH="$E/cb:$fb:$PATH" CODE_ROOT="$E/code" "$root/libexec/canccu-worker" __run web 9 5 1 2 "" "a prompt" "$E/wd" "" >/dev/null 2>&1)
ok "spend: the engine logs each finished run's exact cost" grep -qP '^[0-9]+\tweb\t9\t0.42\t' "$WORKERS_DIR/spend.log"
# a run stopped at its turn budget has no result event, hence no cost: it is logged as "?"
cat > "$E/cb/claude" <<'EOF2'
#!/bin/bash
for i in 1 2 3 4 5 6 7 8 9; do
  printf '{"type":"assistant","message":{"id":"m%s","content":[{"type":"text","text":"turn %s"}]}}\n' "$i" "$i"
  sleep 0.1
done
sleep 5
EOF2
chmod +x "$E/cb/claude"
printf 'repo=web\nkey=8\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-8.lock"
(cd "$E/wd" && PATH="$E/cb:$fb:$PATH" CODE_ROOT="$E/code" "$root/libexec/canccu-worker" __run web 8 3 1 2 "" "a prompt" "$E/wd" "" >/dev/null 2>&1)
ok "spend: a run stopped at its turn budget is logged without a cost" \
  eq "$(grep -c 'stopped: turn budget 3' "$WORKERS_DIR/web-8.last") $(grep -cP '^[0-9]+\tweb\t8\t\?\t' "$WORKERS_DIR/spend.log")" "1 1"
# a run killed (canccu-stop, worker --kill) before its report: one "?" line all the same
printf '#!/bin/bash\necho started > "%s/claude.started"\nsleep 30\n' "$E" > "$E/cb/claude"; chmod +x "$E/cb/claude"
printf 'repo=web\nkey=7\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-7.lock"
(cd "$E/wd" && PATH="$E/cb:$fb:$PATH" CODE_ROOT="$E/code" exec "$root/libexec/canccu-worker" __run web 7 5 1 2 "" "a prompt" "$E/wd" "" >/dev/null 2>&1) &
wk=$!
for _ in $(seq 50); do [ -e "$E/claude.started" ] && break; sleep 0.1; done
# killed the way canccu-stop and worker --kill do it: kill_tree (TERM, then KILL 3 s later)
{ ( . "$root/lib/canccu-engine.sh"; kill_tree "$wk" ); wait "$wk"; } 2>/dev/null   # bash says "Killed": expected here
ok "spend: a run killed by kill_tree is logged once, without a cost" \
  eq "$(test -e "$E/claude.started" && echo ran) $(grep -cP '^[0-9]+\tweb\t7\t\?\t' "$WORKERS_DIR/spend.log")" "ran 1"

# ---------------------------------------------------------------- the status snapshot

env_new snapshot CAP=3
{ issue 3 ready; issue 4 ready "Blocked by #9"; issue 9 ""; issue 8 needs-you; issue 5 in-progress,awaiting-accept
  issue 6 in-progress,needs-you; issue 10 in-progress; issue 12 checkpoint "" "2 Contracts"; } | issues
{ pr 50 5 $HA; pr 60 10 $HB; } | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 600))" "reason=manual: touches migrations"
state 6 phase=needs-you "ny_at=$((NOW - 300))" "reason=plan ready for OK" ny_kind=plan
state 10 phase=review pr=60 review_sha=$HB "started=$((NOW - 720))" stage=review color=2
live_lock review-60; mkdir -p "$CANCCU_HOME/reviews"; echo review > "$CANCCU_HOME/reviews/60.mode"
printf '=== 2030-11-05 11:48:00 web#review-60 "x" session-id s · budget 60t/$15/40m\n[t4] → Read src/a.ts\n' > "$WORKERS_DIR/web-review-60.log"
json ms.json '[{"title": "3 Screens", "open_issues": 4, "closed_issues": 1, "due_on": null},
               {"title": "2 Contracts", "open_issues": 2, "closed_issues": 6, "due_on": "2030-12-01T00:00:00Z"}]'
json cps.json '[{"number": 12, "title": "Checkpoint: contracts", "state": "OPEN", "milestone": {"title": "2 Contracts"}, "labels": [{"name": "checkpoint"}]},
                {"number": 2, "title": "Checkpoint: skeleton", "state": "CLOSED", "milestone": {"title": "1 Skeleton"}, "labels": [{"name": "checkpoint"}]}]'
json deps9.json '[]'
route 'api repos/example-org/web/milestones*' ms.json
route 'issue list -R example-org/web -s all -l checkpoint*' cps.json
printf '%s\tweb\t5\t2.50\n%s\tweb\t6\t?\n' "$((NOW - 100))" "$((NOW - 50))" > "$WORKERS_DIR/spend.log"
dispatch --once
S=$CANCCU_HOME/status.json
sj() { jq -r "$@" "$S" 2>/dev/null; }
ok "snapshot: written, schema 2" eq "$(sj .schema)" 2
ok "snapshot: no temp file left" eq "$(find "$CANCCU_HOME" -maxdepth 1 -name 'status.json.tmp*' | wc -l)" 0
ok "snapshot: every top-level key, typed" eq "$(sj '[.project, .repo, (.pid|type), (.interval|type), (.pass|type), (.caps|type), (.spend|type),
  (.running|type), (.needs_you|type), (.queue|type), (.milestones|type), (.events|type), (.stale|type)] | join(" ")')" \
  "web example-org/web number number object object object array array array array array array"
ok "snapshot: pass" eq "$(sj '[.pass.at, .pass.ok, .pass.error, .pass.paused, .pass.backoff_until] | map(tostring) | join(" ")')" "$NOW true null false null"
ok "snapshot: caps" eq "$(sj '[.caps.running, .caps.cap, .caps.total_running, .caps.total_cap] | map(tostring) | join(" ")')" "2 3 2 3"
ok "snapshot: today's spend and the freeze" eq "$(sj '[.spend.today_usd, .spend.runs_without_cost, .spend.day, .spend.freeze] | map(tostring) | join(" ")')" "2.5 1 2030-11-05 2031-03-01"
ok "snapshot: the pass's start, length and the last lengths (for the monitor's stale rule)" \
  eq "$(sj '[.pass.started, .pass.duration, (.pass.durations | length)] | map(tostring) | join(" ")')" "$NOW 0 1"
ok "snapshot: the started worker" eq "$(sj '.running[] | select(.key == "3") | [.issue, .kind, .pipeline, .color, .title] | map(tostring) | join(" ")')" "3 work work 33 Issue 3"
ok "snapshot: the reviewer: its issue, step, progress against caps, last line" \
  eq "$(sj '.running[] | select(.key == "review-60") | [.issue, .pr, .kind, .pipeline, .minutes, .turns, .turn_cap, .min_cap, .color, .last_line] | map(tostring) | join(" ")')" \
  "10 60 review review 0 4 60 40 135 [t4] → Read src/a.ts"
ok "snapshot: every running item has every field" eq "$(sj '[.running[] | keys | length] | unique | map(tostring) | join(" ")')" 20
ok "snapshot: needs you: accept (with the reason), plan, labelled (a checkpoint is the steps' now, tests/canccu-snapshot2.sh)" \
  eq "$(sj '[.needs_you[] | "\(.kind):\(.issue)"] | sort | join(" ")')" "accept:5 needs-you:8 plan:6"
ok "snapshot: … the accept's reason and PR link" eq "$(sj '.needs_you[] | select(.kind == "accept") | "\(.reason) \(.url)"')" "manual: touches migrations https://github.com/example-org/web/pull/50"
ok "snapshot: queue in order, the blocked one with what it waits on" eq "$(sj '[.queue[] | "\(.issue):\(.blocked):\(.waits_on)"] | join(" ")')" "4:true:blocked by 9"
ok "snapshot: milestones in roadmap order, with their checkpoints" \
  eq "$(sj '[.milestones[] | "\(.title)=\(.closed)/\(.open + .closed)[\([.checkpoints[] | "\(.issue)\(if .ready then "!" else "" end)"] | join(","))]"] | join(" ")')" \
  "2 Contracts=6/8[12] 3 Screens=1/5[]"
ok "snapshot: recent events, the dispatcher's own lines" eq "$(sj '[.events[] | select(.issue == 3) | .text] | first')" "#3 started: Issue 3"
ok "snapshot: no stale section" eq "$(sj '.stale | length')" 0
ok "snapshot: the pass and its snapshot read #4's blockers once" eq "$(grep -c 'issues/4/dependencies/blocked_by' "$FAKE/gh.log")" 1
# the pass's own temp dir only (TMPDIR private to this test), never other processes' on the host
mkdir -p "$E/ptmp"; TMPDIR=$E/ptmp dispatch --once
ok "snapshot: the pass's blockers cache is gone after it" eq "$(find "$E/ptmp" -mindepth 1 | wc -l)" 0
# a failed pass still writes it, with the GitHub sections of the last one
cp "$S" "$E/prev.json"
route 'issue list -R example-org/web -s open*' FAIL
dispatch --once
ok "snapshot: a failed pass writes ok=false and its error" eq "$(sj '[.pass.ok, .pass.error] | map(tostring) | join(" ")')" "false gh error reading issues or PRs"
ok "snapshot: … the GitHub sections are the last ones, listed stale" \
  eq "$(sj '.stale | join(" ")') $(jq -c '.queue' "$S" | cmp -s - <(jq -c .queue "$E/prev.json") && echo same)" "running needs_you queue milestones steps step_overview same"
ok "snapshot: … the running items keep the titles of the last snapshot" eq "$(sj '.running[] | select(.key == "review-60") | .title')" "Issue 10"
# broken old file, failed milestones read
echo '{"schema": 1, "queue": [' > "$S"
sed -i '/milestones/d; /FAIL/d' "$FAKE/routes"; route 'api repos/example-org/web/milestones*' FAIL
dispatch --once
ok "snapshot: a broken old snapshot and a failed milestones read → written, milestones stale" eq "$(sj '[.pass.ok, (.stale | join(","))] | map(tostring) | join(" ")')" "true milestones,steps,step_overview"
# a pass that dies half-way: one line in the pane, and the snapshot says so
CANCCU_TEST_PASS_DIES=1 dispatch --once
ok "a pass that ends early says so in the pane" grep -qE '^[0-9-]{10}T[0-9:]{8}Z the pass ended early \(exit 3\); its error is in dispatch.log$' "$E/out"
ok "… and in the snapshot" eq "$(sj '[.pass.ok, .pass.error] | map(tostring) | join(" ")')" "false the pass ended early (exit 3); see dispatch.log"
rm -f "$S"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --dry-run > /dev/null 2>&1
ok "snapshot: --dry-run writes none" test ! -e "$S"

# ---------------------------------------------------------------- canccu-monitor
# rich comes from a venv (CANCCU_VENV, else ~/.local/share/canccu/venv); the
# suite fails without it rather than skip the monitor

env_new monitor
mon() { CANCCU_VENV=$MON_VENV PATH="$fb:$PATH" "$root/bin/canccu-monitor" "$@" 2>&1; }
out=$(mon --self-test)
if grep -q 'needs the Python package rich' <<<"$out"; then
  nfail=$((nfail + 1)); echo "FAIL [monitor] canccu-monitor needs rich: set CANCCU_VENV to a venv with lib/canccu-monitor.requirements.txt"
else
  ok "monitor: --self-test (the mockup at 120x55 … 60x30, the drop order; fixtures at 60, 100 and 160 columns; redraws keep the cursor hidden)" eq "$(tail -1 <<<"$out")" "canccu-monitor self-test: ok"
  { issue 3 ready; issue 8 needs-you; } | issues
  dispatch --once
  : > "$FAKE/gh.log"; : > "$FAKE/git.log"
  out=$(CANCCU_PROJECT=web mon --once --width 100)
  ok "monitor: draws the snapshot the dispatcher wrote" \
    eq "$(grep -cE '━ ✖ NEEDS YOU · 1 ━|^NOW · running|^  #3  no PR yet  Issue 3$' <<<"$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")")" 3
  ok "monitor: reads only the snapshot: no gh, no git" eq "$(cat "$FAKE/gh.log" "$FAKE/git.log" | wc -l)" 0
  mkdir -p "$CANCCU_ROOT/projects/tools"; echo 'REPO=example-user/tools' > "$CANCCU_ROOT/projects/tools/config"
  echo '{"schema": 1, "needs_you": [{"kind": "accept", "issue": 1}, {"kind": "plan", "issue": 2}]}' > "$CANCCU_ROOT/projects/tools/status.json"
  out=$(CANCCU_PROJECT="" mon --project web --once --width 160 | sed 's/\x1b\[[0-9;]*m//g')
  ok "monitor: the other projects are in the header, their needs-you items in the box" \
    eq "$(grep -cE '^web · example-org/web · pass .*│  tools · no pass yet ⚠|NEEDS YOU · 3 |✖ ACCEPT   tools #1 ' <<<"$out")" 3
  out=$(CANCCU_PROJECT="" mon --project tools --once --width 70 | sed 's/\x1b\[[0-9;]*m//g')
  ok "monitor: --project picks that project's snapshot, its items first, all projects in one view" \
    eq "$(head -1 <<<"$out" | cut -d' ' -f1) $(grep -A1 '^✖ NEEDS YOU' <<<"$out" | tr -s ' ' | tr '\n' '|')" "tools ✖ NEEDS YOU · 3|✖ ACCEPT tools #1|"
  ok "… the other project's needs-you item, marked" grep -qE '^✖ STUCK web #8 · labelled needs-you$' <<<"$out"
  rm "$CANCCU_ROOT/projects/tools/status.json"
  out=$(CANCCU_PROJECT="" mon --project tools --once --width 70); rc=$?
  ok "monitor: no snapshot yet → one line, no crash" eq "$rc $(grep -c '^canccu-monitor: no snapshot yet' <<<"$out")" "0 1"
fi


echo "canccu-pane tests: $npass passed, $nfail failed"
(( nfail == 0 ))
