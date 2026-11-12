#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Follow-up runs (#71): fresh sessions with a handoff unless RESUME_ON names the kind, the scripted
# merge of main, the red-CI flow, the fix-attempt cap and the fix run's model and effort.
. "$(dirname "$0")/lib/harness.sh"

wline() { grep -E "^--quiet --name #5 (--[a-z]+ [^ ]+ |--fresh )*web 5 " "$FAKE/worker.log" | tail -1; }
wt5() { mkdir -p "$WORKERS_DIR/worktrees/web/issue-5" && touch "$WORKERS_DIR/worktrees/web/issue-5/.git"; }

# ---------------------------------------------------------------- fresh or resume

review_env fresh-fix 'Review verdict: changes' review
wt5; printf 'abc1234 feat: the thing\n' > "$FAKE/gitlog"
last 5 done $'status: done\nPR URL: https://github.com/example-org/web/pull/50'
dispatch --once
l=$(wline)
ok "a review fix round starts a fresh session" grep -q -- ' --fresh ' <<<"$l"
ok "… its task first, after the safety block" grep -q 'web 5 Rules for this run: .* next action\. The independent reviewer asked for changes on PR #50 ' <<<"$l"
ok "… the handoff: the PR's link" grep -qF 'https://github.com/example-org/web/pull/50' <<<"$l"
ok "… the branch's commits" grep -qF 'abc1234 feat: the thing' <<<"$l"
ok "… the last report" grep -qF 'status: done PR URL:' <<<"$l"
ok "… the safety block first (#88)" grep -qF -- "web 5 $(lib eval 'echo "$SAFETY_BLOCK"') The independent reviewer asked" <<<"$l"
ok "… short findings inline, with their file" grep -qF "$HA (also in $CANCCU_HOME/reviews/50/$HA.findings.md)" <<<"$l"
ok "… the unit, its branch and where the rules are" grep -qF "This run is on issue #5, branch " <<<"$l"
ok "… not the first prompt again" not grep -q 'propose a tier' <<<"$l"
ok "… a fresh run is said in the log" grep -q '#5 resumed (fresh session, fix)' "$CANCCU_HOME/dispatch.log"
ok "… and counts as a fix attempt" eq "$(st 5 fixes) $(st 5 fixes_pr)" "1 50"

review_env resume-fix 'Review verdict: changes' review RESUME_ON=answer,plan,fix
dispatch --once
ok "RESUME_ON names fix → the session resumes" not grep -q -- ' --fresh ' <<<"$(wline)"
ok "… with the plain message, no handoff" not grep -q 'This run is a fresh session' <<<"$(wline)"
ok "… no safety block: the session has its rules (#88)" grep -q 'web 5 The independent reviewer asked for changes on PR #50 .*The blocking findings: 1. src/a.ts:3 off by one' <<<"$(wline)"

