#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-waits.sh — offline tests for `blocked` and the quiet wait: a blocked issue never
# starts or resumes, a worker that stops blocked waits without needs-you, a resume with no PR
# starts afresh (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- never started

env_new blocked-start
{ issue 3 ready,blocked; issue 4 ready; } | issues
dispatch --once
ok "ready and blocked → not started, whatever its dependencies say" not started 3
ok "… the next one starts" started 4

env_new blocked-step
ms() { jq -nc --argjson n "$1" --arg t "$2" '{number: $n, title: $t, open_issues: 0, closed_issues: 0, due_on: null}'; }
ms 12 "3 Events" | jq -s . > "$FAKE/ms.json"
{ issue 90 epic "" "3 Events"; issue 101 ready,blocked "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
ok "a blocked step issue is not eligible for a package" eq "$(lib eval 'fetch; fetch_steps; eligible_issue 12 101 && echo yes || echo no')" no
ok "… a ready one is" eq "$(lib eval 'fetch; fetch_steps; eligible_issue 12 103 && echo yes || echo no')" yes

# ---------------------------------------------------------------- never resumed

env_new blocked-plan-ok
{ issue 5 in-progress,plan-ok,blocked; } | issues
pr 50 5 $HA none "" true "Tier: plan" | prs
state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" ny_kind=plan
dispatch --once
ok "plan-ok on a blocked issue → no resume" not grep -q '^--quiet --name #5 ' "$FAKE/worker.log"
ok "… plan-ok stays for later" hasnt gh.log "--remove-label plan-ok"

env_new blocked-answered
{ issue 5 in-progress,needs-you,blocked; } | issues
json issue5.json "$(jq -n --argjson c "$(comment 2030-11-05T11:59:00Z 'Go on.')" '{comments: [$c], labels: []}')"
route 'issue view 5 *' issue5.json
state 5 phase=needs-you "ny_at=$((NOW - 600))"
dispatch --once
ok "the user's comment on a blocked needs-you → no resume" not grep -q '^--quiet --name #5 ' "$FAKE/worker.log"

# ---------------------------------------------------------------- a worker that stops blocked

BLOCKED_REPORT=$'#5 waits for #8.\n\n1. **Status:** blocked: #8 (the contract) is still open.\nQuestion: wait for #8, or build against a stub?\n2. **PR URL:** none'
env_new waits
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 done "$BLOCKED_REPORT"
echo sid > "$WORKERS_DIR/web-5.id"
dispatch --once
ok "stopped blocked, no PR → the quiet wait" eq "$(st 5 phase)" waiting
ok "… no needs-you" hasnt gh.log "needs-you"
ok "… no answerer, though it asked" not grep -q -- '--key answer-5' "$FAKE/worker.log"
ok "… the issue is labelled blocked, as the dispatcher's own" eq "$(grep -c 'issue edit 5 -R example-org/web --add-label blocked' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/blocked/5" && echo marked)" "1 marked"
ok "… and not resumed in the same pass" not grep -q '^--quiet --name #5 ' "$FAKE/worker.log"
ok "… canccu-status lists the wait" grep -q '#5 · waits: blocked: #8' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"
{ issue 5 in-progress,blocked; } | issues
dispatch --once
ok "still labelled blocked → still waiting, nothing runs" eq "$(st 5 phase) $(grep -c '^--quiet --name #5 ' "$FAKE/worker.log")" "waiting 0"
{ issue 5 in-progress; } | issues
dispatch --once
ok "the label removed → resumed" grep -q '^--quiet --name #5 --fresh web 5 ' "$FAKE/worker.log"
ok "… afresh, with no session to --resume (its last run left no PR)" test ! -e "$WORKERS_DIR/web-5.id"
ok "… and the whole task in its prompt" grep -q '^--quiet --name #5 --fresh web 5 You are working on example-org/web issue #5 in this worktree.*no longer labelled .blocked' "$FAKE/worker.log"

