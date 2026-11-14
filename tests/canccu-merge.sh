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

# ---------------------------------------------------------------- a gh error in classify (#94)

# a passed review whose classify cannot read the PR (the pass's second `pr view 50`) is retried
# next pass, never sent to the maintainer
review_env classify-retry 'Review verdict: pass' review
mkdir -p "$E/sbin"
cat > "$E/sbin/gh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = "pr view 50" ]; then
  n=\$(( \$(cat "$E/views" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$E/views"
  [ "\$n" = 2 ] && { echo "fake gh: failing" >&2; exit 1; }
fi
exec "$fb/gh" "\$@"
SH
chmod +x "$E/sbin/gh"
PATH="$E/sbin:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1
ok "a passed review, gh error reading the PR in classify → no accept asked, verdict_at not set" \
  eq "$(grep -c 'awaiting-accept' "$FAKE/gh.log") $(grep -c '^pr merge' "$FAKE/gh.log") [$(st 5 verdict_at)]" "0 0 []"
ok "… logged, to be tried again" grep -q '#5 PR #50: review pass · retry: gh error reading PR #50; again next pass' "$CANCCU_HOME/dispatch.log"
dispatch --once
ok "… the next pass, the read working, merges it automatically" has gh.log "pr merge 50 -R example-org/web --auto"

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
echo 'fail:issue close' >> "$FAKE/routes"
dispatch --once
ok "… still open after MERGE_WAIT_MIN, its close failing → released with needs-you" \
  eq "$(grep -c "$NY5" "$FAKE/gh.log") $(test -e "$CANCCU_HOME/state/5" && echo state)" "1 "

# #139: a named issue GitHub left open is closed by the dispatcher after MERGE_CLOSE_MIN
CLOSES56='{"state": "MERGED", "title": "Package a", "body": "Closes #5\nCloses #6", "closingIssuesReferences": [{"number": 5}, {"number": 6}], "headRefName": "pkg-1-a"}'
CL='Closed by canccu-dispatch: PR #50 merged and names this issue as closing, but GitHub left it open.'
gone_env merged-close-both pkg-1-a "$CLOSES56" pkg=a "members=5 6" branch=pkg-1-a "gone_at=$((NOW - 3 * 60))"
{ issue 5 in-progress; issue 6 in-progress; } | issues
dispatch --once
ok "both named members still open past MERGE_CLOSE_MIN → each closed with the comment" \
  eq "$(grep -c "^issue close 5 -R example-org/web --reason completed --comment $CL" "$FAKE/gh.log") $(grep -c "^issue close 6 -R example-org/web --reason completed --comment $CL" "$FAKE/gh.log")" "1 1"
ok "… no needs-you" eq "$(grep -c needs-you "$FAKE/gh.log")" 0
ok "… the close lines, then the merged line" eq "$(grep -oE '#pkg-1-a (PR #50 merged; closed #[56] \(GitHub left it open\)|merged \(PR #50, auto\))' "$CANCCU_HOME/dispatch.log" | tr '\n' '|')" \
  '#pkg-1-a PR #50 merged; closed #5 (GitHub left it open)|#pkg-1-a PR #50 merged; closed #6 (GitHub left it open)|#pkg-1-a merged (PR #50, auto)|'
ok "… released, both advanced, counted as merged" \
  eq "$(test -e "$CANCCU_HOME/state/pkg-1-a" && echo state) $(grep -c 'issues/[56]/dependencies/blocking' "$FAKE/gh.log")" " 2"
ok "… in-progress taken off the closed members" eq "$(grep -c '^issue edit [56] .*--remove-label in-progress' "$FAKE/gh.log")" 2

gone_env merged-close-early pkg-1-a "$CLOSES56" pkg=a "members=5 6" branch=pkg-1-a "gone_at=$((NOW - 60))"
{ issue 5 in-progress; issue 6 in-progress; } | issues
dispatch --once
ok "named members open within MERGE_CLOSE_MIN → nothing closed, the unit kept" \
  eq "$(grep -c '^issue close' "$FAKE/gh.log") $(st pkg-1-a phase)" "0 merging"

gone_env merged-close-fail pkg-1-a "$CLOSES56" pkg=a "members=5 6" branch=pkg-1-a "gone_at=$((NOW - 3 * 60))"
{ issue 5 in-progress; issue 6 in-progress; } | issues
echo 'fail:issue close' >> "$FAKE/routes"
dispatch --once
ok "gh issue close failing → logged to retry, the unit kept" \
  eq "$(grep -cF '#pkg-1-a: gh error closing issue #5; retrying next pass' "$CANCCU_HOME/dispatch.log") $(st pkg-1-a phase) $(grep -c needs-you "$FAKE/gh.log")" "1 merging 0"
: > "$FAKE/routes"; : > "$FAKE/gh.log"; route 'pr view 50 *' pr50.json
dispatch --once
ok "… the next pass, gh working, closes it and releases the unit" \
  eq "$(grep -c "^issue close 5 -R example-org/web --reason completed --comment $CL" "$FAKE/gh.log") $(test -e "$CANCCU_HOME/state/pkg-1-a" && echo state)" "1 "

gone_env merged-close-mixed pkg-1-a "$CLOSES5" pkg=a "members=5 6" branch=pkg-1-a "gone_at=$((NOW - 3 * 60))"
{ issue 5 in-progress; issue 6 in-progress; } | issues
dispatch --once
ok "one member named, one not → the named one closed, the other needs-you as before" \
  eq "$(grep -c '^issue close 5 ' "$FAKE/gh.log") $(grep -c '^issue close 6 ' "$FAKE/gh.log") $(grep -c '^issue edit 6 .*--add-label needs-you' "$FAKE/gh.log") $(grep -c '^issue edit 5 .*needs-you' "$FAKE/gh.log")" "1 0 1 0"
ok "… logged, the unit released" eq "$(grep -cF '#pkg-1-a PR #50 merged but left #6 open: needs-you, unit released' "$CANCCU_HOME/dispatch.log") $(test -e "$CANCCU_HOME/state/pkg-1-a" && echo state)" "1 "

gone_env merged-pkg pkg-1-a '{"state": "MERGED", "title": "Package a", "body": "Closes #6", "closingIssuesReferences": [{"number": 6}], "headRefName": "pkg-1-a"}' \
  pkg=a "members=5 6" branch=pkg-1-a
{ issue 5 in-progress; } | issues
json i6.json '{"state": "CLOSED"}'; route 'issue view 6 *' i6.json
dispatch --once
ok "a package PR that closes one of two members → only the open one gets needs-you" \
  eq "$(grep -c '^issue edit 5 .*--add-label needs-you' "$FAKE/gh.log") $(grep -c '^issue edit 6 .*needs-you' "$FAKE/gh.log") $(grep -c "$NY5" "$FAKE/gh.log")" "1 0 1"
ok "… the closed one is advanced (what it blocked is looked at)" has gh.log "api repos/example-org/web/issues/6/dependencies/blocking"
ok "… the open one is not" hasnt gh.log "api repos/example-org/web/issues/5/dependencies/blocking"
ok "… the package is released" eq "$(test -e "$CANCCU_HOME/state/pkg-1-a" && echo state)" ""

# the open list is capped: a member missing from it is confirmed with gh issue view
gone_env merged-pkg-cap pkg-1-a '{"state": "MERGED", "title": "Package a", "body": "Tier: fix", "closingIssuesReferences": [], "headRefName": "pkg-1-a"}' \
  pkg=a "members=5 6" branch=pkg-1-a
{ issue 5 in-progress; } | issues
json i6.json '{"state": "OPEN"}'; route 'issue view 6 *' i6.json
dispatch --once
ok "a package member missing from the issue list but OPEN on gh → needs-you on it too" \
  eq "$(grep -c '^issue edit 5 .*--add-label needs-you' "$FAKE/gh.log") $(grep -c '^issue edit 6 .*--add-label needs-you' "$FAKE/gh.log")" "1 1"
ok "… it is not advanced, nor are its epics closed" \
  eq "$(grep -c 'issues/6/dependencies/blocking' "$FAKE/gh.log") $(grep -c '^issue close' "$FAKE/gh.log")" "0 0"
ok "… logged with both" grep -qF '#pkg-1-a PR #50 merged but left #5, #6 open: needs-you, unit released' "$CANCCU_HOME/dispatch.log"

gone_env merged-pkg-cap-err pkg-1-a "$NOCLOSE" pkg=a "members=5 6" branch=pkg-1-a
{ issue 5 in-progress; } | issues
route 'issue view 6 *' FAIL
dispatch --once
ok "… a gh error reading it releases nothing: no needs-you, the state is kept" \
  eq "$(grep -c needs-you "$FAKE/gh.log") $(st pkg-1-a phase) $(test -e "$WORKERS_DIR/web-pkg-1-a.id" && echo sid)" "0 merging sid"
ok "… logged" grep -qF '#pkg-1-a: gh error reading issue #6; retrying next pass' "$CANCCU_HOME/dispatch.log"

# #87: a single issue's contract-first PR is known by its branch, as a package's is
gone_env contract-single 5 '{"state": "MERGED", "title": "The contract", "body": "Refs #5", "closingIssuesReferences": [], "headRefName": "5-issue-5-contract"}' \
  branch=5-issue-5
{ issue 5 in-progress; } | issues
dispatch --once
ok "a single issue's contract PR merged, closing nothing → contract_back: still managed, back in check, no needs-you" \
  eq "$(st 5 phase) $(st 5 contract_merged) $(grep -c needs-you "$FAKE/gh.log")" "check 50 0"

# #98: a contract PR that GitHub links as closing an issue never reaches a review or an accept
# cfix <name> <unit> <members> <branch> <closes> [comment]: the unit in check on its draft PR 50
# and its contract PR 51 (CI green), whose closingIssuesReferences is <closes>
cfix() {
  local k=$2 c p
  env_new "$1"
  if [ "${k#pkg-}" != "$k" ]; then
    { issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"; } | issues
    state "$k" pkg=auth step=12 "members=$3" "branch=$4" risk=normal phase=check pr=50 "check_at=$NOW"
  else
    { issue "$k" in-progress; } | issues
    state "$k" "branch=$4" phase=check pr=50 "check_at=$NOW"
  fi
  p=$(PR_BRANCH=$4 pr 50 0 "$HA" green "" true "" | jq --arg c "$3" '.closingIssuesReferences = ($c | split(" ") | map({number: tonumber}))')
  c=$(PR_BRANCH=$4-contract pr 51 0 "$HB" green "" false $'Refs #101\nthe package PR, which closes #101' |
    jq --arg c "$5" '.closingIssuesReferences = ($c | split(" ") | map(select(. != "") | {number: tonumber}))')
  printf '%s\n' "$p" "$c" | prs
  json pr51.json "$(detail "$c" 2030-11-05T10:00:00Z ${6:+"$6"})"; route 'pr view 51 *' pr51.json
  json files51.json '[{"filename": "contracts/a.yaml"}]'; route 'api --paginate repos/example-org/web/pulls/51/files*' files51.json
  json i101.json '{"labels": [{"name": "in-progress"}]}'; route 'issue view 101 *' i101.json
  json i103.json '{"labels": [{"name": "in-progress"}]}'; route 'issue view 103 *' i103.json
  echo sid > "$WORKERS_DIR/web-$k.id"
}
CFIX="PR #51 is the contract PR, but GitHub links it as closing #101: its merge would close the issue with only the contract done."
cfix contract-closes pkg-12-auth "101 103" pkg-12-auth 101
dispatch --once
ok "contract closes: a package's contract PR linked as closing a member → its worker is resumed with the text" \
  grep -qF -- "--key pkg-12-auth --dir" "$FAKE/worker.log" && grep -qF "web pkg-12-auth $CFIX" "$FAKE/worker.log"
ok "… told to write Refs and change only the body" grep -qF 'write `Refs #101` and "the unit'"'"'s own PR implements #101". Change no file and push nothing. Then stop.' "$FAKE/worker.log"
ok "… body_fix is set" eq "$(st pkg-12-auth body_fix)" 51
ok "… no reviewer starts, no accept is asked" eq "$(grep -c -- '--key review-' "$FAKE/worker.log") $(grep -c 'awaiting-accept\|needs-you' "$FAKE/gh.log")" "0 0"
ok "… logged" grep -q 'pkg-12-auth PR #51: the contract PR would close #101; the worker corrects the body' "$CANCCU_HOME/dispatch.log"
: > "$FAKE/worker.log"; sed -i '/^phase=/d' "$CANCCU_HOME/state/pkg-12-auth"; echo phase=check >> "$CANCCU_HOME/state/pkg-12-auth"
rm -f "$WORKERS_DIR"/web-pkg-12-auth.lock
dispatch --once
ok "contract closes: still linked on the next pass with body_fix set → needs-you, no worker run" \
  eq "$(st pkg-12-auth phase) $(grep -c . "$FAKE/worker.log")" "needs-you 0"
ok "… with the text" grep -qF 'PR #51 is the contract PR but GitHub still links it as closing #101: edit the PR body so that no closing keyword stands before an issue number' "$FAKE/gh.log"

cfix contract-fixed pkg-12-auth "101 103" pkg-12-auth "" ; echo body_fix=51 >> "$CANCCU_HOME/state/pkg-12-auth"
dispatch --once
ok "contract closes: once the links are gone the pass goes on to the review" grep -q -- '--key review-51 ' "$FAKE/worker.log"
cfix contract-passed pkg-12-auth "101 103" pkg-12-auth "" "$(vcomment 2030-11-05T11:00:00Z "ok
Review verdict: pass $HB")"
echo body_fix=51 >> "$CANCCU_HOME/state/pkg-12-auth"
dispatch --once
ok "… a pass verdict already on that head is acted on without a new review" \
  eq "$(grep -c -- '--key review-' "$FAKE/worker.log") $(st pkg-12-auth phase)" "0 merging"

cfix contract-closes-issue 5 5 5-issue-5 5
dispatch --once
ok "contract closes: a single issue's contract PR linked as closing it → its worker is resumed, body_fix set" \
  eq "$(grep -cF -- "PR #51 is the contract PR, but GitHub links it as closing #5:" "$FAKE/worker.log") $(st 5 body_fix)" "1 51"

cfix contract-closes-dry pkg-12-auth "101 103" pkg-12-auth 101
before=$(cat "$CANCCU_HOME/state/pkg-12-auth")
dispatch --dry-run
ok "contract closes: a dry run changes nothing" \
  eq "$(grep -c . "$FAKE/worker.log") $(grep -cE '^(issue|pr) (edit|comment)' "$FAKE/gh.log") $([ "$(cat "$CANCCU_HOME/state/pkg-12-auth")" = "$before" ] && echo same)" "0 0 same"

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

# ---------------------------------------------------------------- `accepted` on the issue (#104)

# issue_accept <name> <accept_sha> <head> [who labelled] [when]: PR 50 waits for the accept of
# issue 5, whose `accepted` label (none on the PR) has that label event
issue_accept() {
  env_new "$1"
  { issue 5 in-progress,awaiting-accept,accepted; } | issues
  pr 50 5 "$3" | prs
  state 5 phase=accept pr=50 "accept_sha=$2" rounds=0 "accept_at=$((NOW - 3600))"
  jq -n --arg u "${4:-octo}" --arg t "${5:-2030-11-05T11:30:00Z}" \
    '[{event: "labeled", label: {name: "accepted"}, actor: {login: $u}, created_at: $t}]' > "$FAKE/events5.json"
  route 'api --paginate repos/example-org/web/issues/5/events' events5.json
}
issue_accept on-issue $HA $HA
dispatch --once
ok "accepted on the issue by the user after the request → auto-merge armed" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
ok "… the label taken off the issue" has gh.log "issue edit 5 -R example-org/web --remove-label accepted"
ok "… logged" grep -q '#5 PR #50: `accepted` was on issue #5; taken as the accept' "$CANCCU_HOME/dispatch.log"
issue_accept on-issue-old $HA $HA octo 2030-11-05T10:00:00Z
dispatch --once
ok "accepted on the issue before the accept request → no merge" hasnt gh.log "pr merge"
ok "… one warning naming the issue" eq "$(grep -c 'PR #50: `accepted` on #5 was not added by octo after the accept request; ignored' "$CANCCU_HOME/dispatch.log")" 1
issue_accept on-issue-other $HA $HA review-bot
dispatch --once
ok "accepted on the issue by another login → no merge" hasnt gh.log "pr merge"
ok "… the warning names the issue" grep -q '`accepted` on #5 was not added by octo' "$CANCCU_HOME/dispatch.log"
issue_accept on-issue-push $HA $HB
dispatch --once
ok "a new push while accepted sits on the issue → requeue takes it off the issue" has gh.log "issue edit 5 -R example-org/web --remove-label accepted"
ok "… no merge, review again" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/check
issue_accept to-accept $HA $HA
lib eval "fetch; to_accept 5 50 'manual: x' $HA"
ok "to_accept takes an old accepted off the issue too" has gh.log "issue edit 5 -R example-org/web --remove-label accepted"

env_new pkg-accept
{ issue 101 in-progress,awaiting-accept; issue 103 in-progress,accepted; } | issues
PR_BRANCH=pkg-12-auth pr 50 0 $HA | jq '.closingIssuesReferences = [{number: 101}, {number: 103}]' | prs
state pkg-12-auth pkg=auth step=12 "members=101 103" branch=pkg-12-auth risk=normal \
  phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 3600))"
json events103.json '[{"event": "labeled", "label": {"name": "accepted"}, "actor": {"login": "octo"}, "created_at": "2030-11-05T11:30:00Z"}]'
route 'api --paginate repos/example-org/web/issues/103/events' events103.json
dispatch --once
ok "a package whose second member has accepted → auto-merge armed" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
ok "… the label taken off that member" has gh.log "issue edit 103 -R example-org/web --remove-label accepted"
ok "… logged" grep -q 'pkg-12-auth PR #50: `accepted` was on issue #103; taken as the accept' "$CANCCU_HOME/dispatch.log"
env_new health-accept
state pkg-12-health pkg=health step=12 health=1 members= branch=pkg-12-health
ok "a health pass has no issue to read accepted from" eq "$(lib members_of pkg-12-health)" ""

# ---------------------------------------------------------------- a merge of main only (#91)

env_new main-merge-only; mmrepo
mmo() { lib eval ". '$root/lib/canccu-merge.sh'; main_merge_only $1 $2 && echo yes || echo no"; }
ok "main_merge_only: one clean merge of main → true" eq "$(mmo "$MB_B" "$MB_MM1")" yes
ok "main_merge_only: two stacked clean merges of main → true" eq "$(mmo "$MB_B" "$MB_MM2")" yes
ok "main_merge_only: a merge of main with one more edited line → false" eq "$(mmo "$MB_B" "$MB_MX")" no
ok "main_merge_only: a merge of a branch that is not on main → false" eq "$(mmo "$MB_B" "$MB_MO")" no
ok "main_merge_only: a plain commit → false" eq "$(mmo "$MB_B" "$MB_PC")" no
ok "main_merge_only: a base the walk never reaches → false" eq "$(mmo "$MB_PC" "$MB_MM1")" no
ok "main_merge_only: a git error (an unknown head) → false" eq "$(mmo "$MB_B" "$HA")" no

# ---------------------------------------------------------------- the fix-check counts the PR's own lines (#150)

# fcrepo: a real repo in CLONE. The PR (FC_B) added a line to f.txt; main then added 150 lines
# at f.txt's top (and changed c.txt's line 2). FC_F: FC_B merged main cleanly, plus 10 own lines. FC_O:
# FC_B plus 150 own lines. FC_C: FC_C0 (FC_B plus an edit of c.txt's line 2) with main merged in by hand (a
# conflict, resolved to the PR's side).
fcrepo() {
  local d=$E/code/web i
  _fg() { GIT_AUTHOR_DATE=2030-11-05T10:00:00Z GIT_COMMITTER_DATE=2030-11-05T10:00:00Z \
          "$FAKE_REAL_GIT" -C "$d" -c user.name=octo -c user.email=octo@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
  rm -rf "$d"; mkdir -p "$d"; _fg init
  printf 'f1\nf2\nf3\n' > "$d/f.txt"; printf 'c1\nc2\nc3\n' > "$d/c.txt"; _fg add .; _fg commit -m root
  _fg checkout -b pr; echo p1 >> "$d/f.txt"; _fg commit -am "the PR"; FC_B=$("$FAKE_REAL_GIT" -C "$d" rev-parse HEAD)
  _fg checkout main; { for ((i = 1; i <= 150; i++)); do echo "m$i"; done; cat "$d/f.txt"; } > "$d/x"; mv "$d/x" "$d/f.txt"
  sed -i 's/^c2$/c2 main/' "$d/c.txt"; _fg commit -am "main's 150 lines"; _fg update-ref refs/remotes/origin/main main
  _fg checkout -b fix pr; _fg merge --no-edit main; for ((i = 1; i <= 10; i++)); do echo "q$i"; done >> "$d/f.txt"
  _fg commit -am "a 10-line fix"; FC_F=$("$FAKE_REAL_GIT" -C "$d" rev-parse HEAD)
  _fg checkout -b own pr; for ((i = 1; i <= 150; i++)); do echo "o$i"; done >> "$d/f.txt"
  _fg commit -am "150 own lines"; FC_O=$("$FAKE_REAL_GIT" -C "$d" rev-parse HEAD)
  _fg checkout -b cfl pr; sed -i 's/^c2$/c2 pr/' "$d/c.txt"; _fg commit -am "the PR's c2"; FC_C0=$("$FAKE_REAL_GIT" -C "$d" rev-parse HEAD)
  _fg merge --no-edit main; sed -i '/^[<=>|]\{7\}/d; /^c2 main$/d' "$d/c.txt"; _fg commit -am "merge main, c2 resolved"
  FC_C=$("$FAKE_REAL_GIT" -C "$d" rev-parse HEAD)
  _fg checkout main; touch "$FAKE/realgit"
}
env_new fixcheck-count; fcrepo
ppf() { lib eval ". '$root/lib/canccu-merge.sh'; FIXCHECK_COUNT_MAIN=$1; postpass_full $2 $3"; }
ok "postpass_full: main's 150 lines merged in, plus a 10-line fix → no full review" eq "$(ppf 0 "$FC_B" "$FC_F")" ""
ok "… with FIXCHECK_COUNT_MAIN=1: full review, as before" eq "$(ppf 1 "$FC_B" "$FC_F")" "160 changed lines, over FIXCHECK_FULL_LINES=100"
ok "… 150 own lines: full review" eq "$(ppf 0 "$FC_B" "$FC_O")" "150 changed lines, over FIXCHECK_FULL_LINES=100"
ok "… a merge of main resolved by hand: counted from base, as before" eq "$(ppf 0 "$FC_C0" "$FC_C")" "150 changed lines, over FIXCHECK_FULL_LINES=100"

# ---------------------------------------------------------------- the accept kept on a merge of main (#92)

# keepenv <name> <phase> <setting> <new head>: PR 50, accepted by the user on MB_B (in accept, or
# in merging with how=accepted), has moved to the new head
keepenv() {
  env_new "$1" "KEEP_ACCEPT_ON_MAIN_MERGE=$3"; mmrepo
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 "$4" green accepted | prs
  json events50.json '[{"event": "labeled", "label": {"name": "accepted"}, "actor": {"login": "octo"}, "created_at": "2030-11-05T11:30:00Z"}]'
  route 'api --paginate repos/example-org/web/issues/50/events' events50.json
  if [ "$2" = accept ]; then state 5 phase=accept pr=50 "accept_sha=$MB_B" rounds=0 "accept_at=$((NOW - 3600))"
  else state 5 phase=merging pr=50 "merge_sha=$MB_B" how=accepted "merge_at=$((NOW - 600))" "accept_sha=$MB_B" "accept_at=$((NOW - 3600))"; fi
}
for ph in accept merging; do
  keepenv "keep-$ph" "$ph" 1 "$MB_MM1"
  dispatch --once
  ok "$ph, KEEP_ACCEPT_ON_MAIN_MERGE=1, a clean merge of main → \`accepted\` kept" hasnt gh.log "remove-label accepted"
  ok "… auto-merge on the new head" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $MB_MM1"
  ok "… logged" grep -qF "#5 PR #50: \`accepted\` carried over from ${MB_B:0:7} to ${MB_MM1:0:7}: a merge of main only (KEEP_ACCEPT_ON_MAIN_MERGE=1)" "$CANCCU_HOME/dispatch.log"
  ok "… merging, how accepted, on the new head" eq "$(st 5 phase) $(st 5 how) $(st 5 merge_sha)" "merging accepted $MB_MM1"
  keepenv "keep-$ph-plus" "$ph" 1 "$MB_MX"
  dispatch --once
  ok "$ph, KEEP_ACCEPT_ON_MAIN_MERGE=1, a merge of main plus one line → \`accepted\` dropped" has gh.log "pr edit 50 -R example-org/web --remove-label accepted"
  ok "… no merge, review again" eq "$(grep -c -- '--auto' "$FAKE/gh.log")/$(st 5 phase)" 0/check
  keepenv "keep-$ph-off" "$ph" 0 "$MB_MM1"
  dispatch --once
  ok "$ph, KEEP_ACCEPT_ON_MAIN_MERGE=0, a clean merge of main → \`accepted\` dropped" has gh.log "pr edit 50 -R example-org/web --remove-label accepted"
  ok "… no merge, review again" eq "$(grep -c -- '--auto' "$FAKE/gh.log")/$(st 5 phase)" 0/check
done

# ---------------------------------------------------------------- a conflict with main (#89)

# dirtyenv <name> <phase> <mergeStateStatus> [config line...]: PR 50 (branch 5-thing, worktree of
# issue 5) waits in accept, in merging with auto-merge armed, or (ci) in check with no CI checks
# for longer than NO_CHECKS_MIN (GitHub runs none on a conflicting PR), at HA; main is 2 commits ahead
dirtyenv() {
  env_new "$1" "${@:4}"
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 $HA "$([ "$2" = ci ] && echo none || echo green)" | jq --arg m "$3" '.mergeStateStatus = $m' | prs
  if [ "$2" = accept ]; then state 5 phase=accept pr=50 accept_sha=$HA pass_sha=$HA rounds=0 "accept_at=$((NOW - 3600))"
  elif [ "$2" = ci ]; then state 5 phase=check pr=50 "check_at=$((NOW - 3600))"
  else state 5 phase=merging pr=50 merge_sha=$HA pass_sha=$HA how=auto "merge_at=$((NOW - 60))"; fi
  mkdir -p "$WORKERS_DIR/worktrees/web/issue-5" && touch "$WORKERS_DIR/worktrees/web/issue-5/.git"
  echo 5-thing > "$FAKE/branch"; echo 2 > "$FAKE/behind"
}
for ph in accept merging; do
  dirtyenv "dirty-$ph" "$ph" DIRTY
  dispatch --once
  ok "$ph, the PR conflicts with main → main merged in by script, pushed" eq "$(grep -c 'merge --no-edit origin/main' "$FAKE/git.log") $(grep -c 'push origin HEAD:refs/heads/5-thing' "$FAKE/git.log")" "1 1"
  ok "… no AI run" eq "$(wc -l < "$FAKE/worker.log")" 0
  ok "… logged" grep -qF '#5 PR #50: conflicts with main; merged main into the branch by script (no AI run)' "$CANCCU_HOME/dispatch.log"
  ok "… noted for the head" eq "$(st 5 conflict_merge)" "$HA"
  [ "$ph" = merging ] && ok "… auto-merge disabled first" has gh.log "pr merge 50 -R example-org/web --disable-auto"
  dispatch --once
  ok "… once per head: GitHub still says DIRTY on the same head → no second merge" eq "$(grep -c 'merge --no-edit origin/main' "$FAKE/git.log")" 1
done

dirtyenv dirty-conflict accept DIRTY; printf 'src/a.ts\nsrc/b.ts\n' > "$FAKE/merge-conflict"
dispatch --once
ok "the merge of main conflicts → aborted, nothing pushed" eq "$(grep -c 'merge --abort' "$FAKE/git.log") $(grep -c push "$FAKE/git.log")" "1 0"
ok "… the worker resolves it, a merge run, told the files" grep -q -- '--fresh .*web 5 Rules for this run: .* Merging origin/main into the branch of PR #50 conflicts in: src/a.ts src/b.ts' "$FAKE/worker.log"
ok "… logged" grep -qF '#5 PR #50: conflicts with main in: src/a.ts src/b.ts; the worker resolves them' "$CANCCU_HOME/dispatch.log"
ok "… conflict_sha is the head; not a fix attempt" eq "$(st 5 conflict_sha) $(st 5 fixes)" "$HA "
rm -f "$WORKERS_DIR/web-5.lock"; last 5 done "could not resolve the conflict"
# GitHub has not recomputed the merge state yet: postpass_step, not conflict_merge, finds the head unchanged
pr 50 5 $HA | prs
dispatch --once
ok "… its run ends, reaped to check" eq "$(st 5 phase)" check
json pr50.json "$(detail "$(pr 50 5 $HA)" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
dispatch --once
ok "… it pushed nothing (still the passed head) → needs-you" has gh.log "PR #50 conflicts with main in: src/a.ts src/b.ts, and the worker's merge run pushed no resolution"
ok "… no second review, no second run" eq "$(grep -c -- '--key review-50' "$FAKE/worker.log") $(grep -c 'Merging origin/main into the branch' "$FAKE/worker.log")" "0 1"

dirtyenv dirty-dirty accept DIRTY; printf ' M src/a.ts\n' > "$FAKE/dirty"
dispatch --once
ok "the merge by script cannot run → needs-you saying why" has gh.log "PR #50 conflicts with main; the merge by script did not run (uncommitted changes in the worktree)"

dirtyenv dirty-current accept DIRTY; echo 0 > "$FAKE/behind"
dispatch --once
ok "DIRTY but main is in already (GitHub's state is stale) → logged only" grep -qF '#5 PR #50: conflicts with main; the merge by script did not run (main is in already)' "$CANCCU_HOME/dispatch.log"
ok "… no needs-you, no push" eq "$(grep -c needs-you "$FAKE/gh.log") $(grep -c push "$FAKE/git.log")" "0 0"

# #149: in phase ci too, a conflicting PR gets main merged in by script, not a no-checks needs-you
dirtyenv dirty-ci ci DIRTY
dispatch --once
ok "ci, the PR conflicts with main → main merged in by script, pushed" eq "$(grep -c 'merge --no-edit origin/main' "$FAKE/git.log") $(grep -c 'push origin HEAD:refs/heads/5-thing' "$FAKE/git.log")" "1 1"
ok "… logged" grep -qF '#5 PR #50: conflicts with main; merged main into the branch by script (no AI run)' "$CANCCU_HOME/dispatch.log"
ok "… no needs-you, no AI run" eq "$(grep -c needs-you "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "0 0"
ok "… the new head noted, its CI wait timed from now" eq "$(st 5 main_merged) $(st 5 check_at)" "$FAKE_MERGED $NOW"
pr 50 5 "$FAKE_MERGED" none | prs
dispatch --once
ok "… next pass, the new head has no checks yet → no needs-you" eq "$(grep -c needs-you "$FAKE/gh.log")" 0

dirtyenv dirty-ci-conflict ci DIRTY; printf 'src/a.ts\n' > "$FAKE/merge-conflict"
dispatch --once
ok "ci, the merge of main conflicts → one worker merge run" grep -q 'Merging origin/main into the branch of PR #50 conflicts in: src/a.ts' "$FAKE/worker.log"
rm -f "$WORKERS_DIR/web-5.lock"; last 5 done "could not resolve the conflict"
dispatch --once; dispatch --once
ok "… the same head on later passes → no second merge run, needs-you" \
  eq "$(grep -c 'Merging origin/main into the branch' "$FAKE/worker.log") $(grep -c 'merge --no-edit origin/main' "$FAKE/git.log")" "1 1"
ok "… saying the run pushed no resolution" has gh.log "PR #50 conflicts with main in: src/a.ts, and the worker's merge run pushed no resolution"

dirtyenv dirty-ci-off ci DIRTY MERGE_MAIN_ANY_PHASE=0
dispatch --once
ok "ci, MERGE_MAIN_ANY_PHASE=0 → no merge of main in phase ci" not grep -qs 'merge --no-edit' "$FAKE/git.log"
ok "… no AI run" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… the no-checks needs-you names the conflict" has gh.log "no CI checks on PR #50: it conflicts with main, so GitHub runs no checks; merge main into it or say how"

for ph in accept merging; do
  dirtyenv "behind-$ph" "$ph" BEHIND
  dispatch --once
  ok "$ph, BEHIND only → nothing merged" hasnt git.log "merge --no-edit"
done
ok "fetch_prs reads mergeStateStatus" grep -q 'mergeStateStatus' "$root/lib/canccu-github.sh"

# ---------------------------------------------------------------- the merge queue's removal reason (#90)

# qrenv <name> <reason> <createdAt>: auto-merge off, not queued, 10 min after it was armed (11:50),
# and the PR's newest RemovedFromMergeQueueEvent; merge_group runs of PR 50 and of another PR
qrenv() {
  merging_off "$1" '{"state": "OPEN"}'
  mkdir -p "$WORKERS_DIR/worktrees/web/issue-5" && touch "$WORKERS_DIR/worktrees/web/issue-5/.git"
  echo 5-thing > "$FAKE/branch"; echo 2 > "$FAKE/behind"
  jq -n --arg r "$2" --arg t "$3" '{data: {repository: {pullRequest: {timelineItems: {nodes: [{reason: $r, createdAt: $t}]}}}}}' > "$FAKE/qr.json"
  route 'api graphql *RemovedFromMergeQueueEvent*' qr.json
  json mgruns.json '{"workflow_runs": [
    {"name": "CI", "html_url": "https://github.com/example-org/web/actions/runs/901", "head_branch": "gh-readonly-queue/main/pr-50-abc", "conclusion": "failure"},
    {"name": "Lint", "html_url": "https://github.com/example-org/web/actions/runs/902", "head_branch": "gh-readonly-queue/main/pr-50-abc", "conclusion": "success"},
    {"name": "CI", "html_url": "https://github.com/example-org/web/actions/runs/903", "head_branch": "gh-readonly-queue/main/pr-51-def", "conclusion": "failure"}]}'
  route 'api repos/example-org/web/actions/runs?event=merge_group&per_page=20*' mgruns.json
}
qrenv qr-conflict MERGE_CONFLICT 2030-11-05T11:55:00Z
dispatch --once
ok "the queue removed it for a conflict → main merged in by script" has git.log "merge --no-edit origin/main"
ok "… no needs-you" hasnt gh.log "needs-you"
ok "… logged" grep -qF '#5 PR #50: the merge queue removed it (merge conflict); merging main by script' "$CANCCU_HOME/dispatch.log"
qrenv qr-checks FAILED_CHECKS 2030-11-05T11:55:00Z
dispatch --once
ok "the queue removed it for failed checks → needs-you naming the failed run of its group" \
  has gh.log "the merge queue removed PR #50 because checks failed in its merge group: CI https://github.com/example-org/web/actions/runs/901. Not enqueued again"
ok "… not another PR's run, nor a green one" eq "$(grep -c -e 'runs/903' -e 'runs/902' "$FAKE/gh.log")" 0
ok "… no enqueue" not grep -q 'enqueuePullRequest' "$FAKE/gh.log"
qrenv qr-manual MANUAL 2030-11-05T11:55:00Z
dispatch --once
ok "removed for another reason → needs-you that says so" has gh.log "the merge queue removed PR #50 (reason: MANUAL); a manual removal or a queue change. Not enqueued again"
qrenv qr-old FAILED_CHECKS 2030-11-05T11:40:00Z
dispatch --once
ok "a removal from before merge_at → today's needs-you" has gh.log "auto-merge was disabled or the merge queue rejected PR #50"
ok "… not the removal's" hasnt gh.log "checks failed in its merge group"

# ---------------------------------------------------------------- a GitHub error on the merge (#130)

# macc <name> [config...]: PR 50 of issue 5 waits for the accept of HA, accepted by octo since
macc() {
  env_new "$@"
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 $HA green accepted | prs
  state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 3600))"
  jq -n '[{event: "labeled", label: {name: "accepted"}, actor: {login: "octo"}, created_at: "2030-11-05T11:30:00Z"}]' > "$FAKE/events50.json"
  route 'api --paginate repos/example-org/web/issues/50/events' events50.json
}
# flaky <times> <error>: the first <times> `gh pr merge` calls fail with that error (0: every one)
flaky() {
  mkdir -p "$E/sbin"
  cat > "$E/sbin/gh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr merge" ]; then
  k=\$(( \$(cat "$E/merges" 2>/dev/null || echo 0) + 1 )); echo "\$k" > "$E/merges"
  if [ "$1" = 0 ] || [ "\$k" -le "$1" ]; then echo "$2" >&2; exit 1; fi
