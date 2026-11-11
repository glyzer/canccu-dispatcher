#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-merge.sh — offline tests for the merge method (the repo's allowed one, none with a
# merge queue), a merge found already done, and the plan-only PR ("Plan for #n"): found, reviewed,
# merged, then its issue back in the queue with plan_ok (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# repo_settings <queue true|false> <squash> <merge> <rebase>: the repo's merge settings (GraphQL)
repo_settings() {
  jq -n --argjson q "$1" --argjson s "$2" --argjson m "$3" --argjson r "$4" \
    '{data: {repository: {mergeQueue: (if $q then {id: "MQ_1"} else null end),
      squashMergeAllowed: $s, mergeCommitAllowed: $m, rebaseMergeAllowed: $r}}}' > "$FAKE/settings.json"
  route 'api graphql *mergeQueue {*' settings.json
}

# ---------------------------------------------------------------- the merge method

review_env method-squash-only 'Review verdict: pass' review
repo_settings false true false false
dispatch --once
ok "squash-only repo, no queue → --auto --squash pinned to the head" has gh.log "pr merge 50 -R example-org/web --auto --squash --match-head-commit $HA"
review_env method-queue 'Review verdict: pass' review
repo_settings true true false false
dispatch --once
ok "merge-queue repo → no method (the queue sets it)" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
review_env method-all 'Review verdict: pass' review
repo_settings false true true true
dispatch --once
ok "a repo that allows everything → squash" has gh.log "pr merge 50 -R example-org/web --auto --squash --match-head-commit $HA"
ok "… the settings are read once in the pass" eq "$(grep -c 'mergeQueue {' "$FAKE/gh.log")" 1
review_env method-merge-only 'Review verdict: pass' review
repo_settings false false true true
dispatch --once
ok "no squash → a merge commit" has gh.log "pr merge 50 -R example-org/web --auto --merge --match-head-commit $HA"
review_env method-direct 'Review verdict: pass' review
json repo.json '{"allow_auto_merge": false}'
repo_settings false false false true
dispatch --once
ok "a direct merge takes the method too" has gh.log "pr merge 50 -R example-org/web --rebase --match-head-commit $HA"
review_env method-error 'Review verdict: pass' review
repo_settings false true false false
echo 'GraphQL: Merge method merge commits are not allowed on this repository (mergePullRequest)' > "$FAKE/merge-error"
dispatch --once
ok "a failed merge: needs-you carries gh's own error" has gh.log "Merge method merge commits are not allowed on this repository"

# ---------------------------------------------------------------- auto-merge gone: merged already?

merging_off() {   # merging_off <name> <PR view json>: auto-merge off, not queued, 10 min after it was armed
  env_new "$1"
  { issue 5 in-progress; } | issues
  pr 50 5 $HA green | prs
  state 5 phase=merging pr=50 merge_sha=$HA how=auto "merge_at=$((NOW - 600))"
  json mq.json '{"data": {"repository": {"pullRequest": {"mergeQueueEntry": null}}}}'
  route 'api graphql *mergeQueueEntry*' mq.json
  json pr50.json "$2"; route 'pr view 50 *' pr50.json
}
merging_off merged-already '{"state": "MERGED", "body": "Closes #5", "closingIssuesReferences": [{"number": 5}]}'
dispatch --once
ok "auto-merge off on a PR already merged → no needs-you" hasnt gh.log "needs-you"
ok "… recorded as merged" eq "$(st 5 phase) $(st 5 merge_mode)" "merging merged"
merging_off rejected '{"state": "OPEN", "body": "Closes #5", "closingIssuesReferences": [{"number": 5}]}'
dispatch --once
ok "auto-merge off on an open PR → needs-you, as before" has gh.log "auto-merge was disabled or the merge queue rejected PR #50"

# ---------------------------------------------------------------- a merge group with no runs (#23)

