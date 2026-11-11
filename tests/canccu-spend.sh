#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-spend.sh — offline tests for the run settings and the spend log: the health pass's
# model and effort (HEALTH_MODEL, HEALTH_EFFORT), the spend log's per-run columns (tokens, model,
# effort, run type, session, window change, outcome) and the cost-per-merged-PR report
# (canccu-status --spend). Harness: tests/lib/harness.sh.
#   bash tests/canccu-spend.sh   one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

ms() { jq -nc --argjson n "$1" --arg t "$2" --argjson c "${3:-0}" '{number: $n, title: $t, open_issues: 0, closed_issues: $c, due_on: null}'; }
# henv <name> [config...]: step "3 Events" (milestone 12) has every work issue closed, so its
# health pass starts on the next pass
henv() {
  local n=$1; shift
  env_new "$n" "$@"
  ms 12 "3 Events" 3 | jq -s . > "$FAKE/ms.json"
  jq -nc '{number: 95, title: "Checkpoint 95", state: "OPEN", milestone: {title: "3 Events"}, labels: [{name: "checkpoint"}]}' | jq -s . > "$FAKE/cps.json"
  json c90.json '{"comments": []}'; route 'issue view 90 *' c90.json; route 'api -X PATCH *' empty.json
  { issue 90 epic "" "3 Events"; } | issues
  touch "$FAKE/comment-urls"
}
# hline: the health pass's start in worker.log; henv_of <var>: its value in that start's environment
hline() { grep -F -- '--key pkg-12-health' "$FAKE/worker.log"; }
henv_of() { awk -v v="$1" '/^=== / { h = ($0 ~ /--key pkg-12-health/) } h && index($0, v "=") == 1 { sub(/^[^=]*=/, ""); print }' "$FAKE/worker.envdump"; }

# ---------------------------------------------------------------- the health pass's model and effort (#75)

henv health-set MODEL=claude-opus-5-5 HEALTH_MODEL=claude-haiku-5-5 HEALTH_EFFORT=low
dispatch --once
ok "health: HEALTH_MODEL is the health pass's model" grep -qF -- '--model claude-haiku-5-5' <<<"$(hline)"
ok "… HEALTH_EFFORT its effort" eq "$(henv_of WORKER_EFFORT)" low
ok "… its run type is health" eq "$(henv_of WORKER_RUN_TYPE)" health

henv health-unset MODEL=claude-opus-5-5
dispatch --once
ok "health: no HEALTH_MODEL → MODEL" grep -qF -- '--model claude-opus-5-5' <<<"$(hline)"
ok "… no HEALTH_EFFORT → no effort, as before" eq "$(henv_of WORKER_EFFORT)" ""

henv health-bad HEALTH_EFFORT=fast
dispatch --once
ok "health: an effort claude does not know is not passed" eq "$(henv_of WORKER_EFFORT)" ""
ok "… and said" grep -q 'HEALTH_EFFORT is not an effort level' "$CANCCU_HOME/dispatch.log"

env_new health-not-others MODEL=claude-opus-5-5 HEALTH_MODEL=claude-haiku-5-5 HEALTH_EFFORT=low
{ issue 10 ready; } | issues
dispatch --once
ok "a worker of an issue keeps MODEL and no effort" \
  eq "$(grep -c -- '--model claude-opus-5-5 --name #10 ' "$FAKE/worker.log") $(grep -c '^WORKER_EFFORT=low' "$FAKE/worker.envdump")" "1 0"

ok "health: the prompt asks for a short report for the lead" grep -q 'Keep that report short' <<<"$(lib health_prompt 12 pkg-12-health)"

# the real engine passes the effort to claude as --effort, and none without one
mkdir -p "$E/code/web/.git" "$E/wd"
printf 'repo=web\nkey=9\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-9.lock"
(cd "$E/wd" && PATH="$fb:$PATH" CODE_ROOT="$E/code" WORKER_EFFORT=low "$root/libexec/canccu-worker" __run web 9 5 1 2 "" "a prompt" "$E/wd" "" >/dev/null 2>&1)
ok "engine: WORKER_EFFORT → claude --effort" grep -qF -- '--effort low' "$FAKE/claude.args"
: > "$FAKE/claude.args"
printf 'repo=web\nkey=9\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-9.lock"
(cd "$E/wd" && PATH="$fb:$PATH" CODE_ROOT="$E/code" "$root/libexec/canccu-worker" __run web 9 5 1 2 "" "a prompt" "$E/wd" "" >/dev/null 2>&1)
ok "engine: no WORKER_EFFORT → no --effort" not grep -qF -- '--effort' "$FAKE/claude.args"