fi
exec "$fb/gh" "\$@"
SH
  chmod +x "$E/sbin/gh"
}
fpass() { PATH="$E/sbin:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1; }
dlog() { grep -cF -- "$1" "$CANCCU_HOME/dispatch.log"; }

macc merge-502-once
flaky 1 'HTTP 502: Bad Gateway'
fpass
ok "a 502 on the merge → the retry is logged" grep -qF '#5 PR #50: GitHub error on the merge (try 1 of 3); trying again next pass: HTTP 502: Bad Gateway' "$CANCCU_HOME/dispatch.log"
ok "… the unit stays in accept, the try counted, no needs-you" eq "$(st 5 phase) $(st 5 merge_tries) $(grep -c needs-you "$FAKE/gh.log")" "accept 1 0"
fpass
ok "… the next pass merges" eq "$(dlog '#5 PR #50: auto-merge enabled (accepted)') $(st 5 phase)" "1 merging"
ok "… the tries cleared, still no needs-you" eq "[$(st 5 merge_tries)] $(grep -c needs-you "$FAKE/gh.log")" "[] 0"

macc merge-502-always MERGE_RETRY=2
flaky 0 'HTTP 502: Bad Gateway'
fpass; fpass
ok "a 502 on every merge, MERGE_RETRY=2 → two passes retry, no needs-you yet" \
  eq "$(dlog 'trying again next pass') $(st 5 phase) $(grep -c needs-you "$FAKE/gh.log")" "2 accept 0"
fpass
ok "… the third pass raises the needs-you" eq "$(st 5 phase) $(st 5 ny_stage)" "needs-you merge"
ok "… its reason ends with the tries" has gh.log "gh: HTTP 502: Bad Gateway (after 2 tries)"

macc merge-not-mergeable
flaky 0 'GraphQL: Pull request is not mergeable (enablePullRequestAutoMerge)'
fpass
ok "a refusal (not mergeable) → the needs-you at once, no retry" \
  eq "$(st 5 phase) $(dlog 'trying again next pass')" "needs-you 0"
ok "… with gh's error, no tries named" eq "$(grep -c 'Pull request is not mergeable' "$FAKE/gh.log") $(grep -c 'tries)' "$FAKE/gh.log")" "1 0"

# merging_step's direct merge (no auto-merge in the repo), CI green on the passed head
env_new merge-direct-502
{ issue 5 in-progress; } | issues
pr 50 5 $HA green | prs
json repo.json '{"allow_auto_merge": false}'
state 5 phase=merging pr=50 merge_sha=$HA how=auto merge_mode=direct "merge_at=$((NOW - 60))"
flaky 1 'HTTP 503: Service Unavailable'
fpass
ok "a direct merge's 503 → retried: merging (direct), no needs-you" \
  eq "$(st 5 phase) $(st 5 merge_mode) $(st 5 merge_tries) $(dlog 'GitHub error on the merge (try 1 of 3)')" "merging direct 1 1"
fpass
ok "… the next pass merges it directly" eq "$(dlog '#5 PR #50: merged directly') $(st 5 merge_mode) [$(st 5 merge_tries)]" "1 merged []"

ok "gh_transient: 5xx, timeouts and dropped connections" lib gh_transient $'x\nPost "https://api.github.com/graphql": net/http: TLS handshake timeout'
ok "gh_transient: any case" lib gh_transient 'non-200 OK status code: 504 GATEWAY TIMEOUT'
ok "gh_transient: a refusal is not" not lib gh_transient 'GraphQL: Head branch was modified. Review and try the merge again.'

# munpark <name> <head> [labels]: a needs-you at the merge of the accepted HA; the PR's head given
munpark() {
  env_new "$1"
  { issue 5 "in-progress${3:+,$3}"; } | issues
  p=$(pr 50 5 "$2" green); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "${@:4}")"; route 'pr view 50 *' pr50.json
  json c5.json '{"comments": []}'; route 'issue view 5 *' c5.json
  state 5 phase=needs-you pr=50 accept_sha=$HA "accept_at=$((NOW - 3600))" "ny_at=$((NOW - 600))" ny_stage=merge merge_tries=3 \
    "reason=gh pr merge failed (after 3 tries)"
  touch "$CANCCU_HOME/paused"
}
munpark merge-unpark $HA
dispatch --once
ok "a merge needs-you lifted with no comment, head = accept_sha → back to accept, tries cleared" eq "$(st 5 phase) [$(st 5 merge_tries)]" "accept []"
ok "… logged" grep -qF '#5 PR #50: needs-you lifted at the merge; trying the merge again' "$CANCCU_HOME/dispatch.log"
ok "… the worker is not resumed" not started 5
munpark merge-unpark-push $HB
dispatch --once
ok "… with a newer head → requeued for review instead" eq "$(st 5 phase) $(dlog 'review again') $(dlog 'needs-you lifted at the merge')" "check 1 0"
munpark merge-unpark-auto $HA
sed -i '/^accept_sha=/d' "$CANCCU_HOME/state/5"
dispatch --once
ok "… no accept_sha (an automatic merge) → left in needs-you" eq "$(st 5 phase) $(dlog 'needs-you lifted')" "needs-you 0"
munpark merge-unpark-label $HA needs-you
dispatch --once
ok "… the label still there → nothing" eq "$(st 5 phase) $(dlog 'needs-you lifted')" "needs-you 0"
munpark merge-unpark-comment $HA "" "$(comment 2030-11-05T11:58:00Z 'Merged it by hand, wait')"
dispatch --once
ok "… a comment since → not unparked (resume_step's path)" eq "$(dlog 'needs-you lifted at the merge')" 0

echo "canccu-merge tests: $npass passed, $nfail failed"
(( nfail == 0 ))
