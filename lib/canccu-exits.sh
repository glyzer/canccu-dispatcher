# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by lib/canccu-pipeline.sh: what reap_worker does with a run that stopped blocked, was
# denied commands, or crashed or was killed (one fresh retry with the handoff).

# a unit in phase starting whose run is not alive yet: the engine may still be starting it (a
# canccu-run beside the pass), so the reap waits this long before it calls the start killed
STARTING_GRACE=60

# denied_ok <K> <pr or empty>: a done run whose message lists permission denials. True when its PR
# holds everything the run left (the PR's head is the worktree's HEAD, nothing uncommitted);
# otherwise the unit goes to needs-you with the denials, and false. No PR but a pushed branch with
# commits: dispatcher_pr opens it first.
denied_ok() {
  local n=$1 p=$2 den wt wh="" ph st k="?"
  den=$(run_msg "$n" | sed -n '/^Permission denials (information):$/,$p' | tail -n +2)
  DPR_BODY=""
  # a PR opened after this pass read the list
  [ -n "$p" ] || { fetch_prs && p=$(pr_for "$n"); }
  # its branch pushed with commits: the dispatcher opens the PR the run could not (#237)
  [ -n "$p" ] || { dispatcher_pr "$n" "$den" && p=$(pr_for "$n"); }
  if [ -z "$p" ]; then needs_you "$n" "the worker's run was denied commands and opened no PR" "$den"; return 1; fi
  ph=$(pr_get "$p" .headRefOid)
  wt=$(unit_wt "$n")
  # a worktree that is gone or unreadable proves nothing: a mismatch
  if [ -d "$wt" ]; then
    wh=$(guard 20 git -C "$wt" rev-parse HEAD 2>/dev/null)
    # the PR body file dispatcher_pr read is the run's scratch, not work the PR lacks
    st=$(guard 20 git -C "$wt" status --porcelain 2>/dev/null) &&
      k=$(printf '%s' "$st" | grep -vxF "?? ${DPR_BODY:-/}" | grep -c . || true)
  fi
  [ -n "$wh" ] && [ "$wh" = "$ph" ] && [ "$k" = 0 ] && return 0
  [ -n "$wh" ] || wh=gone
  needs_you "$n" "the worker's run was denied commands and left work its PR does not have (worktree ${wh:0:7}, PR ${ph:0:7}, $k uncommitted files)" "$den"
  return 1
}

# crash_retry <K> <status>: a crashed, stalled or killed run gets CRASH_RETRY fresh runs with its
# handoff, never its own session again (the session that crashed is the likely cause). True when
# it parked the unit in phase retry, where resume_step starts the run once a slot is free.
crash_retry() {
  local n=$1 t; t=$(st_get "$n" crash_tries); [[ $t =~ ^[0-9]+$ ]] || t=0
  (( t < ${CRASH_RETRY:-1} )) || return 1
  t=$((t + 1))
  st_set "$n" phase=retry crash_tries="$t" retry_status="$(oneline 200 "$2")" prev_phase=
  log "#$n the worker stopped ($2); one fresh run with the handoff (try $t of ${CRASH_RETRY:-1})"
}
crash_task() {
  echo "Your earlier run ended without finishing ($(st_get "$1" retry_status)). Continue the task from where the branch and this handoff leave it."
}

# wait_blocked <K> <what it waits on>: a worker stopped blocked or not started, with no PR: a quiet
# wait (phase waiting), never needs-you or the answerer, even when it also asked a question. The
# lead issue gets `blocked`, marked as the dispatcher's (unblock_tick lifts it once its blocked-by
# links close); a label already there is the user's. resume_step resumes it once the label goes.
wait_blocked() {
  local n=$1 l; l=$(lead_of "$1")
  if ! unit_blocked "$n"; then
    # without the label nothing would hold it: the next pass would resume it at once
    edit_issue "$n" --add-label blocked || { log "#$n stopped blocked; adding \`blocked\` failed, again next pass"; return 0; }
    blocked_mark "$l"
    # this pass's list too, or resume_step would see it unblocked and resume it at once
    ISSUES=$(jq -c --argjson n "$l" 'map(if .number == $n then .labels += [{name: "blocked"}] else . end)' <<<"$ISSUES")
  fi
  st_set "$n" phase=waiting reason="$(oneline 200 "$2")"
  log "#$n waits (no PR): $(oneline 120 "$2")"
}

