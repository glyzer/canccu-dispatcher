#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-models.sh — the narrow runs' models: the user's follow-up on a needs-you from CI, a
# review or a fix-check runs on FIX_MODEL, a question's answer and the rest on MODEL; a line
# "opus" or "model: <id>" in the comment overrides it; a merge run on MERGE_MODEL, the answerer on
# ANSWER_MODEL (lib/canccu-actions.sh; the harness: tests/lib/harness.sh).
. "$(dirname "$0")/lib/harness.sh"

cfg=(FIX_MODEL=claude-sonnet-5-5 FIX_EFFORT=medium MODEL=claude-opus-5-5)
# lead <name> <ny_kind> <ny_stage> <comment> [config...]: issue 5 waits on needs-you, the user commented
lead() {
  env_new "$1" "${@:5}"
  { issue 5 in-progress,needs-you; } | issues
  pr 50 5 $HA | prs
  state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" "ny_kind=$2" "ny_stage=$3"
  json issue5.json "$(jq -n --argjson c "$(comment 2030-11-05T11:59:00Z "$4")" '{comments: [$c]}')"
  route 'issue view 5 *' issue5.json
  json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
}
model() { grep -oE -- '^--quiet --model [^ ]+' "$FAKE/worker.log" | awk '{ print $3 }' | tail -1; }
effort() { sed -n 's/^WORKER_EFFORT=//p' "$FAKE/worker.envdump" | tail -1; }
rtype() { sed -n 's/^WORKER_RUN_TYPE=//p' "$FAKE/worker.envdump" | tail -1; }

lead review "" review 'Keep the old name.' "${cfg[@]}"
dispatch --once
ok "the user's comment on a review's needs-you → FIX_MODEL and FIX_EFFORT, still a build in spend.log" \
  eq "$(model) $(effort) $(rtype)" "claude-sonnet-5-5 medium build"
for s in ci fix-check fix; do
  lead "stage-$s" "" "$s" 'Go on.' "${cfg[@]}"; dispatch --once
  ok "… on a needs-you from $s too" eq "$(model)" claude-sonnet-5-5
done
lead question question work 'Use port 8080.' "${cfg[@]}"
dispatch --once
ok "the answer to a question → MODEL, no effort" eq "$(model) [$(effort)]" "claude-opus-5-5 []"
lead plan plan work 'Split it.' "${cfg[@]}"
dispatch --once
ok "a plan's needs-you → MODEL" eq "$(model)" claude-opus-5-5
lead stopped "" work 'Try again.' "${cfg[@]}"
dispatch --once
ok "a stopped worker's needs-you → MODEL" eq "$(model)" claude-opus-5-5

lead opus "" review $'Keep the old name.\nopus' "${cfg[@]}"
dispatch --once
ok "a line \"opus\" in the comment → opus" eq "$(model)" opus
lead model-id question work $'Use port 8080.\nmodel: claude-haiku-5-5' "${cfg[@]}"
dispatch --once
ok "a line \"model: <id>\" → that model" eq "$(model)" claude-haiku-5-5
lead model-text "" review 'Do not use the opus model here.' "${cfg[@]}"
dispatch --once
ok "… a sentence that names a model is no model line" eq "$(model)" claude-sonnet-5-5
# a full review's changes with no review fix run left (owed), then needs-work with a model line
review_env owed-opus 'Review verdict: changes' review REVIEW_FIX_ATTEMPTS=0 "${cfg[@]}"
dispatch --once
{ issue 5 in-progress,needs-you,needs-work; } | issues
json issue5.json "$(comment 2030-11-05T12:10:00Z $'Keep the old name.\nopus' | jq -s '{labels: [{name: "in-progress"}, {name: "needs-you"}, {name: "needs-work"}], comments: .}')"
: > "$FAKE/worker.log"; CANCCU_NOW=$((NOW + 1200)) dispatch --once
ok "a needs-work comment's \"opus\" line on an owed review round → its fix run on opus" \
  eq "$(grep -c "review's fix round" "$FAKE/worker.log") $(model)" "1 opus"

