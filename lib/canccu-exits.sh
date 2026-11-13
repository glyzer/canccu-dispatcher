# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by lib/canccu-pipeline.sh: what reap_worker does with a run that stopped blocked, was
# denied commands, or crashed or was killed (one fresh retry with the handoff).

# a unit in phase starting whose run is not alive yet: the engine may still be starting it (a
# canccu-run beside the pass), so the reap waits this long before it calls the start killed
STARTING_GRACE=60

# denied_ok <K> <pr or empty>: a done run whose message lists permission denials. True when its PR
# holds everything the run left (the PR's head is the worktree's HEAD, nothing uncommitted);
# otherwise the unit goes to needs-you with the denials, and false.
denied_ok() {
  local n=$1 p=$2 den wt wh="" ph st k="?"
  den=$(run_msg "$n" | sed -n '/^Permission denials (information):$/,$p' | tail -n +2)
  # a PR opened after this pass read the list
  [ -n "$p" ] || { fetch_prs && p=$(pr_for "$n"); }
  if [ -z "$p" ]; then needs_you "$n" "the worker's run was denied commands and opened no PR" "$den"; return 1; fi
  ph=$(pr_get "$p" .headRefOid)
  wt=$(unit_wt "$n")
  # a worktree that is gone or unreadable proves nothing: a mismatch
  if [ -d "$wt" ]; then
    wh=$(guard 20 git -C "$wt" rev-parse HEAD 2>/dev/null)
    st=$(guard 20 git -C "$wt" status --porcelain 2>/dev/null) && k=$(printf '%s' "$st" | grep -c . || true)
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