env_new waits-not-started
{ issue 5 in-progress,blocked; } | issues
state 5 phase=work "started=$NOW"; last 5 done $'Status: not started; the issue is labelled blocked.\nPR URL: none'
dispatch --once
ok "not started, already labelled blocked (the lead's) → the quiet wait" eq "$(st 5 phase)" waiting
ok "… the label is not added again, nor marked as the dispatcher's" eq "$(grep -c 'add-label blocked' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/blocked/5" && echo marked)" "0 "

env_new waits-with-pr
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=work "started=$NOW"; last 5 done $'Status: PR ready, waiting for the review.\nPR URL: https://github.com/example-org/web/pull/50'
dispatch --once
ok "a status that waits but with a PR → the review, no wait" eq "$(st 5 phase)" review

# ---------------------------------------------------------------- resume with no PR: fresh

env_new fresh-resume
{ issue 5 in-progress,needs-you; } | issues
json issue5.json "$(jq -n --argjson c "$(comment 2030-11-05T11:59:00Z 'Build it now.')" '{comments: [$c], labels: []}')"
route 'issue view 5 *' issue5.json
state 5 phase=needs-you "ny_at=$((NOW - 600))" no_pr=1
echo sid > "$WORKERS_DIR/web-5.id"
dispatch --once
ok "no PR: the resume drops the session id" test ! -e "$WORKERS_DIR/web-5.id"
ok "… and carries the task and the user's answer" grep -q '^--quiet --name #5 --fresh web 5 You are working on example-org/web issue #5 .*The user answered: Build it now.' "$FAKE/worker.log"
env_new keep-resume RESUME_ON=answer,plan,user
{ issue 5 in-progress,needs-you; } | issues
pr 50 5 $HA red | prs
json issue5.json "$(jq -n --argjson c "$(comment 2030-11-05T11:59:00Z 'Fix CI.')" '{comments: [$c], labels: []}')"
route 'issue view 5 *' issue5.json; json pr50c.json '{"comments": []}'; route 'pr view 50 *' pr50c.json
state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" no_pr=1
echo sid > "$WORKERS_DIR/web-5.id"
dispatch --once
ok "an open PR, RESUME_ON names user: the session is resumed" eq "$(cat "$WORKERS_DIR/web-5.id") $(grep -c '^--quiet --name #5 web 5 The user answered: Fix CI.' "$FAKE/worker.log")" "sid 1"

# ---------------------------------------------------------------- only the dispatcher's own label is removed

env_new unblock-own
{ issue 6 blocked "Blocked by #5"; issue 7 blocked "Blocked by #5"; } | issues
json issue5.json '{"state": "CLOSED"}'; route 'issue view 5 *' issue5.json
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/7"
dispatch --once
ok "a blocked label the dispatcher did not add stays, its blockers closed or not" hasnt gh.log "issue edit 6 "
ok "… one it added goes once its blockers closed" has gh.log "issue edit 7 -R example-org/web --remove-label blocked --add-label ready"
ok "… and its mark with it" test ! -e "$CANCCU_HOME/blocked/7"

# ---------------------------------------------------------------- review findings

env_new waits-md-status
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 done $'**Status**: blocked: #8 is open\n**PR URL**: none'
dispatch --once
ok "**Status**: blocked (the colon after the bold) → the quiet wait" eq "$(st 5 phase)" waiting

env_new waits-keyword
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 done $'Status: PR ready, waiting for CI.\nPR URL: none'
dispatch --once
ok "a status that only says waiting is no blocked stop" not eq "$(st 5 phase)" waiting
ok "… and no blocked label" hasnt gh.log "add-label blocked"

env_new waits-label-fails
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 done $'Status: blocked: #8 is open.'
echo 'fail:issue edit' >> "$FAKE/routes"
dispatch --once
ok "the blocked label cannot be set → no wait without it (the next pass tries again)" eq "$(st 5 phase)" work

