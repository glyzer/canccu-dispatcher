# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by canccu-dispatch after canccu-common.sh; never run: the dispatcher pass, steps 5 (accept, merging) and 6 (after merge).

# ---------------------------------------------------------------- 5. accept

# pr_gone <n> <pr>: the PR left the open list while the issue is open. The health pass's PR:
# health_pr_closed (a close) or finish_unit (a merge) takes it from here. A merged plan-only PR:
# plan_back. Another merged one: finish_unit, once GitHub closes the issue.
pr_gone() {
  local j
  is_health "$1" && return 0
  j=$(ghj pr view "$2" -R "$REPO" --json state,body,closingIssuesReferences) || return 0
  case $(jqr .state <<<"$j") in
    CLOSED) needs_you "$1" "PR #$2 was closed without merging" ;;
    MERGED) plan_pr_merged "$1" "$j" && plan_back "$1" "$2" ;;
  esac
  return 0
}

# plan_pr_merged <K> <pr view json>: a merged PR that closes none of the unit's issues and says it
# is a plan ("Plan for #n", or Tier: plan): the plan is on main, the issues stay open for the build
plan_pr_merged() {
  local m
  { [ -n "$(jqr "$PR_ISSUES_JQ"' plan_for[]' <<<"$2")" ] || is_plan_body "$(jqr '.body // ""' <<<"$2")"; } || return 1
  for m in $(members_of "$1"); do
    [ "$(jqr --argjson m "$m" 'any(.closingIssuesReferences[]?; .number == $m)' <<<"$2")" = true ] && return 1
  done
  return 0
}

# plan_back <K> <pr>: the unit's plan-only PR merged. The unit goes back to the queue as the lead
# did by hand: no longer managed, its worktree, branch and session gone (a fresh start), its
# issues `ready` and `plan-ok` (the start sets plan_ok and executes the plan) and no longer
# in-progress, needs-you or awaiting-accept.
plan_back() {
  local k=$1 pr=$2 m l r
  unit_cleanup "$k" "$pr"
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
  pr_has_label "$pr" accepted && mut gh pr edit "$pr" -R "$REPO" --remove-label accepted
  has_label "$n" awaiting-accept && edit_issue "$n" --remove-label awaiting-accept
  st_set "$n" phase=check check_at="$(now)" merge_mode=
  case $(st_get "$n" stage) in
    fixing|fixcheck) log "#$n PR #$pr: $3; \`accepted\` dropped, the fix-check is void: fix-check again" ;;
    *) log "#$n PR #$pr: $3; \`accepted\` dropped, review again" ;;
  esac
}

# accepted_by_user <pr> <since epoch>: the newest `accepted` label event on the PR is by USER_LOGIN
# (never the reviewer bot) and came after the accept request
accepted_by_user() { label_by_user "$1" accepted "${2:-0}"; }

accept_step() {
  local n=$1 pr head
  pr=$(st_get "$n" pr)
  pr_is_open "$pr" || { pr_gone "$n" "$pr"; return; }
  head=$(pr_get "$pr" .headRefOid)
  if [ "$head" != "$(st_get "$n" accept_sha)" ]; then requeue "$n" "$pr" "new push since the classification"; return; fi
  pr_has_label "$pr" accepted || return 0
  if accepted_by_user "$pr" "$(st_get "$n" accept_at)"; then merge_auto "$n" "$pr" accepted "$head"
  else warn_once "accept-$pr" "#$n PR #$pr: \`accepted\` was not added by $USER_LOGIN after the accept request; ignored"; fi
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
    j=$(ghj pr view "$pr" -R "$REPO" --json state,body,closingIssuesReferences 2>/dev/null)
    if [ "$(jqr '.state // ""' <<<"$j" 2>/dev/null)" = MERGED ]; then
      if plan_pr_merged "$n" "$j"; then plan_back "$n" "$pr"
      else st_set "$n" merge_mode=merged merge_at="$(now)"; log "#$n PR #$pr: merged (auto-merge is off because it is done)"; fi
      return 0
    fi
    needs_you "$n" "auto-merge was disabled or the merge queue rejected PR #$pr"
  fi
  return 0
}

# ---------------------------------------------------------------- 6. after merge

# advance <n>: issues n blocked that carry the dispatcher's own `blocked` and have no open
# blocker left → unblocked
advance() {
  local n=$1 d deps
  deps=$( { ghj api "repos/$REPO/issues/$n/dependencies/blocking" 2>/dev/null | jqr '.[] | select(.state == "open") | .number'
            jqr --argjson n "$n" '.[] | select((.body // "") | split("\n") | any(test("blocked by"; "i") and test("#\($n)\\b"))) | .number' <<<"$ISSUES"
          } | sort -un)
  for d in $deps; do
    has_label "$d" blocked && blocked_ours "$d" || continue
    [ -z "$(blockers_open "$d" | grep -vx "$n")" ] || continue
    unblock "$d"
  done
}

# unblock <n>: the dispatcher's own `blocked` goes; an issue nobody manages gets `ready` for it
unblock() {
  local n=$1 r=()
  is_managed "$(unit_of_issue "$n")" || r=(--add-label ready)
  mut gh issue edit "$n" -R "$REPO" --remove-label blocked "${r[@]}" || return 1
  blocked_unmark "$n"
  ISSUES=$(jq -c --argjson n "$n" --argjson r "${#r[@]}" 'map(if .number == $n then .labels |= (map(select(.name != "blocked" and .name != "ready"))
    + (if $r > 0 then [{name: "ready"}] else [] end)) else . end)' <<<"$ISSUES")
  log "#$n unblocked: blocked$( (( ${#r[@]} )) && echo " → ready")"
}