# #88: a fix round's long findings never push the rules out of the prompt
ok "the safety block is at most 600 characters" eq "$(lib eval '(( ${#SAFETY_BLOCK} <= 600 )) && echo short')" short
review_env fix-long 'Review verdict: changes' review
F=$(for i in $(seq 1 100); do printf '%d. src/a.ts:%d a finding long enough to fill the line; fix: %s\n' "$i" "$i" "$(printf 'x%.0s' $(seq 1 40))"; done)
p=$(pr 50 5 $HA); json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "$F
Review verdict: changes $HA")")"
wt5; dispatch --once
l=$(wline); t=${l#* web 5 }; t=${t% turns=*}; t=${t%…}
ff="$CANCCU_HOME/reviews/50/$HA.findings.md"
ok "a fix round with 10 kB of findings: the prompt starts with the safety block in full" grep -qF -- "web 5 $(lib eval 'echo "$SAFETY_BLOCK"') " <<<"$l"
ok "… at most 8000 characters after the issue number" eq "$(( ${#F} > 9000 && ${#t} <= 8000 ))" 1
ok "… it names the findings file" grep -qF "The findings are cut here; read all of them in $ff." <<<"$l"
ok "… which exists before the worker starts" eq "$(head -1 "$FAKE/worker.files") $(grep -c '^[0-9]*\. ' "$ff")" "$ff 100"

env_new plan-ok-resumes
{ issue 5 in-progress,plan-ok; } | issues
pr 50 5 $HA green "" true | prs
state 5 phase=needs-you pr=50 "ny_at=$NOW"
json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json
json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "plan-ok resumes by default" eq "$(grep -c 'approved the plan' "$FAKE/worker.log")/$(grep -c -- '--fresh' "$FAKE/worker.log")" 1/0

needsyou() {   # needsyou <name> <ny_kind> [config...]: issue 5 waits on needs-you; the user commented
  env_new "$1" "${@:3}"
  { issue 5 in-progress,needs-you; } | issues
  pr 50 5 $HA | prs
  state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" "ny_kind=$2"
  json issue5.json "$(jq -n --argjson c "$(comment 2030-11-05T11:59:00Z 'Use port 8080.')" '{comments: [$c]}')"
  route 'issue view 5 *' issue5.json
  json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
}
needsyou answer-resumes question
dispatch --once
ok "the user's answer to a question resumes" eq "$(grep -c 'The user answered: Use port 8080.' "$FAKE/worker.log")/$(grep -c -- '--fresh' "$FAKE/worker.log")" 1/0
needsyou comment-fresh ""
dispatch --once
ok "a comment on any other needs-you starts fresh" eq "$(grep -c 'The user answered: Use port 8080.' "$FAKE/worker.log")/$(grep -c -- '--fresh' "$FAKE/worker.log")" 1/1
needsyou resume-all "" RESUME_ON=all
dispatch --once
ok "RESUME_ON=all: every follow-up resumes" eq "$(grep -c -- '--fresh' "$FAKE/worker.log")" 0

env_new needs-work-fresh
{ issue 5 in-progress,needs-work; } | issues
pr 50 5 $HA | prs
state 5 phase=accept pr=50 "accept_at=$NOW"
json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json
json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "needs-work starts a fresh session" grep -q -- '--fresh .*The user rejected PR #50' "$FAKE/worker.log"
ok "… not a fix attempt (the user asked for it)" eq "$(st 5 fixes)" ""

# ---------------------------------------------------------------- the fix run's model and effort

review_env fix-model 'Review verdict: changes' review FIX_MODEL=claude-sonnet-5-5 FIX_EFFORT=medium MODEL=claude-opus-5-5
dispatch --once
ok "a fix run gets FIX_MODEL and FIX_EFFORT" eq "$(grep -cE -- '^--quiet --model claude-sonnet-5-5 --name #5 --fresh web 5 Rules for this run: .* The independent reviewer' "$FAKE/worker.log") $(grep -c '^WORKER_EFFORT=medium$' "$FAKE/worker.envdump") $(grep -c '^WORKER_RUN_TYPE=fix$' "$FAKE/worker.envdump")" "1 1 1"
needsyou fix-model-other "" FIX_MODEL=claude-sonnet-5-5 FIX_EFFORT=medium MODEL=claude-opus-5-5
dispatch --once
ok "… any other follow-up the usual model and no effort" eq "$(grep -c -- '--model claude-opus-5-5' "$FAKE/worker.log")/$(grep -c '^WORKER_EFFORT=.' "$FAKE/worker.envdump")" 1/0
review_env fix-model-default 'Review verdict: changes' review
dispatch --once
ok "by default a fix run has no --model and no --effort (as before)" eq "$(grep -c -- '--model ' "$FAKE/worker.log")/$(grep -c '^WORKER_EFFORT=.' "$FAKE/worker.envdump")" 0/0

# ---------------------------------------------------------------- red CI

redenv() {   # redenv <name> [config...]: issue 5 is in check; PR 50 on branch 5-thing has red CI
  env_new "$@"
  { issue 5 in-progress; } | issues
  pr 50 5 $HA red | jq '.statusCheckRollup[0].detailsUrl = "https://github.com/example-org/web/actions/runs/700/job/77"' | prs
  state 5 phase=check pr=50 "check_at=$NOW"
  wt5; echo 5-thing > "$FAKE/branch"
  printf 'test\tRun tests\t2030-11-05T10:00:00Z FAIL tests/a.sh: expected 2, got 3\n' > "$FAKE/joblog"
  route 'run view --job 77 *' joblog
}
redenv red-behind
echo 3 > "$FAKE/behind"
dispatch --once
ok "red CI, main ahead → main merged into the branch, by script" has git.log "merge --no-edit origin/main"
ok "… pushed normally to the PR's branch" has git.log "push origin HEAD:refs/heads/5-thing"
ok "… never a rebase or a force-push" eq "$(grep -cE 'rebase|--force|push -f' "$FAKE/git.log")" 0
ok "… no AI run" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… CI runs again: it stays in check" eq "$(st 5 phase) $(st 5 main_merged)" "check $FAKE_MERGED"
ok "… not a fix attempt" eq "$(st 5 fixes)" ""
dispatch --once
ok "the old head still listed (GitHub lags) → it waits, nothing starts" eq "$(wc -l < "$FAKE/worker.log") $(grep -c 'merge --no-edit' "$FAKE/git.log")" "0 1"

redenv red-current
echo 0 > "$FAKE/behind"
dispatch --once
l=$(wline)
ok "red CI with main already in → a fresh fix session" grep -q -- '--fresh .*web 5 Rules for this run: .* CI is red on PR #50' <<<"$l"
ok "… with the failing job's log tail" grep -qF 'FAIL tests/a.sh: expected 2, got 3' <<<"$l"
ok "… read from the failing job" has gh.log "run view --job 77 -R example-org/web --log-failed"
ok "… no merge" hasnt git.log "merge --no-edit"
ok "… a fix attempt" eq "$(st 5 fixes) $(st 5 fixes_pr)" "1 50"

redenv red-conflict
echo 2 > "$FAKE/behind"; printf 'src/a.ts\nsrc/b.ts\n' > "$FAKE/merge-conflict"
dispatch --once
ok "a merge of main that conflicts is aborted" has git.log "merge --abort"
ok "… nothing pushed" hasnt git.log "push"
ok "… a fresh session resolves it, told the files" grep -q -- '--fresh .*web 5 Rules for this run: .* Merging origin/main into the branch of PR #50 conflicts in: src/a.ts src/b.ts' <<<"$(wline)"
ok "… not a fix attempt" eq "$(st 5 fixes)" ""

redenv red-no-worktree
rm -rf "$WORKERS_DIR/worktrees"; echo 3 > "$FAKE/behind"
dispatch --once
ok "no worktree to merge in → no merge" not grep -qs 'merge --no-edit' "$FAKE/git.log"
ok "… straight to the fix session" eq "$(grep -c 'CI is red on PR #50' "$FAKE/worker.log")" 1

redenv red-other-branch
echo other-branch > "$FAKE/branch"; echo 3 > "$FAKE/behind"
dispatch --once
ok "the worktree on another branch → no merge there" hasnt git.log "merge --no-edit"

redenv red-dirty
printf ' M src/a.ts\n' > "$FAKE/dirty"; echo 3 > "$FAKE/behind"
dispatch --once
l=$(wline)
ok "uncommitted changes in the worktree → no merge by script" hasnt git.log "merge --no-edit"
ok "… the fix run is not told main is in; it merges main first" grep -q 'CI is red on PR #50; main was not merged in by script (uncommitted changes in the worktree)\. First run git merge origin/main' <<<"$l"
ok "… untracked files alone do not stop the merge (status -uno)" has git.log "status --porcelain --untracked-files=no"

redenv red-push-fail
echo 3 > "$FAKE/behind"; touch "$FAKE/push-fail"
dispatch --once
ok "a rejected push of the merge → no run, again next pass" eq "$(wc -l < "$FAKE/worker.log") $(st 5 mm_err)" "0 1"
dispatch --once; dispatch --once
ok "… the third failure in a row → needs-you with git's error" has gh.log "merging main into it by script failed 3 times"
ok "… naming the error" has gh.log "rejected by a pre-receive hook"
ok "… still no run" eq "$(wc -l < "$FAKE/worker.log")" 0

redenv red-conflict-again
echo 2 > "$FAKE/behind"; printf 'src/a.ts\n' > "$FAKE/merge-conflict"
dispatch --once
c=$(st 5 conflict_sha); ok "… the conflict run is noted for the head" eq "$c" "$HA"
rm -f "$WORKERS_DIR/web-5.lock"; last 5 done "gave up"; state 5 phase=check pr=50 "check_at=$NOW" "conflict_sha=$c"
dispatch --once
ok "a conflict run that left the head as it was → needs-you, not a second run" \
  eq "$(grep -c 'Merging origin/main into the branch of PR #50 conflicts' "$FAKE/worker.log")" 1
ok "… naming the conflict" has gh.log "merging origin/main into it conflicts in: src/a.ts"

redenv red-backoff
echo 0 > "$FAKE/behind"; echo "$((NOW + 3600))" > "$CANCCU_ROOT/backoff"
dispatch --once
ok "backing off: no fix run" eq "$(wc -l < "$FAKE/worker.log")" 0

# #94: while backing off, a review's changes and a merged contract PR start no run and change
# no state; after the back-off they run once
review_env fix-backoff 'Review verdict: changes' review
echo "$((NOW + 3600))" > "$CANCCU_ROOT/backoff"
dispatch --once
ok "a changes verdict while backing off → no engine call, no 'could not start', no fix counted" \
  eq "$(wc -l < "$FAKE/worker.log") $(grep -c 'could not start' "$CANCCU_HOME/dispatch.log") [$(st 5 fixes)] [$(st 5 verdict_at)]" "0 0 [] []"
rm -f "$CANCCU_ROOT/backoff"
dispatch --once
ok "… after the back-off the fix run starts once" \
  eq "$(grep -c 'The independent reviewer asked for changes on PR #50' "$FAKE/worker.log") $(st 5 fixes)" "1 1"
env_new contract-backoff
{ issue 5 in-progress; } | issues
pr 50 5 "$HA" green "" true | prs
state 5 phase=check pr=50 contract_merged=51 "check_at=$NOW"
echo "$((NOW + 3600))" > "$CANCCU_ROOT/backoff"
dispatch --once
ok "a merged contract PR while backing off → no engine call, no 'could not start', still to do" \
  eq "$(wc -l < "$FAKE/worker.log") $(grep -c 'could not start' "$CANCCU_HOME/dispatch.log") $(st 5 contract_merged)" "0 0 51"
rm -f "$CANCCU_ROOT/backoff"
dispatch --once
ok "… after the back-off its resume starts once" \
  eq "$(grep -c 'The contract PR #51 merged into main' "$FAKE/worker.log") [$(st 5 contract_merged)]" "1 []"

# ---------------------------------------------------------------- the cap

redenv cap-ci
echo 0 > "$FAKE/behind"
state 5 phase=check pr=50 "check_at=$NOW" fixes=1 fixes_pr=50
dispatch --once
ok "one fix attempt used (the review's): a CI fix run is the second" eq "$(grep -c 'CI is red on PR #50' "$FAKE/worker.log") $(st 5 fixes)" "1 2"
rm -f "$WORKERS_DIR/web-5.lock"; last 5 done "done"; dispatch --once
ok "red again after FIX_ATTEMPTS (2) fix runs → needs-you" has gh.log "CI is red on PR #50 after 2 automatic fix runs"
ok "… no third run" eq "$(grep -c 'CI is red on PR #50' "$FAKE/worker.log")" 1

review_env cap-review 'Review verdict: changes' review
state 5 phase=review pr=50 review_sha=$HA stage=review fixes=2 fixes_pr=50
dispatch --once
ok "the cap holds for a review fix round too" eq "$(grep -c 'asked for changes' "$FAKE/worker.log")" 0
ok "… needs-you instead" has gh.log "no automatic fix run is left"

review_env cap-other-pr 'Review verdict: changes' review
state 5 phase=review pr=50 review_sha=$HA stage=review fixes=2 fixes_pr=49
dispatch --once
ok "the count is per PR: another PR's fix runs don't count" eq "$(grep -c 'asked for changes' "$FAKE/worker.log") $(st 5 fixes) $(st 5 fixes_pr)" "1 1 50"

redenv cap-zero FIX_ATTEMPTS=0
echo 0 > "$FAKE/behind"
dispatch --once
ok "FIX_ATTEMPTS=0: red CI → needs-you as before" eq "$(wc -l < "$FAKE/worker.log")/$(grep -c 'CI is red on PR #50' "$FAKE/gh.log")" 0/1

review_env bad-values 'Review verdict: changes' review FIX_ATTEMPTS=two FIX_EFFORT=hgih
dispatch --once
ok "a FIX_ATTEMPTS that is no number counts as 2: the fix round runs" eq "$(grep -c 'asked for changes' "$FAKE/worker.log")" 1
ok "… a bad FIX_EFFORT is left out (the engine would refuse it on every pass), and said" \
  eq "$(grep -c '^WORKER_EFFORT=.' "$FAKE/worker.envdump") $(grep -q 'FIX_EFFORT is not an effort level' "$CANCCU_HOME/dispatch.log" && echo said)" "0 said"

# ---------------------------------------------------------------- the finish run (#26)

# a run whose turn ended while work ran in the background (or before its push): one fresh finish run
env_new finish-bg
{ issue 5 in-progress; } | issues
wt5; printf 'abc1234 test: the failing test\n' > "$FAKE/gitlog"
state 5 phase=work "started=$NOW"; last 5 'error: ended with background work pending' 'The suite runs in the background.'
dispatch --once; dispatch --once
ok "background pending: said in the log, never as done" grep -q '#5 worker ended with background work pending' "$CANCCU_HOME/dispatch.log"
l=$(wline)
ok "… no PR but commits: one fresh finish run" grep -q -- ' --fresh .*web 5 Rules for this run: .* Finish: your earlier run ended with work in this worktree and no PR' <<<"$l"
ok "… with the handoff, not the whole task again" eq "$(grep -c 'This run is a fresh session' <<<"$l") $(grep -c 'abc1234 test: the failing test' <<<"$l")" "1 1"
ok "… no needs-you yet" hasnt gh.log "needs-you"
ok "… and it is had once" eq "$(st 5 finish_tried)" 1
# the finish run ended with no PR again: needs-you now
last 5 done 'still no PR'; touch -d "@$((NOW + 120))" "$WORKERS_DIR/web-5.last"
rm -f "$WORKERS_DIR/web-5.lock"; lib st_set 5 phase=work "started=$((NOW + 60))"
dispatch --once; dispatch --once
ok "… a second run without a PR → needs-you" has gh.log "the worker finished without an open PR"
ok "… no second finish run" eq "$(grep -c 'web 5 Rules for this run: .* Finish:' "$FAKE/worker.log")" 1

# uncommitted work only counts too
env_new finish-dirty
{ issue 5 in-progress; } | issues
wt5; printf ' M src/a.ts\n' > "$FAKE/dirty"
state 5 phase=work "started=$NOW"; last 5 done 'all done, I think'
dispatch --once; dispatch --once
ok "uncommitted work, no PR: the finish run" grep -q 'web 5 Rules for this run: .* Finish:' "$FAKE/worker.log"

# nothing in the worktree: needs-you at once, as before
env_new finish-nothing
{ issue 5 in-progress; } | issues
wt5
state 5 phase=work "started=$NOW"; last 5 done 'nothing to do here'
dispatch --once; dispatch --once
ok "no work in the worktree, no PR: needs-you, no finish run" eq "$(grep -c 'Finish:' "$FAKE/worker.log" 2>/dev/null) $(grep -c 'finished without an open PR' "$FAKE/gh.log")" "0 1"

# background pending, but the PR is open: judged like any done run
env_new finish-pr
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA green); printf '%s\n' "$p" | prs
state 5 phase=work "started=$NOW"; last 5 'error: ended with background work pending' 'PR URL: https://github.com/example-org/web/pull/50'
dispatch --once
ok "background pending with an open PR: no needs-you, no finish run" eq "$(grep -c needs-you "$FAKE/gh.log") $(grep -c 'Finish:' "$FAKE/worker.log" 2>/dev/null)" "0 0"
ok "… its run kind" eq "$(lib run_exit "$WORKERS_DIR/web-5.last" | cut -d'|' -f1)" background