env_new mark-cleared
{ issue 5 in-progress; } | issues
state 5 phase=waiting reason=blocked
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/5"
dispatch --once
ok "the user removed the dispatcher's blocked → resumed, and the mark goes" eq "$(test -e "$CANCCU_HOME/blocked/5" && echo marked)$(grep -c '^--quiet --name #5 ' "$FAKE/worker.log")" 1
env_new mark-stale
{ issue 7 ""; } | issues
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/7"
dispatch --once
ok "a mark on an issue no longer labelled blocked goes" test ! -e "$CANCCU_HOME/blocked/7"
{ issue 7 blocked "Blocked by #5"; } | issues
json issue5.json '{"state": "CLOSED"}'; route 'issue view 5 *' issue5.json
dispatch --once
ok "… so a person's later blocked stays when its links close" hasnt gh.log "issue edit 7 "
ok "… and is said once (theirs to lift)" grep -q '#7 is labelled `blocked` by someone else and its blocked-by links are all closed' "$CANCCU_HOME/dispatch.log"

env_new waits-package
{ issue 5 in-progress,blocked; issue 6 in-progress "Blocked by #8"; } | issues
json issue8.json '{"state": "CLOSED"}'; route 'issue view 8 *' issue8.json
state pkg-12-a pkg=a step=12 wave=1 "members=5 6" branch=pkg-12-a phase=waiting reason=blocked
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/5"
dispatch --once
ok "a package's wait: the lead's label goes once any member's links are all closed" has gh.log "issue edit 5 -R example-org/web --remove-label blocked"

env_new fresh-after-question
{ issue 5 in-progress; } | issues
json issue5.json "$(jq -n --argjson c "$(comment 2030-11-05T12:00:30Z 'Answer: v2, per docs/x.md.')" '{comments: [$c], labels: []}')"
route 'issue view 5 *' issue5.json
state 5 phase=answer "started=$NOW" no_pr=1
mkdir -p "$CANCCU_HOME/questions"; echo 'Question: v1 or v2?' > "$CANCCU_HOME/questions/5.txt"
last answer-5 done 'ANSWERED'
dispatch --once
ok "a fresh session after an answer is told the question too" grep -q '^--quiet --name #5 --fresh web 5 You are working on .*Your earlier run stopped with this question: Question: v1 or v2?.*Answer: v2' "$FAKE/worker.log"

env_new answer-blocked
{ issue 5 in-progress,blocked; } | issues
state 5 phase=question
mkdir -p "$CANCCU_HOME/questions"; echo 'Question: v1 or v2?' > "$CANCCU_HOME/questions/5.txt"
dispatch --once
ok "no answerer for a blocked unit" not grep -q -- '--key answer-5' "$FAKE/worker.log"

# ---------------------------------------------------------------- blocked exit, finished work (#25)

# the worker's permission classifier denied a call the run then worked around: the exit report says
# `blocked`, though the PR is open and green; paused projects review too
env_new blocked-exit-pr
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=work "started=$NOW"; last 5 blocked $'PR ready.\nPR URL: https://github.com/example-org/web/pull/50'
touch "$CANCCU_HOME/paused"
dispatch --once
ok "a blocked exit with an open PR → the review, no needs-you, paused too" eq "$(st 5 phase)" review
ok "… no needs-you label" hasnt gh.log "needs-you"

env_new blocked-exit-no-pr
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 blocked $'Blocked by the permission classifier.'
dispatch --once
ok "a blocked exit with no PR → still needs-you" eq "$(st 5 phase)" needs-you

# a needs-you the lead lifts with no comment: the run is done and its PR waits for review
env_new lifted-needs-you
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json c5.json '{"comments": []}'; route 'issue view 5 *' c5.json
state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" ny_stage=work "reason=the worker stopped: blocked"
touch "$CANCCU_HOME/paused"
dispatch --once
ok "needs-you lifted, PR open and green → the review starts" grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… the worker is not resumed" not started 5

env_new kept-needs-you
{ issue 5 in-progress,needs-you; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json c5.json '{"comments": []}'; route 'issue view 5 *' c5.json
state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" ny_stage=work
dispatch --once
ok "needs-you still there → nothing happens" eq "$(st 5 phase)" needs-you

echo "canccu-waits tests: $npass passed, $nfail failed"
(( nfail == 0 ))