# ---------------------------------------------------------------- the spend log's columns (#72)

# env_of <header pattern> <var>: the variable in the fake engine's environment for the start whose
# command line matches the pattern (the last such start)
env_of() { awk -v p="$1" -v v="$2" '/^=== / { h = ($0 ~ p); if (h) val = "" } h && index($0, v "=") == 1 { val = substr($0, length(v) + 2) } END { print val }' "$FAKE/worker.envdump"; }
# col <n> <line>: a spend.log line's column
col() { cut -f"$1" <<<"$2"; }

env_new spend-engine
mkdir -p "$E/cb" "$E/code/web/.git" "$E/wd"
cat > "$E/cb/claude" <<'EOF2'
#!/bin/bash
echo '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.45,"resetsAt":4102444800}}}}'
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.42,"result":"ok","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}'
EOF2
chmod +x "$E/cb/claude"
run11() { printf 'repo=web\nkey=11\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-11.lock"
          (cd "$E/wd" && PATH="$E/cb:$fb:$PATH" CODE_ROOT="$E/code" "$@" "$root/libexec/canccu-worker" __run web 11 5 1 2 claude-x "a prompt" "$E/wd" "" >/dev/null 2>&1); }
run11 env WORKER_RUN_TYPE=build WORKER_EFFORT=low
ok "engine: the old columns first, then type, model, effort, session, the tokens; no window, no outcome yet" \
  grep -qP '^[0-9]+\tweb\t11\t0.42\tbuild\tclaude-x\tlow\tfresh\t100\t20\t300\t40\t-\t-\t-$' "$WORKERS_DIR/spend.log"
run11 env WORKER_RUN_TYPE=review WORKER_EFFORT_NOTE=medium WORKER_WINDOW_DELTA=1 WORKER_WINDOW_BEFORE=40
ok "engine: a resumed session; the effort note without an effort; the window before and after (USAGE_WINDOW_DELTA=1)" \
  grep -qP '^[0-9]+\tweb\t11\t0.42\treview\tclaude-x\tmedium\tresumed\t100\t20\t300\t40\t40\t45\t-$' "$WORKERS_DIR/spend.log"
sed -i '/rate_limit_event/d' "$E/cb/claude"; rm -f "$WORKERS_DIR/usage.json"
run11 env WORKER_WINDOW_DELTA=1 WORKER_WINDOW_BEFORE=40
ok "engine: no reading from this run → the window after is unknown" eq "$(tail -1 "$WORKERS_DIR/spend.log" | cut -f5,13,14)" "-	40	-"
cat > "$E/cb/claude" <<'EOF2'
#!/bin/bash
for i in 1 2 3 4 5 6 7 8 9; do printf '{"type":"assistant","message":{"id":"m%s","content":[{"type":"text","text":"t"}]}}\n' "$i"; done
EOF2
run11 env WORKER_RUN_TYPE=build
ok "engine: a run with no result has no cost and no tokens" eq "$(tail -1 "$WORKERS_DIR/spend.log" | cut -f4,5,9-12)" "?	build	-	-	-	-"
ok "engine: every line has 15 columns" eq "$(awk -F '\t' 'NF != 15' "$WORKERS_DIR/spend.log")" ""

# the dispatcher names each run's type, and the window before when USAGE_WINDOW_DELTA=1
env_new spend-types USAGE_WINDOW_DELTA=1
jq -n --argjson at "$NOW" '{at: $at, info: {unifiedWindows: {five_hour: {utilization: 0.3, resetsAt: ($at + 3600)}}}}' > "$WORKERS_DIR/usage.json"
{ issue 10 ready; } | issues
dispatch --once
ok "type: a new issue's worker is a build" eq "$(env_of '#10 ' WORKER_RUN_TYPE)" build
ok "window: the 5-hour share at the start, with USAGE_WINDOW_DELTA=1" eq "$(env_of '#10 ' WORKER_WINDOW_BEFORE) $(env_of '#10 ' WORKER_WINDOW_DELTA)" "30 1"
env_new spend-nodelta
jq -n --argjson at "$NOW" '{at: $at, info: {unifiedWindows: {five_hour: {utilization: 0.3, resetsAt: ($at + 3600)}}}}' > "$WORKERS_DIR/usage.json"
{ issue 10 ready; } | issues
dispatch --once
ok "window: off by default" eq "$(env_of '#10 ' WORKER_WINDOW_BEFORE) $(env_of '#10 ' WORKER_WINDOW_DELTA)" " 0"