# ---------------------------------------------------------------- the limited run's task (#111)

# kind limited reads no last report: under set -u the unset report stopped the output before the
# standing orders, and the run after the reset got a task cut short
env_new handoff-limited
{ issue 5 in-progress; } | issues
json issue5.json '{"title": "Issue 5", "comments": []}'; route 'issue view 5 *' issue5.json
wt5; printf 'abc1234 feat: the thing\n' > "$FAKE/gitlog"
h=$( ( PATH="$fb:$PATH"; CANCCU_WORKER="$fb/worker"; . "$root/lib/canccu-common.sh"; set -u; handoff 5 limited ) 2>"$E/err")
ok "handoff K limited under set -u: it runs to its last line" grep -qF "This run is on issue #5, branch" <<<"$h"
ok "… nothing on stderr" eq "$(cat "$E/err")" ""

# ---------------------------------------------------------------- a rerun of the failed jobs (#21)

# rrenv <name> [config...]: red CI on HA with main in; its failed check is job 77 of run 700
rrenv() {
  redenv "$@"; echo 0 > "$FAKE/behind"
  json ok.json '{}'; route 'run rerun *' ok.json
}
# redat <sha> <completedAt> [detailsUrl]: PR 50 is red on that head, its failed check completed then
redat() {
  pr 50 5 "$1" red | jq --arg t "$2" --arg u "${3:-https://github.com/example-org/web/actions/runs/700/job/77}" \
    '.statusCheckRollup[0].detailsUrl = $u | .statusCheckRollup[0].completedAt = $t' | prs
}
rrenv rerun-once
dispatch --once
ok "red CI with main in → the failed jobs rerun once" eq "$(grep -c '^run rerun 700 --failed -R example-org/web' "$FAKE/gh.log")" 1
ok "… no fix run" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… logged with the failed check" grep -qF "#5 PR #50: CI red on ${HA:0:7} (test); failed jobs rerun once before any fix run" "$CANCCU_HOME/dispatch.log"
ok "… noted for the head" eq "$(st 5 ci_rerun)" "$HA"
dispatch --once
ok "… GitHub still lists the old result → wait, no second rerun, no fix run" eq "$(grep -c '^run rerun' "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "1 0"
redat "$HA" 2030-11-05T12:30:00Z
dispatch --once
ok "red again on the same head after the rerun → the fix run" eq "$(grep -c '^run rerun' "$FAKE/gh.log") $(grep -c 'CI is red on PR #50' "$FAKE/worker.log")" "1 1"