# GitHub sometimes never starts the merge_group runs of a queue entry: it sits in AWAITING_CHECKS
# until the queue's timeout. A dequeue plus enqueue starts them.
# queued <name> <entry state> <enqueued at> <merge_group run count>: PR 50 armed 20 min ago, queued
queued() {
  env_new "$1"
  { issue 5 in-progress; } | issues
  pr 50 5 $HA green | prs
  state 5 phase=merging pr=50 merge_sha=$HA how=auto "merge_at=$((NOW - 1200))"
  jq -n --arg s "$2" --arg t "$3" '{data: {repository: {pullRequest: {id: "PR_50",
    mergeQueueEntry: {state: $s, enqueuedAt: $t, headCommit: {oid: "mq50"}}}}}}' > "$FAKE/mqe.json"
  route 'api graphql *enqueuedAt*' mqe.json
  json ok.json '{"data": {}}'; route 'api graphql *queuePullRequest*' ok.json
  json mq.json '{"data": {"repository": {"pullRequest": {"mergeQueueEntry": {"state": "QUEUED"}}}}}'
  route 'api graphql *mergeQueueEntry*' mq.json
  jq -n --argjson c "$4" '{total_count: $c}' > "$FAKE/mgruns.json"
  route 'api repos/example-org/web/actions/runs?event=merge_group&head_sha=mq50*' mgruns.json
}
old_t=$(date -u -d "@$((NOW - 900))" +%FT%TZ) new_t=$(date -u -d "@$((NOW - 120))" +%FT%TZ)
queued queue-stuck AWAITING_CHECKS "$old_t" 0
dispatch --once
ok "queue: an entry with no merge_group run after NO_CHECKS_MIN → dequeued" grep -q '^api graphql .*dequeuePullRequest' "$FAKE/gh.log"
ok "… and enqueued again" grep -q '^api graphql .*enqueuePullRequest' "$FAKE/gh.log"
ok "… reported" grep -q '#5 PR #50: the merge queue started no merge_group run in 10 min; dequeued and enqueued again' "$CANCCU_HOME/dispatch.log"
ok "… no needs-you" hasnt gh.log "needs-you"
: > "$FAKE/gh.log"; dispatch --once
ok "… once per head" not grep -q 'dequeuePullRequest' "$FAKE/gh.log"
queued queue-young AWAITING_CHECKS "$new_t" 0
dispatch --once
ok "queue: a young entry is left alone" not grep -q 'dequeuePullRequest' "$FAKE/gh.log"
queued queue-running AWAITING_CHECKS "$old_t" 2
dispatch --once
ok "queue: an entry whose runs started is left alone" not grep -q 'dequeuePullRequest' "$FAKE/gh.log"
queued queue-mergeable MERGEABLE "$old_t" 0
dispatch --once
ok "queue: an entry not waiting for checks is left alone" not grep -q 'dequeuePullRequest' "$FAKE/gh.log"
queued queue-enqueue-fails AWAITING_CHECKS "$old_t" 0
sed -i '1i api graphql *enqueuePullRequest(*\tFAIL' "$FAKE/routes"
dispatch --once
ok "queue: the enqueue fails → needs-you, the PR is out of the queue" has gh.log "was dequeued to restart its merge group, but could not be enqueued again"

# ---------------------------------------------------------------- the plan-only PR

PLAN_BODY=$'Plan for #5\n\nTier: plan\nRisk: low — a plan'
plan_pr() { pr 50 5 "$1" "${2:-green}" "" false "$PLAN_BODY" | jq '.closingIssuesReferences = []'; }

env_new plan-found
{ issue 5 in-progress; } | issues
p=$(plan_pr $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=work "started=$NOW" plan_ok=1; last 5 done 'Status: plan PR ready.'
dispatch --once
ok "a plan PR (Plan for #5, closes nothing) is found: no needs-you" hasnt gh.log "needs-you"
ok "… and reviewed" eq "$(st 5 phase) $(st 5 pr)" "review 50"
env_new plan-by-branch
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA green "" false "A plan." | jq '.closingIssuesReferences = []'); printf '%s\n' "$p" | prs
ok "a PR on branch 5-… that names no issue is still #5's" eq "$(lib eval 'fetch; pr_for 5')" 50