effenv spend-review '[{"filename": "src/a.ts", "changes": 10}]' "Tier: feature"
dispatch --once
ok "type: the full review, with its code-review effort as the effort" \
  eq "$(env_of 'review#50' WORKER_RUN_TYPE) $(env_of 'review#50' WORKER_EFFORT_NOTE) $(env_of 'review#50' WORKER_EFFORT)" "review high "

review_env spend-fix 'Review verdict: changes' review
dispatch --once
ok "type: the worker resumed with the review's findings is a fix" eq "$(env_of 'The independent reviewer asked for changes' WORKER_RUN_TYPE)" fix

# ---------------------------------------------------------------- the outcome column (spend_note)

env_new spend-note
L5="$((NOW - 100))	web	5	2.00	build	-	-	fresh	1	2	3	4	-	-	-"
printf '%s\tweb\t5\t1.00\n%s\n%s\tweb\t6\t3.00\tbuild\t-\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 900))" "$L5" "$((NOW - 50))" > "$WORKERS_DIR/spend.log"
lib spend_note 5 "$((NOW - 200))" pr=50 rounds=0
ok "note: the key's newest line since the run started gets the outcome" eq "$(sed -n 2p "$WORKERS_DIR/spend.log" | cut -f15)" "pr=50,rounds=0"
ok "… the other lines stay as they were" eq "$(sed -n '1p;3p' "$WORKERS_DIR/spend.log" | cut -f1-4 | tr '\n' ' ')" "$((NOW - 900))	web	5	1.00 $((NOW - 50))	web	6	3.00 "
lib spend_note 5 "$((NOW - 200))" ci=green pr=51
ok "note: a field already there is replaced, a new one added" eq "$(sed -n 2p "$WORKERS_DIR/spend.log" | cut -f15)" "rounds=0,ci=green,pr=51"
ok "… the other columns are untouched" eq "$(sed -n 2p "$WORKERS_DIR/spend.log" | cut -f1-14)" "$(cut -f1-14 <<<"$L5")"
cp "$WORKERS_DIR/spend.log" "$E/before"
lib spend_note 5 "$((NOW - 10))" ci=red
ok "note: no line since the run started → nothing changes" cmp -s "$E/before" "$WORKERS_DIR/spend.log"
lib spend_note 5 "$((NOW - 1000))" x=1
ok "note: an old four-column line … is never the newest of a later run" eq "$(sed -n 1p "$WORKERS_DIR/spend.log")" "$((NOW - 900))	web	5	1.00"
printf '%s\tweb\t7\t1.00\n' "$((NOW - 5))" >> "$WORKERS_DIR/spend.log"
lib spend_note 7 0 pr=none
ok "… and one written by hand gets the missing columns as -" eq "$(tail -1 "$WORKERS_DIR/spend.log")" "$((NOW - 5))	web	7	1.00	-	-	-	-	-	-	-	-	-	-	pr=none"

printf 'Blocking:\n1. src/a.ts:3 off by one; fix: use <=\n   - nested detail\n2. src/b.ts:9 leak\n\nNon-blocking:\n- naming\n* wording\n\nRisk: normal — x\nReview verdict: changes %s\n' "$HA" > "$E/rev.md"
ok "findings: blocking before Non-blocking, non-blocking after, top-level items only" eq "$(lib findings_count "$E/rev.md")" "2 2"
ok "findings: no file → none" eq "$(lib findings_count "$E/none.md")" "0 0"
# #94: what a passed review lists before any heading (what it checked) counts as neither
printf 'Checked:\n1. the tests\n2. the docs\n3. the config\n\nNon-blocking:\n- naming\n\nReview verdict: pass %s\n' "$HA" > "$E/pass.md"
ok "findings: a passed review's list of checks, no Blocking heading → 0 blocking" eq "$(lib findings_count "$E/pass.md")" "0 1"
printf 'I checked:\n- the tests\n\n**Blocking**\n1. src/a.ts:3 off by one\n\n## Non-blocking\n- naming\n- wording\n' > "$E/both.md"
ok "findings: both headings → each part counted, the items before them in neither" eq "$(lib findings_count "$E/both.md")" "1 2"
printf '%s\tweb\treview-50\t1.00\treview\t-\thigh\tfresh\t-\t-\t-\t-\t-\t-\t-\n%s\tweb\t5\t1.00\tfix\t-\t-\tresumed\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 30))" "$((NOW - 20))" >> "$WORKERS_DIR/spend.log"
touch -d "@$NOW" "$E/rev.md"
lib spend_review_note 5 50 "$E/rev.md" "$HA" "$((NOW - 100))"
ok "note: a review's verdict, its findings and the unit's fix rounds" eq "$(grep -P '\treview-50\t' "$WORKERS_DIR/spend.log" | cut -f15)" "verdict=changes,blocking=2,nonblocking=2,rounds=1"

