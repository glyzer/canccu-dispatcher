# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by canccu-dispatch after canccu-merge.sh; never run: the dispatcher pass, step 6 (after merge): what a merge unblocks and closes, and the cleanup of a merged unit.

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

# links_closed <n>: issue n's blocked-by links (the dependencies API and its "Blocked by #k" lines)
# are all closed: prints how many there are. Fails on an open link, or one that cannot be read (an
# API error, a body link off the capped open list whose state gh cannot tell).
links_closed() {
  local n=$1 api b links
  api=$(ghj api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>/dev/null) || return 1
  [ "$(jqr 'any(.[]; .state != "closed")' <<<"$api")" = false ] || return 1
  links=$(jqr 'length' <<<"$api")
  for b in $(blocked_by_refs "$n"); do
    is_open "$b" && return 1
    [ "$(ghj issue view "$b" -R "$REPO" --json state 2>/dev/null | jqr '.state // empty')" = CLOSED ] || return 1
    links=$((links + 1))
  done
  echo "$links"
}

# unblock_tick: the dispatcher's own `blocked` (a quiet wait's) goes once the blocked-by links are
# all closed, whatever closed them: a merge (advance does that too, at once), the dispatcher
# closing an epic, the lead closing a checkpoint, a hand. A package's wait is on its lead issue but
# waits on any member's links: every member's count. With no link at all the label stays. A
# `blocked` someone else set is theirs to lift: never removed (said once when its links are all
# closed). A mark whose label is gone goes too, so a person's later `blocked` is never taken for
# the dispatcher's. This pass's issue list takes the new labels (unblock).
unblock_tick() {
  local n f m c links
  for f in "$CANCCU_HOME"/blocked/*; do
    [ -e "$f" ] || continue; n=${f##*/}
    [ "$(jqr --argjson n "$n" 'any(.[]; .number == $n and all(.labels[]; .name != "blocked"))' <<<"$ISSUES")" = true ] && blocked_unmark "$n"
  done
  for n in $(jqr '.[] | select(any(.labels[]; .name == "blocked")) | .number' <<<"$ISSUES"); do
    if ! blocked_ours "$n"; then
      c=$(links_closed "$n") && (( c > 0 )) &&
        warn_once "blocked-theirs-$n" "#$n is labelled \`blocked\` by someone else and its blocked-by links are all closed: remove the label to release it"
      continue
    fi
    links=0
    for m in $(members_of "$(unit_of_issue "$n")"); do c=$(links_closed "$m") || continue 2; links=$((links + c)); done
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
  local n=$1 pr=$2 wt br m
  wt=$(unit_wt "$n")
  if [ -e "$wt/.git" ]; then
    br=$(guard 10 git -C "$wt" branch --show-current)
    mut git -C "$CLONE" worktree remove --force "$wt"
    [ -n "$br" ] && mut git -C "$CLONE" branch -D "$br"
  fi
  [ -e "$(review_wt "$pr")/.git" ] && mut git -C "$CLONE" worktree remove --force "$(review_wt "$pr")"
  mut rm -f "$WORKERS_DIR/$REPO_NAME-$n.id" "$(qfile "$n")"
  for m in $(members_of "$n"); do blocked_unmark "$m"; done
}

# unit_merged <K> <pr> <PR title> <closed member...>: the record and cleanup of a merged unit
# (finish_unit, merged_left); the closed members unblock what they blocked and close their epics
unit_merged() {
  local n=$1 pr=$2 title=$3 how m; shift 3
  how=$(st_get "$n" how)
  (( CANCCU_DRY )) || printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$n" "$pr" "${how:-by hand}" "$title" >> "$CANCCU_HOME/merged.log"
  log "#$n merged (PR #$pr, ${how:-by hand})"
  unit_cleanup "$n" "$pr"
  [ "$(guard 10 git -C "$CLONE" branch --show-current)" = main ] && { mut git -C "$CLONE" pull -q --ff-only || log "git pull in $CLONE failed"; }
  for m; do advance "$m"; close_epics "$m"; done
}

# finish_unit <K>: a managed unit is closed: an issue; a package with every issue closed; the
# health pass with its PR merged (or nothing to do)
finish_unit() {
  local n=$1 pr state=none j l m lbls="" title="" body=""
  # the open list is capped, so confirm before cleaning up
  for m in $(members_of "$n"); do
    j=$(ghj issue view "$m" -R "$REPO" --json state,labels) || { log "#$n: gh error reading issue #$m; retrying next pass"; return; }
    [ "$(jqr .state <<<"$j")" = CLOSED ] || { log "#$n: #$m is open but missing from the issue list; skipped"; return; }
    lbls+="$m $(jqr '[.labels[].name] | join(" ")' <<<"$j")"$'\n'
  done
  pr=$(st_get "$n" pr)
  if [ -n "$pr" ]; then
    j=$(ghj pr view "$pr" -R "$REPO" --json state,title,body) || { log "#$n: gh error reading PR #$pr; retrying next pass"; return; }
    state=$(jqr .state <<<"$j"); title=$(jqr .title <<<"$j"); body=$(jqr '.body // ""' <<<"$j")
  fi
  if [ "$state" = MERGED ]; then
    # shellcheck disable=SC2046  # issue numbers: one word each
    unit_merged "$n" "$pr" "$title" $(members_of "$n")
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