env_new plan-classify
{ issue 5 in-progress; } | issues
p=$(plan_pr $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "docs/plans/issue-5.md"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
state 5 phase=check pr=50
ok "a plan PR before plan-ok → manual: plan tier (not 'closes no issue')" eq "$(lib eval 'fetch; classify 50')" "manual: plan tier"
state 5 phase=check pr=50 plan_ok=1
ok "… after plan-ok the build must close the issue: Plan for #5 alone → manual" eq "$(lib eval 'fetch; classify 50')" "manual: PR #50 closes no issue after plan-ok (the build must close #5)"
p2=$(pr 50 5 $HA green "" false $'Closes #5\n\nTier: feature'); printf '%s\n' "$p2" | prs
json pr50.json "$(detail "$p2" 2030-11-05T10:00:00Z)"
ok "… a build that closes it merges like any other" eq "$(lib eval 'fetch; classify 50')" auto
printf '%s\n' "$p" | prs; json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 50 > "$E/out" 2>&1
ok "canccu-review accepts a plan PR" grep -q -- '--key review-50 ' "$FAKE/worker.log"

env_new plan-merged
{ issue 5 in-progress,awaiting-accept; } | issues
state 5 phase=merging pr=50 merge_sha=$HA how=accepted "merge_at=$((NOW - 600))"
json pr50.json "$(jq -n --arg b "$PLAN_BODY" '{state: "MERGED", body: $b, closingIssuesReferences: [], headRefName: "5-thing"}')"; route 'pr view 50 *' pr50.json
echo sid > "$WORKERS_DIR/web-5.id"
dispatch --once
ok "the plan PR merged, the issue still open → no needs-you" hasnt gh.log "needs-you"
ok "… back to the queue: ready and plan-ok, in-progress and awaiting-accept off" \
  has gh.log "issue edit 5 -R example-org/web --add-label ready --add-label plan-ok --remove-label in-progress --remove-label awaiting-accept"
ok "… no longer managed, its session gone" eq "$(test -e "$CANCCU_HOME/state/5" && echo managed)$(test -e "$WORKERS_DIR/web-5.id" && echo sid)" ""
ok "… logged" grep -q '#5 PR #50: the plan merged; back to the queue with plan-ok' "$CANCCU_HOME/dispatch.log"
ok "… its head branch deleted on GitHub (the build reuses the name)" has gh.log "api -X DELETE repos/example-org/web/git/refs/heads/5-thing"
{ issue 5 ready,plan-ok; } | issues
: > "$FAKE/routes"; dispatch --once
ok "next pass: it starts again, told to execute the merged plan" grep -q '^--quiet --name #5 web 5 You are working on .*The plan docs/plans/issue-5.md is approved and merged' "$FAKE/worker.log"
ok "… plan_ok set, the plan-ok label taken with the start" eq "$(st 5 plan_ok) $(grep -c 'issue edit 5 .*--remove-label plan-ok' "$FAKE/gh.log")" "1 1"

merging_off plan-merged-off "$(jq -n --arg b "$PLAN_BODY" '{state: "MERGED", body: $b, closingIssuesReferences: []}')"
pr 50 5 $HA green "" false "$PLAN_BODY" | jq '.closingIssuesReferences = []' | jq -s . > "$FAKE/prs.json"
dispatch --once
ok "auto-merge off, the plan PR merged meanwhile → back to the queue, no needs-you" \
  eq "$(grep -c 'needs-you' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/state/5" && echo managed)" "0 "

env_new built-after-plan-ok
{ issue 5 in-progress; } | issues
state 5 phase=merging pr=50 merge_sha=$HA how=auto "merge_at=$((NOW - 600))" plan_ok=1
json pr50.json "$(jq -n --arg b "$PLAN_BODY" '{state: "MERGED", body: $b, closingIssuesReferences: [], headRefName: "5-thing"}')"; route 'pr view 50 *' pr50.json
dispatch --once
ok "a PR merged after plan-ok is the build, never a plan sent back to the queue: released with needs-you (#86)" \
  eq "$(test -e "$CANCCU_HOME/state/5" && echo managed) $(grep -c 'add-label plan-ok' "$FAKE/gh.log") $(grep -c '^issue edit 5 .*--add-label needs-you' "$FAKE/gh.log")" " 0 1"

# ---------------------------------------------------------------- a merged PR that leaves its issue open (#86)

# gone_env <name> <unit key> <PR view json> <state lines...>: the unit is in merging with PR 50,
# which merged; its worktree and session id are there
gone_env() {
  local k=$2 wt
  env_new "$1"
  json pr50.json "$3"; route 'pr view 50 *' pr50.json
  shift 3
  state "$k" phase=merging pr=50 merge_sha=$HA how=auto "merge_at=$((NOW - 600))" "$@"
  if [[ $k == pkg-* ]]; then wt=$WORKERS_DIR/worktrees/web/$k; else wt=$WORKERS_DIR/worktrees/web/issue-$k; fi
  mkdir -p "$wt"; : > "$wt/.git"; echo sid > "$WORKERS_DIR/web-$k.id"
}
NOCLOSE='{"state": "MERGED", "title": "Add a thing", "body": "Tier: fix", "closingIssuesReferences": [], "headRefName": "5-thing"}'
CLOSES5='{"state": "MERGED", "title": "Add a thing", "body": "Closes #5", "closingIssuesReferences": [{"number": 5}], "headRefName": "5-thing"}'
NY5='^issue comment 5 .*PR #50 merged but did not close this issue. The dispatcher no longer manages it. If the work is done, close the issue. If work is left, remove `needs-you` and add `ready`: a new worker starts from main.'

gone_env merged-left 5 "$NOCLOSE"
{ issue 5 in-progress; } | issues
dispatch --once
ok "a merged PR that closes nothing → needs-you on the issue, in-progress off" \
  has gh.log "issue edit 5 -R example-org/web --add-label needs-you --remove-label in-progress"