rrenv rerun-new-head
state 5 phase=check pr=50 "check_at=$NOW" ci_rerun=$HB
dispatch --once
ok "a red head other than the one rerun → a new rerun" eq "$(grep -c '^run rerun 700 --failed' "$FAKE/gh.log") $(st 5 ci_rerun)" "1 $HA"

rrenv rerun-no-actions
redat "$HA" 2030-11-05T10:00:00Z https://ci.example.com/build/9
dispatch --once
ok "a failed check that is no Actions run → no rerun, the fix run" eq "$(grep -c '^run rerun' "$FAKE/gh.log") $(grep -c 'CI is red on PR #50' "$FAKE/worker.log")" "0 1"

rrenv rerun-fails; : > "$FAKE/routes"; route 'run view --job 77 *' joblog
dispatch --once
ok "a rerun call that fails → logged, the fix run in the same pass" eq "$(grep -c 'rerun of run 700 failed' "$CANCCU_HOME/dispatch.log") $(grep -c 'CI is red on PR #50' "$FAKE/worker.log")" "1 1"

rrenv rerun-cap
state 5 phase=check pr=50 "check_at=$NOW" fixes=2 fixes_pr=50 ci_rerun=$HA
dispatch --once
ok "the needs-you after FIX_ATTEMPTS names the failed check" has gh.log "CI is red on PR #50 after 2 automatic fix runs (FIX_ATTEMPTS); failed: test"

ok "ci_names: at most 5 names, then …" eq "$(lib eval 'PRS=$(jq -n "[{number: 50, statusCheckRollup: [range(7) | {name: \"c\(.)\", conclusion: \"FAILURE\"}]}]"); ci_names 50')" "c0, c1, c2, c3, c4, …"

rrenv rerun-green
state 5 phase=check pr=50 "check_at=$NOW" ci_rerun=$HA "started=$((NOW - 600))"
pr 50 5 $HA green | prs
printf '%s\tweb\t5\t2.00\tbuild\t-\t-\tfresh\t-\t-\t-\t-\t-\t-\t-\n' "$((NOW - 10))" > "$WORKERS_DIR/spend.log"
dispatch --once
ok "the rerun head turned green → rerun-green on the worker's spend line" eq "$(cut -f15 "$WORKERS_DIR/spend.log")" "ci=rerun-green"

echo "canccu-followup tests: $npass passed, $nfail failed"
(( nfail == 0 ))
