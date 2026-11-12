# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by canccu-dispatch after canccu-common.sh; never run: the dispatcher pass, step 5 (accept, merging; step 6 is lib/canccu-aftermerge.sh).

# ---------------------------------------------------------------- 5. accept

# pr_gone <n> <pr>: the PR left the open list while the issue is open. The health pass's PR:
# health_pr_closed (a close) or finish_unit (a merge) takes it from here. A merged plan-only PR:
# plan_back. Another merged one: merged_left.
pr_gone() {
  local j
  is_health "$1" && return 0
  j=$(ghj pr view "$2" -R "$REPO" --json state,title,body,closingIssuesReferences,headRefName) || return 0
  case $(jqr .state <<<"$j") in
    CLOSED) needs_you "$1" "PR #$2 was closed without merging" ;;
    MERGED)
      if is_contract_pr "$1" "$(jqr '.headRefName // ""' <<<"$j")"; then contract_back "$1" "$2"
      elif plan_pr_merged "$1" "$j"; then plan_back "$1" "$2" "$(jqr '.headRefName // ""' <<<"$j")"
      else merged_left "$1" "$2" "$j"; fi ;;
  esac
  return 0
}

# merged_left <K> <pr> <pr view json>: the unit's PR merged with a member still open. One its
# `Closes` names is closed by GitHub a moment later: wait for that (gone_at), at most
# MERGE_WAIT_MIN. A member it does not name (or one still open after the wait) never closes on its
# own; parking the unit would block the `ready` that restarts it, so the unit is released and the
# member waits for a person with needs-you. The open list is capped: a member missing from it is
# confirmed with gh, and a gh error decides nothing (the next pass tries again).
merged_left() {
  local k=$1 pr=$2 j=$3 m l r s left=() open=() closed=() at
  for m in $(members_of "$k"); do
    if _issue_open "$m"; then s=OPEN
    else s=$(ghj issue view "$m" -R "$REPO" --json state -q .state) && [ -n "$s" ] ||
      { log "#$k: gh error reading issue #$m; retrying next pass"; return 0; }
    fi
    if [ "$s" != OPEN ]; then closed+=("$m"); continue; fi
    open+=("$m")
    [ "$(jqr --argjson m "$m" 'any(.closingIssuesReferences[]?; .number == $m)' <<<"$j")" = true ] || left+=("$m")
  done
  if (( ! ${#left[@]} )); then
    at=$(st_get "$k" gone_at)
    [ -n "$at" ] || { st_set "$k" gone_at="$(now)"; return 0; }
    (( $(now) - at > MERGE_WAIT_MIN * 60 )) || return 0
    left=("${open[@]}")
  fi
  unit_merged "$k" "$pr" "$(jqr '.title // ""' <<<"$j")" "${closed[@]}"
  for m in "${left[@]}"; do
    r=(); for l in in-progress awaiting-accept; do has_label "$m" "$l" && r+=(--remove-label "$l"); done
    mut gh issue edit "$m" -R "$REPO" --add-label needs-you "${r[@]}"
    mut gh issue comment "$m" -R "$REPO" --body "**Needs you** (canccu-dispatch): PR #$pr merged but did not close this issue. The dispatcher no longer manages it. If the work is done, close the issue. If work is left, remove \`needs-you\` and add \`ready\`: a new worker starts from main."$'\n\n'"$CANCCU_MARK"
  done
  step_unit_finished "$k" MERGED "$pr" "$(jqr '.body // ""' <<<"$j")"
  st_rm "$k"
  log "#$k PR #$pr merged but left $(printf '#%s, ' "${left[@]}" | sed 's/, $//') open: needs-you, unit released"
}

# contract_back <K> <pr>: the unit's contract-first PR merged (is_contract_pr); its issues stay
# open. Its review and merge round is over: the unit's own PR starts afresh in check, which
# resumes the worker on a draft (contract_merged) to bring in main and finish.
contract_back() {
  local k=$1 pr=$2 main
  main=$(pr_for "$k")
  st_set "$k" phase=check check_at="$(now)" pr="$main" contract_merged="$pr" \
    merge_mode= merge_at= merge_sha= how= accept_sha= accept_at=
  new_cycle "$k"
  has_label "$k" awaiting-accept && edit_issue "$k" --remove-label awaiting-accept
  log "#$k PR #$pr: the contract PR merged; the package goes on in PR #${main:-?}"
}

# plan_pr_merged <K> <pr view json>: a merged PR that closes none of the unit's issues and says it
# is a plan ("Plan for #n", or Tier: plan): the plan is on main, the issues stay open for the build.
# After plan-ok it is the build itself (classify keeps one that closes nothing from merging).
plan_pr_merged() {
  local m
  [ "$(st_get "$1" plan_ok)" = 1 ] && return 1
  { [ -n "$(jqr "$PR_ISSUES_JQ"' plan_for[]' <<<"$2")" ] || is_plan_body "$(jqr '.body // ""' <<<"$2")"; } || return 1
  for m in $(members_of "$1"); do
    [ "$(jqr --argjson m "$m" 'any(.closingIssuesReferences[]?; .number == $m)' <<<"$2")" = true ] && return 1
  done
  return 0
}

# plan_back <K> <pr> <head branch>: the unit's plan-only PR merged. The unit goes back to the
# queue as the lead did by hand: no longer managed, its worktree, branch and session gone (a fresh
# start), its issues `ready` and `plan-ok` (the start sets plan_ok and executes the plan) and no
# longer in-progress, needs-you or awaiting-accept. The head branch goes on GitHub too: the build
# gets the same name, and a squash-merged branch left there would refuse its push.
plan_back() {
  local k=$1 pr=$2 m l r
  unit_cleanup "$k" "$pr"
  [ -n "${3:-}" ] && { mut gh api -X DELETE "repos/$REPO/git/refs/heads/$3" >/dev/null || log "#$k: branch $3 not deleted on GitHub (gone already?)"; }
  for m in $(members_of "$k"); do
    r=()
    for l in in-progress needs-you awaiting-accept; do has_label "$m" "$l" && r+=(--remove-label "$l"); done
    mut gh issue edit "$m" -R "$REPO" --add-label ready --add-label plan-ok "${r[@]}"
  done
  st_rm "$k"
  log "#$k PR #$pr: the plan merged; back to the queue with plan-ok"
}

# requeue <n> <pr> <why>: a push after classification: drop `accepted` and auto-merge, review again
# (after a fix-check: a new fix-check; never a second full review)
requeue() {
  local n=$1 pr=$2
  drop_accepted "$n" "$pr"
  has_label "$n" awaiting-accept && edit_issue "$n" --remove-label awaiting-accept
  st_set "$n" phase=check check_at="$(now)" merge_mode=
  case $(st_get "$n" stage) in
    fixing|fixcheck) log "#$n PR #$pr: $3; \`accepted\` dropped, the fix-check is void: fix-check again" ;;
    *) log "#$n PR #$pr: $3; \`accepted\` dropped, review again" ;;
  esac
}

# accepted_by_user <pr|issue> <since epoch>: its newest `accepted` label event is by USER_LOGIN
# (never the reviewer bot) and came after the accept request
accepted_by_user() { label_by_user "$1" accepted "${2:-0}"; }

accept_step() {
  local n=$1 pr head i on=""
  pr=$(st_get "$n" pr)
  pr_is_open "$pr" || { pr_gone "$n" "$pr"; return; }
  head=$(pr_get "$pr" .headRefOid)
  if [ "$head" != "$(st_get "$n" accept_sha)" ]; then requeue "$n" "$pr" "new push since the classification"; return; fi
  # the label on an issue of the unit is tolerated too, under the same checks as on the PR
  if pr_has_label "$pr" accepted; then on=$pr
  else for i in $(members_of "$n"); do has_label "$i" accepted && { on=$i; break; }; done; fi
  [ -n "$on" ] || return 0
  if accepted_by_user "$on" "$(st_get "$n" accept_at)"; then
    if [ "$on" != "$pr" ]; then
      # taken off, so it can never count again for a later head
      mut gh issue edit "$on" -R "$REPO" --remove-label accepted
      log "#$n PR #$pr: \`accepted\` was on issue #$on; taken as the accept"
    fi
    merge_auto "$n" "$pr" accepted "$head"
  else warn_once "accept-$pr" "#$n PR #$pr: \`accepted\` on #$on was not added by $USER_LOGIN after the accept request; ignored"; fi
  return 0
}

# in_merge_queue <pr>: the PR sits in the merge queue (auto-merge hands it over there). A gh
# error counts as yes: the MERGE_WAIT_MIN bound still catches a PR that never merges.
in_merge_queue() {
  local r
  r=$(ghj api graphql -F o="${REPO%%/*}" -F r="${REPO#*/}" -F p="$1" \
        -f query='query($o: String!, $r: String!, $p: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $p) { mergeQueueEntry { state } } } }' \
        -q '.data.repository.pullRequest.mergeQueueEntry != null') || return 0
  [ "$r" = true ]
}

# merging_step <n>: auto-merge is armed (merge_mode empty), or, without auto-merge, the PR waits to
# merge directly (merge_mode direct; merged once done). A push disarms auto-merge (armed: by the
# state or by GitHub) and reviews again; auto-merge switched off (by GitHub, or the queue rejected
# the PR), or a merge that takes longer than MERGE_WAIT_MIN (direct: CI not green by then, no
# checks after NO_CHECKS_MIN, or the PR still open after the direct merge) → needs-you, so no PR
# waits here forever.
merging_step() {
  local n=$1 pr head at mode j
  pr=$(st_get "$n" pr)
  pr_is_open "$pr" || { pr_gone "$n" "$pr"; return; }
  mode=$(st_get "$n" merge_mode)
  head=$(pr_get "$pr" .headRefOid)
  if [ "$head" != "$(st_get "$n" merge_sha)" ]; then
    armed "$n" "$pr" && mut gh pr merge "$pr" -R "$REPO" --disable-auto
    if [ -z "$mode" ]; then requeue "$n" "$pr" "new push after auto-merge was enabled; auto-merge disabled"
    else requeue "$n" "$pr" "new push after the review passed; not merged"; fi
    return
  fi
  at=$(st_get "$n" merge_at); [ -n "$at" ] || { at=$(now); st_set "$n" merge_at="$at"; }
  case $mode in
    merged)   # the PR is still in this pass's list; open long after the merge → needs-you
      (( $(now) - at > MERGE_WAIT_MIN * 60 )) && needs_you "$n" "PR #$pr is still open $MERGE_WAIT_MIN min after the direct merge"
      return 0 ;;
    direct)
      case $(direct_ci "$pr") in
        none) if (( $(now) - at > ${NO_CHECKS_MIN:-10} * 60 )); then
                needs_you "$n" "no CI checks on PR #$pr at ${head:0:7} ${NO_CHECKS_MIN:-10} min after the review passed; not merged"; return 0
              fi ;;
        pending) if (( $(now) - at > MERGE_WAIT_MIN * 60 )); then
                   needs_you "$n" "PR #$pr has not merged $MERGE_WAIT_MIN min after the review passed; CI is not green on ${head:0:7}"; return 0
                 fi ;;
      esac
      merge_direct "$n" "$pr"; return 0 ;;
  esac
  if (( $(now) - at > MERGE_WAIT_MIN * 60 )); then
    mut gh pr merge "$pr" -R "$REPO" --disable-auto
    needs_you "$n" "PR #$pr has not merged $MERGE_WAIT_MIN min after auto-merge was enabled; auto-merge disabled (check the merge queue)"
  elif [ "$(pr_get "$pr" '.autoMergeRequest != null')" = false ] && (( $(now) - at > 120 )) && ! in_merge_queue "$pr"; then
    # merged meanwhile (the queue's reason `merged`, or this pass's list is older): no rejection
    j=$(ghj pr view "$pr" -R "$REPO" --json state,body,closingIssuesReferences,headRefName 2>/dev/null)
    if [ "$(jqr '.state // ""' <<<"$j" 2>/dev/null)" = MERGED ]; then
      if plan_pr_merged "$n" "$j"; then plan_back "$n" "$pr" "$(jqr '.headRefName // ""' <<<"$j")"
      else st_set "$n" merge_mode=merged merge_at="$(now)"; log "#$n PR #$pr: merged (auto-merge is off because it is done)"; fi
      return 0
    fi
    needs_you "$n" "auto-merge was disabled or the merge queue rejected PR #$pr"
  elif [ "$(st_get "$n" queue_kick)" != "$head" ] && (( $(now) - at > ${NO_CHECKS_MIN:-10} * 60 )); then
    queue_kick "$n" "$pr" "$head"
  fi
  return 0
}