# unblock_tick: each open issue with the dispatcher's own `blocked` (a quiet wait's) whose
# blocked-by links (the dependencies API and its "Blocked by #k" lines) are all closed is
# unblocked, whatever closed them: a merge (advance does that too, at once), the dispatcher
# closing an epic, the lead closing a checkpoint, a hand. A `blocked` someone else set is theirs
# to lift: never removed, whatever its links say. An issue with no link keeps the label. A link
# that cannot be read (an API error, a body link off the capped open list whose state gh cannot
# tell) keeps it blocked this pass. This pass's issue list takes the new labels (unblock), so the
# start, a step's planner and the resume see it unblocked now.
unblock_tick() {
  local n api b links
  for n in $(jqr '.[] | select(any(.labels[]; .name == "blocked")) | .number' <<<"$ISSUES"); do
    blocked_ours "$n" || continue
    api=$(ghj api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>/dev/null) || continue
    [ "$(jqr 'any(.[]; .state != "closed")' <<<"$api")" = false ] || continue
    links=$(jqr 'length' <<<"$api")
    for b in $(blocked_by_refs "$n"); do
      is_open "$b" && continue 2
      [ "$(ghj issue view "$b" -R "$REPO" --json state 2>/dev/null | jqr '.state // empty')" = CLOSED ] || continue 2
      links=$((links + 1))
    done
    (( links > 0 )) || continue
    unblock "$n"
  done
  return 0
}

# close_epics <n>: an open epic (n's parent, or one whose Order: line names n) with every sub-issue closed
close_epics() {
  local n=$1 e subs
  for e in $( { ghj api "repos/$REPO/issues/$n/parent" 2>/dev/null | jqr '.number // empty'
                jqr --argjson n "$n" '.[] | select(any(.labels[]; .name == "epic"))
                  | select((.body // "") | split("\n") | any(test("^\\s*\\**Order:") and test("#\($n)\\b"))) | .number' <<<"$ISSUES"
              } | sort -un); do
    is_open "$e" && has_label "$e" epic || continue
    step_holds_epic "$e" && continue   # a step's epic closes with its step (close_step_epic)
    subs=$(ghj api --paginate "repos/$REPO/issues/$e/sub_issues" | jqr '.[] | "\(.number) \(.state)"') || continue
    [ -n "$subs" ] || continue
    subs=$(grep -v "^$n " <<<"$subs")   # n itself is closed even if the API lags
    grep -q ' open$' <<<"$subs" && continue
    mut gh issue close "$e" -R "$REPO" --comment "All sub-issues are closed. $CANCCU_MARK" && log "epic #$e closed"
  done
}

# unit_cleanup <K> <pr>: a unit whose PR merged leaves nothing behind: its worktree and branch,
# the PR's review worktree, its session id and question
unit_cleanup() {
  local n=$1 pr=$2 wt br
  wt=$(unit_wt "$n")
  if [ -e "$wt/.git" ]; then
    br=$(guard 10 git -C "$wt" branch --show-current)
    mut git -C "$CLONE" worktree remove --force "$wt"
    [ -n "$br" ] && mut git -C "$CLONE" branch -D "$br"
  fi
  [ -e "$(review_wt "$pr")/.git" ] && mut git -C "$CLONE" worktree remove --force "$(review_wt "$pr")"
  mut rm -f "$WORKERS_DIR/$REPO_NAME-$n.id" "$(qfile "$n")"
}

# finish_unit <K>: a managed unit is closed: an issue; a package with every issue closed; the
# health pass with its PR merged (or nothing to do)
finish_unit() {
  local n=$1 pr how state=none j l m lbls="" title="" body=""
  # the open list is capped, so confirm before cleaning up
  for m in $(members_of "$n"); do
    j=$(ghj issue view "$m" -R "$REPO" --json state,labels) || { log "#$n: gh error reading issue #$m; retrying next pass"; return; }
    [ "$(jqr .state <<<"$j")" = CLOSED ] || { log "#$n: #$m is open but missing from the issue list; skipped"; return; }
    lbls+="$m $(jqr '[.labels[].name] | join(" ")' <<<"$j")"$'\n'
  done
  pr=$(st_get "$n" pr); how=$(st_get "$n" how)
  if [ -n "$pr" ]; then
    j=$(ghj pr view "$pr" -R "$REPO" --json state,title,body) || { log "#$n: gh error reading PR #$pr; retrying next pass"; return; }
    state=$(jqr .state <<<"$j"); title=$(jqr .title <<<"$j"); body=$(jqr '.body // ""' <<<"$j")
  fi
  if [ "$state" = MERGED ]; then
    (( CANCCU_DRY )) || printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$n" "$pr" "${how:-by hand}" "$title" >> "$CANCCU_HOME/merged.log"
    log "#$n merged (PR #$pr, ${how:-by hand})"
    unit_cleanup "$n" "$pr"
    [ "$(guard 10 git -C "$CLONE" branch --show-current)" = main ] && { mut git -C "$CLONE" pull -q --ff-only || log "git pull in $CLONE failed"; }
    for m in $(members_of "$n"); do advance "$m"; close_epics "$m"; done
  else
    log "#$n closed without a merged PR; its worktree is kept"
    mut rm -f "$(qfile "$n")"
  fi
  is_health "$n" && health_labels_clear "$n"
  step_unit_finished "$n" "$state" "$pr" "$body"
  while read -r m l; do
    [ -n "$m" ] || continue
    for l in in-progress awaiting-accept needs-you; do
      grep -qw -- "$l" <<<"$(grep "^$m " <<<"$lbls")" && mut gh issue edit "$m" -R "$REPO" --remove-label "$l"
    done
  done <<<"$lbls"
  st_rm "$n"
}