ok "… with the comment, once" eq "$(grep -c "$NY5" "$FAKE/gh.log")" 1
ok "… released: no state, no session id, its worktree removed" \
  eq "$(test -e "$CANCCU_HOME/state/5" && echo state)$(test -e "$WORKERS_DIR/web-5.id" && echo sid) $(grep -c "worktree remove --force $WORKERS_DIR/worktrees/web/issue-5$" "$FAKE/git.log")" " 1"
ok "… merged.log has the merge" grep -qE "^[0-9]+	5	50	auto	Add a thing$" "$CANCCU_HOME/merged.log"
ok "… logged" grep -qF '#5 PR #50 merged but left #5 open: needs-you, unit released' "$CANCCU_HOME/dispatch.log"
{ issue 5 ready; } | issues
: > "$FAKE/routes"; dispatch --once
ok "… with \`ready\` and without needs-you, the next pass starts it as a new unit" eq "$(started 5 && echo started) $(st 5 phase)" "started work"

gone_env merged-left-dry 5 "$NOCLOSE"
{ issue 5 in-progress; } | issues
dispatch --dry-run
ok "a dry run releases nothing" \
  eq "$(st 5 phase) $(grep -cE '^issue (edit|comment)' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/merged.log" && echo log)$(test -e "$WORKERS_DIR/web-5.id" && echo sid)" "merging 0 sid"

gone_env merged-closes 5 "$CLOSES5"
{ issue 5 in-progress; } | issues
dispatch --once
ok "a merged PR whose Closes names the still open issue → no needs-you on the first pass, gone_at set" \
  eq "$(grep -c needs-you "$FAKE/gh.log") $(st 5 gone_at) $(st 5 phase)" "0 $NOW merging"
dispatch --once
ok "… nor on the next pass within MERGE_WAIT_MIN" eq "$(grep -c needs-you "$FAKE/gh.log") $(st 5 gone_at)" "0 $NOW"
sed -i "s/^gone_at=.*/gone_at=$((NOW - 241 * 60))/" "$CANCCU_HOME/state/5"
dispatch --once
ok "… still open after MERGE_WAIT_MIN → released with needs-you" \
  eq "$(grep -c "$NY5" "$FAKE/gh.log") $(test -e "$CANCCU_HOME/state/5" && echo state)" "1 "

gone_env merged-pkg pkg-1-a '{"state": "MERGED", "title": "Package a", "body": "Closes #6", "closingIssuesReferences": [{"number": 6}], "headRefName": "pkg-1-a"}' \
  pkg=a "members=5 6" branch=pkg-1-a
{ issue 5 in-progress; } | issues
dispatch --once
ok "a package PR that closes one of two members → only the open one gets needs-you" \
  eq "$(grep -c '^issue edit 5 .*--add-label needs-you' "$FAKE/gh.log") $(grep -c '^issue edit 6 .*needs-you' "$FAKE/gh.log") $(grep -c "$NY5" "$FAKE/gh.log")" "1 0 1"
ok "… the closed one is advanced (what it blocked is looked at)" has gh.log "api repos/example-org/web/issues/6/dependencies/blocking"
ok "… the open one is not" hasnt gh.log "api repos/example-org/web/issues/5/dependencies/blocking"
ok "… the package is released" eq "$(test -e "$CANCCU_HOME/state/pkg-1-a" && echo state)" ""

env_new plan-ok-resume
{ issue 5 in-progress,plan-ok; } | issues
pr 50 5 $HA none "" true "$PLAN_BODY" | jq '.closingIssuesReferences = []' | jq -s . > "$FAKE/prs.json"
state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" ny_kind=plan
json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json; json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "the plan-ok resume tells the worker to close the issue in the same PR" grep -q 'web 5 The user approved the plan.*replace each `Plan for #<n>` line with `Closes #<n>`' "$FAKE/worker.log"

env_new fresh-plan-prompt
{ issue 5 in-progress; } | issues
state 5 phase=work plan_ok=1
ok "a fresh session of a build on a merged plan is told to execute it" grep -q 'The plan docs/plans/issue-5.md is approved and merged' <<<"$(lib eval 'fetch; unit_prompt 5')"

env_new method-cached
repo_settings false true false false
ok "the merge method is read once per pass, however many merges" eq "$(lib eval 'fetch; merge_flags 0; merge_flags 1; echo "${MF[*]}"') $(grep -c 'mergeQueue {' "$FAKE/gh.log")" "--squash 1"

echo "canccu-merge tests: $npass passed, $nfail failed"
(( nfail == 0 ))