# queue_kick <n> <pr> <head>: GitHub sometimes starts no merge_group run for a queue entry, which
# then waits for checks until the queue's own timeout. An entry still waiting NO_CHECKS_MIN after it
# was queued, with no run for its merge group, is dequeued and enqueued again (that starts them),
# once per head: still stuck, MERGE_WAIT_MIN's needs-you follows. A gh error reading decides nothing.
queue_kick() {
  local n=$1 pr=$2 r id at oid c
  r=$(ghj api graphql -F o="${REPO%%/*}" -F r="${REPO#*/}" -F p="$pr" \
        -f query='query($o: String!, $r: String!, $p: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $p) { id mergeQueueEntry { state enqueuedAt headCommit { oid } } } } }' \
        -q '.data.repository.pullRequest | select(.mergeQueueEntry.state == "AWAITING_CHECKS") | "\(.id) \(.mergeQueueEntry.enqueuedAt) \(.mergeQueueEntry.headCommit.oid // "")"') || return 0
  read -r id at oid <<<"$r"
  [ -n "$id" ] && [ -n "$at" ] && (( $(now) - $(iso_epoch "$at") > ${NO_CHECKS_MIN:-10} * 60 )) || return 0
  if [ -n "$oid" ]; then
    c=$(ghj api "repos/$REPO/actions/runs?event=merge_group&head_sha=$oid&per_page=1" -q .total_count) || return 0
    [ "$c" = 0 ] || return 0
  fi
  st_set "$n" queue_kick="$head"
  mut gh api graphql -f id="$id" -f query='mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { clientMutationId } }' >/dev/null ||
    { log "#$n PR #$pr: its merge group has no runs, and the dequeue failed; MERGE_WAIT_MIN still applies"; return 0; }
  if ! mut_out gh api graphql -f id="$id" -f query='mutation($id: ID!) { enqueuePullRequest(input: {pullRequestId: $id}) { clientMutationId } }'; then
    needs_you "$n" "PR #$pr was dequeued to restart its merge group, but could not be enqueued again; add it to the merge queue by hand. gh: $(oneline 300 "$MUT_OUT")"
    return 0
  fi
  log "#$n PR #$pr: the merge queue started no merge_group run in ${NO_CHECKS_MIN:-10} min; dequeued and enqueued again"
}