# dispatcher_pr <K> [denials]: a worker run ended with its branch pushed, commits ahead of
# origin/BASE_BRANCH and no PR (its gh pr create was denied, #237): the dispatcher opens the PR
# and the pipeline goes on with it. The body: the file the denied gh pr create named with
# --body-file, if it resolves inside the unit's worktree (no other path is read), else built from
# the issue (Closes lines, the run's Testing: and Revert: lines). True when the PR is open and found.
# DPR_BODY: the body file's path in the worktree (denied_ok does not count it as uncommitted).
dispatcher_pr() {
  local n=$1 wt br ahead f="" body c t p pk draft=""
  DPR_BODY=""
  is_step_run "$n" && return 1
  wt=$(unit_wt "$n"); [ -e "$wt/.git" ] || return 1
  br=$(guard 20 git -C "$wt" branch --show-current 2>/dev/null); [ -n "$br" ] || br=$(unit_branch "$n")
  # the branch pr_for finds for the unit, and nothing else
  if is_pkg "$n"; then [ "$br" = "$(unit_branch "$n")" ] || return 1; else [[ $br =~ ^(issue-)?$n(-|$) ]] || return 1; fi
  guard 60 git -C "$wt" fetch -q origin "$BASE_BRANCH" "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null || return 1
  ahead=$(guard 20 git -C "$wt" rev-list --count "origin/$BASE_BRANCH..origin/$br" 2>/dev/null)
  [[ $ahead =~ ^[1-9][0-9]*$ ]] || return 1
  c=$(grep -m1 -E '(^|[[:space:]])gh pr create([[:space:]]|$)' <<<"${2:-}")
  [[ $c == *" --draft"* ]] && draft=--draft
  if [[ $c =~ --body-file[=[:space:]]+([^[:space:]]+) ]]; then
    f=${BASH_REMATCH[1]//[\"\']/}; [[ $f == /* ]] || f=$wt/$f
    f=$(realpath -e -- "$f" 2>/dev/null) && [[ $f == "$(realpath -e -- "$wt")"/* ]] && [ -f "$f" ] || f=""
  fi
  if [ -n "$f" ]; then body=$(head -c 60000 "$f"); DPR_BODY=${f#"$(realpath -e -- "$wt")"/}
  else
    body=$(members_of "$n" | sed 's/^/Closes #/'); pk=$(st_get "$n" pkg)
    [ -n "$pk" ] && body+=$'\n\n'"Package: $pk"
    t=$(run_msg "$n" | grep -E '^[[:space:]*_-]*(Testing|Revert):' | sed -E 's/^[[:space:]*_-]+//' | head -2)
    [ -n "$t" ] && body+=$'\n\n'"$t"
  fi
  body+=$'\n\n'"The dispatcher opened this PR: the worker pushed \`$br\` but did not open it${c:+ (its \`gh pr create\` was denied)}. $CANCCU_MARK"
  mut gh pr create -R "$REPO" --base "$BASE_BRANCH" --head "$br" --title "$(title_of "$n")" --body "$body" $draft >/dev/null ||
    { log "#$n the worker pushed $br without a PR; opening it failed"; return 1; }
  fetch_prs && p=$(pr_for "$n") && [ -n "$p" ] || return 1
  log "#$n the worker pushed $br ($ahead commit(s)) but opened no PR; the dispatcher opened PR #$p"
}
