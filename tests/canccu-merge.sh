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
ok "a PR merged after plan-ok is the build, never a plan sent back to the queue" eq "$(test -e "$CANCCU_HOME/state/5" && echo managed) $(grep -c 'add-label plan-ok' "$FAKE/gh.log")" "managed 0"

env_new plan-ok-resume
{ issue 5 in-progress,plan-ok; } | issues
pr 50 5 $HA none "" true "$PLAN_BODY" | jq '.closingIssuesReferences = []' | jq -s . > "$FAKE/prs.json"
state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" ny_kind=plan
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