# the dispatcher notes the outcome when it reaps the run, and CI when it checks the PR
env_new spend-reap
{ issue 5 in-progress; } | issues
pr 50 5 $HA pending | prs
state 5 phase=work "started=$((NOW - 600))"
last 5 done
printf '%s\tweb\t5\t2.00\tbuild\t-\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 10))" > "$WORKERS_DIR/spend.log"
dispatch --once
ok "reap: the worker's line names its PR and the fix rounds so far" eq "$(cut -f15 "$WORKERS_DIR/spend.log")" "pr=50,rounds=0"
pr 50 5 $HA red | prs
dispatch --once
ok "check: CI red on its PR is noted on the worker's line" eq "$(cut -f15 "$WORKERS_DIR/spend.log")" "pr=50,rounds=0,ci=red"

# ---------------------------------------------------------------- the cost per merged PR (canccu-status --spend)

env_new spend-report
printf '%s\t5\t50\tauto-merge\tIssue 5\n' "$((NOW - 10))" > "$CANCCU_HOME/merged.log"
{ printf '%s\tweb\t5\t1.00\n' "$((NOW - 600))"
  printf '%s\tweb\t5\t2.00\tbuild\tclaude-opus-5-5\t-\tfresh\t-\t-\t-\t-\t-\t-\tpr=50\n' "$((NOW - 500))"
  printf '%s\tweb\treview-50\t1.00\treview\tclaude-sonnet-5-5\thigh\tfresh\t-\t-\t-\t-\t-\t-\tverdict=changes\n' "$((NOW - 400))"
  printf '%s\tweb\t5\t?\tfix\tclaude-opus-5-5\t-\tresumed\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 300))"
  printf '%s\tweb\t5\t0.50\tfix\tclaude-opus-5-5\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 200))"
  printf '%s\tweb\tanswer-5\t0.25\tanswer\tclaude-opus-5-5\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 100))"
  printf '%s\tweb\t6\t9.00\tbuild\tclaude-opus-5-5\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 50))"
  printf '%s\tother\t5\t7.00\tbuild\tclaude-opus-5-5\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 50))"
  printf '%s\tweb\t5\t3.00\tbuild\tclaude-opus-5-5\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW + 100))"; } > "$WORKERS_DIR/spend.log"
rep=$(PATH="$fb:$PATH" "$root/bin/canccu-status" --spend 2>&1)
ok "report: every run of the PR, lost ones and fix rounds too; other units, repos and later runs not" \
  grep -qF 'PR #50 (#5 Issue 5) · 2 fix rounds · $4.75 · 6 runs (1 lost, so at least)' <<<"$rep"
ok "… grouped by model and run type" grep -qE '^  claude-opus-5-5 +fix +2 runs +\$ +0\.50  1 lost$' <<<"$rep"
ok "… the review by its own model" grep -qE '^  claude-sonnet-5-5 +review +1 run +\$ +1\.00$' <<<"$rep"
ok "… a line from before the new columns as model and type -" grep -qE '^  \(default\) +- +1 run +\$ +1\.00$' <<<"$rep"
ok "… and the total over all merged PRs" grep -qF 'all 1 merged PR · $4.75 · 6 runs (1 lost, so at least)' <<<"$rep"
rm "$CANCCU_HOME/merged.log"
ok "report: nothing merged yet → said" grep -q 'no merged PR yet' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" --spend 2>&1)"

echo "canccu-spend tests: $npass passed, $nfail failed"
(( nfail == 0 ))
