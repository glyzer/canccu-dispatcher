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
ok "… its task first" grep -q 'web 5 The independent reviewer asked for changes on PR #50 ' <<<"$l"
ok "… the handoff: the PR's link" grep -qF 'https://github.com/example-org/web/pull/50' <<<"$l"
ok "… the branch's commits" grep -qF 'abc1234 feat: the thing' <<<"$l"
ok "… the last report" grep -qF 'status: done PR URL:' <<<"$l"
ok "… the standing orders of the first run" grep -q 'standing orders.*You are working on example-org/web issue #5 ' <<<"$l"
ok "… a fresh run is said in the log" grep -q '#5 resumed (fresh session, fix)' "$CANCCU_HOME/dispatch.log"
ok "… and counts as a fix attempt" eq "$(st 5 fixes) $(st 5 fixes_pr)" "1 50"

review_env resume-fix 'Review verdict: changes' review RESUME_ON=answer,plan,fix
dispatch --once
ok "RESUME_ON names fix → the session resumes" not grep -q -- ' --fresh ' <<<"$(wline)"
ok "… with the plain message, no handoff" not grep -q 'standing orders' <<<"$(wline)"

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
ok "a fix run gets FIX_MODEL and FIX_EFFORT" eq "$(grep -cE -- '^--quiet --model claude-sonnet-5-5 --name #5 --fresh web 5 The independent reviewer' "$FAKE/worker.log") $(grep -c '^WORKER_EFFORT=medium$' "$FAKE/worker.envdump") $(grep -c '^WORKER_RUN_TYPE=fix$' "$FAKE/worker.envdump")" "1 1 1"
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
ok "red CI with main already in → a fresh fix session" grep -q -- '--fresh .*web 5 CI is red on PR #50' <<<"$l"
ok "… with the failing job's log tail" grep -qF 'FAIL tests/a.sh: expected 2, got 3' <<<"$l"
ok "… read from the failing job" has gh.log "run view --job 77 -R example-org/web --log-failed"
ok "… no merge" hasnt git.log "merge --no-edit"
ok "… a fix attempt" eq "$(st 5 fixes) $(st 5 fixes_pr)" "1 50"

redenv red-conflict
echo 2 > "$FAKE/behind"; printf 'src/a.ts\nsrc/b.ts\n' > "$FAKE/merge-conflict"
dispatch --once
ok "a merge of main that conflicts is aborted" has git.log "merge --abort"
ok "… nothing pushed" hasnt git.log "push"
ok "… a fresh session resolves it, told the files" grep -q -- '--fresh .*web 5 Merging origin/main into the branch of PR #50 conflicts in: src/a.ts src/b.ts' <<<"$(wline)"
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

echo "canccu-followup tests: $npass passed, $nfail failed"
(( nfail == 0 ))