# merge runs: MERGE_MODEL, else FIX_MODEL, else MODEL
mrun() { lead "$1" "" review x "${@:2}"; lib eval 'resume 5 "Merge main." merge' >/dev/null; }
mrun merge-model MERGE_MODEL=claude-haiku-5-5 "${cfg[@]}"
ok "a merge run → MERGE_MODEL, a merge in spend.log" eq "$(model) $(rtype)" "claude-haiku-5-5 merge"
mrun merge-fix "${cfg[@]}"
ok "… MERGE_MODEL empty → FIX_MODEL" eq "$(model)" claude-sonnet-5-5
mrun merge-plain MODEL=claude-opus-5-5
ok "… both empty → MODEL" eq "$(model)" claude-opus-5-5

# the answerer: ANSWER_MODEL, else MODEL
arun() {
  env_new "$@"
  { issue 5 in-progress; } | issues
  state 5 phase=question; mkdir -p "$CANCCU_HOME/questions"
  lib eval 'q_set 5 "Poll or subscribe?"; start_answer 5' >/dev/null
}
arun answer-model ANSWER_MODEL=claude-haiku-5-5 MODEL=claude-opus-5-5
ok "the answerer → ANSWER_MODEL" grep -qE -- '--model claude-haiku-5-5 .*--name answer#5 ' "$FAKE/worker.log"
arun answer-plain MODEL=claude-opus-5-5
ok "… ANSWER_MODEL empty → MODEL" grep -qE -- '--model claude-opus-5-5 .*--name answer#5 ' "$FAKE/worker.log"

# a draft whose contract PR merged (#331): main merged in by script; its last run's report says
# whether the package's own work is done. done → the PR marked ready, no run; otherwise a merge run
# cenv <name> <report> [config...]: issue 5 in check, draft PR 50, its contract PR 51 merged
cenv() {
  env_new "$1" "${@:3}"
  { issue 5 in-progress; } | issues
  pr 50 5 "$HA" green "" true | prs
  state 5 phase=check pr=50 contract_merged=51 "check_at=$NOW"
  mkdir -p "$WORKERS_DIR/worktrees/web/issue-5" && touch "$WORKERS_DIR/worktrees/web/issue-5/.git"
  echo 5-thing > "$FAKE/branch"; echo 2 > "$FAKE/behind"
  last 5 done "$2"
  json ok.json '{}'; route 'pr ready *' ok.json
}
cenv done $'Opened the contract PR #51.\nPackage work: done' MERGE_MODEL=claude-haiku-5-5 "${cfg[@]}"
dispatch --once
ok "contract merged, work done → main merged by script, the PR marked ready, no run" \
  eq "$(grep -c 'merge --no-edit origin/main' "$FAKE/git.log") $(grep -c '^pr ready 50 ' "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log") [$(st 5 contract_merged)]" "1 1 0 []"
ok "… logged" grep -q '#5 PR #50: contract PR #51 merged, main merged in, the package.s work done: marked ready' "$CANCCU_HOME/dispatch.log"
cenv unfinished $'Opened the contract PR #51.\nPackage work: unfinished' MERGE_MODEL=claude-haiku-5-5 "${cfg[@]}"
dispatch --once
ok "… work unfinished → a merge run on MERGE_MODEL to finish it, not marked ready" \
  eq "$(model) $(rtype) $(grep -c 'Finish the package.s work in PR #50' "$FAKE/worker.log") $(grep -c '^pr ready' "$FAKE/gh.log")" "claude-haiku-5-5 merge 1 0"
ok "… logged" grep -q '#5 PR #50: contract PR #51 merged, main merged in; the package.s work is unfinished: the worker finishes it' "$CANCCU_HOME/dispatch.log"
cenv noline 'Opened the contract PR #51.' MERGE_MODEL=claude-haiku-5-5 "${cfg[@]}"
dispatch --once
ok "… no Package work: line → unfinished: a merge run" eq "$(model) $(grep -c '^pr ready' "$FAKE/gh.log")" "claude-haiku-5-5 0"
cenv conflict $'Package work: done' MERGE_MODEL=claude-haiku-5-5 "${cfg[@]}"
echo src/a.ts > "$FAKE/merge-conflict"
dispatch --once
ok "… a conflict, though the work is done → a merge run on MERGE_MODEL that merges main" \
  eq "$(model) $(grep -c 'Run git merge origin/main in your branch' "$FAKE/worker.log") $(grep -c '^pr ready' "$FAKE/gh.log")" "claude-haiku-5-5 1 0"
ok "… logged" grep -q '#5 PR #50: contract PR #51 merged; main could not be merged in (conflict' "$CANCCU_HOME/dispatch.log"

echo "canccu-models tests: $npass passed, $nfail failed"
(( nfail == 0 ))
