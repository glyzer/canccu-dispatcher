# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by canccu-steps.sh; never run: a step's health pass, closing checkpoint and end, and step_tick, which drives every phase of a step.

# ---------------------------------------------------------------- health pass and checkpoint

# health_due <m>: every work issue of the step is closed, some work was done, no health pass yet
health_due() {
  [ "$(cur "$1" .work_open)" = 0 ] && (( $(cur "$1" .work_closed) > 0 )) && [ -z "$(step_get "$1" health)" ] &&
    [ -z "$(step_get "$1" round_phase)" ]   # a cadence round in progress ends first
}
# label_by_user <issue|pr> <label> <since epoch>: its newest such label event is USER_LOGIN's, after then
label_by_user() {
  local e; e=$(ghj api --paginate "repos/$REPO/issues/$1/events" |
    jqr -s --arg l "$2" '[.[][] | select(.event == "labeled" and .label.name == $l)] | last
      | select(. != null) | "\(.actor.login // "") \(.created_at)"') || return 1
  [ -n "$e" ] && [ "${e%% *}" = "$USER_LOGIN" ] && [ "${e%% *}" != "$REVIEWER_LOGIN" ] &&
    [[ ${e#* } > "$(iso "${3:-0}")" ]]
}
# checkpoint_summary <m>: the checkpoint comment
checkpoint_summary() {
  local m=$1 sp nc
  read -r sp nc <<<"$(step_spend "$m")"
  printf '**Checkpoint** for step %s (canccu-dispatch)\n\n**Packages**\n' "$(step_title "$m")"
  local k nm w is rk pr out
  while IFS=$'\t' read -r k nm w is rk pr out; do
    [ -n "$k" ] && printf -- '- %s (%s risk): %s · PR #%s · %s\n' "$nm" "$rk" "$(sed -E 's/([0-9]+)/#\1/g; s/ /, /g' <<<"$is")" "$pr" "$out"
  done < "$CANCCU_HOME/steps/$m.packages" 2>/dev/null
  printf '\n**Health pass:** %s\n\n**Spend:** $%s of STEP_BUDGET $%s%s\n\n' \
    "$(case $(step_get "$m" health) in skipped) echo "nothing to do" ;; closed) echo "PR #$(step_get "$m" health_pr) closed without merging" ;;
         *) echo "PR #$(step_get "$m" health_pr)" ;; esac)" \
    "$sp" "$STEP_BUDGET" "$( (( nc > 0 )) && echo " (+$nc runs without a reported cost)")"
  deep_summary "$m"
  printf '**Roadmap notes**\n%s\n\n**Follow-ups**\n%s\n\n' \
    "$(awk -F '\t' '$2 == "roadmap" { printf "- %s (PR #%s)\n", $4, $3 }' "$CANCCU_HOME/steps/$m.notes" 2>/dev/null | grep . || echo none)" \
    "$(awk -F '\t' '$2 == "follow-up" { printf "- %s (PR #%s)\n", $4, $3 }' "$CANCCU_HOME/steps/$m.notes" 2>/dev/null | grep . || echo none)"
  echo "Label this issue \`checkpoint-ok\` or close it to start the next step."
}
# health_labels_clear <K>: the health pass is finished. Its labels live on the step's issue
# (lead_of): awaiting-accept is only ever its own; its needs-you goes unless the step has a cause
# of its own (step_ny_clear) or it is the checkpoint waiting for checkpoint-ok.
health_labels_clear() {
  local k=$1 m i; m=$(st_get "$k" step) i=$(lead_of "$k")
  [ -n "$i" ] || return 0
  has_label "$i" awaiting-accept && edit_issue "$k" --remove-label awaiting-accept
  [ "$(st_get "$k" phase)" = needs-you ] || return 0
  [ "$(step_get "$m" phase)" = checkpoint ] && [ "$i" = "$(step_get "$m" checkpoint)" ] && return 0
  step_ny_clear "$m"
}
# health_pr_closed <m>: the health pass's PR was closed without merging: the health pass ends
# (closed), its unit is finished, and the checkpoint follows; the lead decides there
health_pr_closed() {
  local m=$1 k="pkg-$1-health" pr st
  is_managed "$k" && [ "$(step_get "$m" health)" = running ] || return 0
  pr=$(st_get "$k" pr); [ -n "$pr" ] && ! pr_is_open "$pr" || return 0
  st=$(ghj pr view "$pr" -R "$REPO" --json state -q .state) || return 0
  [ "$st" = CLOSED ] || return 0
  step_set "$m" health=closed health_pr="$pr"; st_set "$k" skipped=1
  log "#$k: PR #$pr was closed without merging; the health pass ends and the checkpoint follows"
  step_ny_clear "$m"
}
# waiting_checkpoints: "<issue> <m>" for each step m that waits for checkpoint-ok on its checkpoint
waiting_checkpoints() {
  local f m c
  for f in "$CANCCU_HOME"/steps/*; do
    m=${f##*/}; [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] && [ "$(step_get "$m" phase)" = checkpoint ] || continue
    c=$(step_get "$m" checkpoint); [ -n "$c" ] && echo "$c $m"
  done
  return 0
}
# checkpoint_tick <m>: after the health pass: needs-you and the summary on the checkpoint; then wait
# for checkpoint-ok (the user's label) or its close
checkpoint_tick() {
  local m=$1 c st ph u; c=$(cur "$m" '.checkpoint.issue // empty'); st=$(cur "$m" '.checkpoint.state // empty')
  ph=$(step_get "$m" phase)
  if [ "$ph" = health ]; then
    health_pr_closed "$m"
    case $(step_get "$m" health) in merged|skipped|closed) ;; *) return 0 ;; esac
    if [ -z "$c" ] || [ "$st" = closed ]; then step_done "$m" "it has no open checkpoint, so it skips the checkpoint pause"; return 0; fi
    edit_issue "$c" --add-label needs-you
    # the summary's link: the monitor's needs-you item and this line end with it
    comment_issue_url "$c" "$(checkpoint_summary "$m")"; u=$COMMENT_URL
    step_set "$m" phase=checkpoint checkpoint_at="$(now)" checkpoint_url="$u"
    log "step $(step_title "$m"): checkpoint #$c waits for checkpoint-ok$(its_url "${u:-$(issue_url "$c")}")"
    feed_open "checkpoint-$m" po ask checkpoint - - "${u:-$(issue_url "$c")}" "step $(step_title "$m"): checkpoint #$c waits for checkpoint-ok"; return 0
  fi
  [ "$ph" = checkpoint ] || return 0
  [ -n "$c" ] || { step_done "$m" "its checkpoint is gone, so the pause ends"; return 0; }
  if [ "$st" != closed ]; then
    jqr --argjson c "$c" '.[] | select(.number == $c) | .labels[].name' <<<"$CHECKPOINTS" | grep -qx checkpoint-ok || return 0
    label_by_user "$c" checkpoint-ok "$(step_get "$m" checkpoint_at)" ||
      { warn_once "cpok-$c" "step $(step_title "$m"): checkpoint-ok on #$c was not added by $USER_LOGIN after the summary; ignored"; return 0; }
    # the step is done only once the close went through: else the next pass tries again
    mut gh issue close "$c" -R "$REPO" --comment "Checkpoint OK: step $(step_title "$m") is done. $CANCCU_MARK" ||
      { log "step $(step_title "$m"): closing checkpoint #$c failed; retrying next pass"; return 0; }
  fi
  mut gh issue edit "$c" -R "$REPO" --remove-label needs-you
  step_done "$m" "checkpoint #$c OK"
  local t; t=$(step_tag_name "$m") && step_tag "$m" "$t"
}
# step_done <m> <why>: the step is done (done_at: from now on, new open work or an open
# checkpoint in it is the lead's, see step_stop_reason); its epic closes when its sub-issues are;
# its planner's worktree goes
step_done() {
  local wt; wt=$(plan_wt "$1")
  step_set "$1" phase=done done_at="$(now)"
  log "step $(step_title "$1") is done: $2"
  feed_settle "checkpoint-$1" "done"
  feed - info step-done - - - "step $(step_title "$1") is done: $2" >/dev/null
  [ -e "$wt" ] && { mut git -C "$CLONE" worktree remove --force "$wt" || log "step $1: cannot remove the planner worktree $wt"; }
  close_step_epic "$1"
}
# close_step_epic <m>: close the step's epic once its step is done and every sub-issue is closed
# (close_epics leaves a step's epic open until then: it is where the step talks to the lead)
close_step_epic() {
  local e subs; e=$(step_get "$1" epic)
  [ -n "$e" ] && _issue_open "$e" || return 0
  subs=$(ghj api --paginate "repos/$REPO/issues/$e/sub_issues" | jqr '.[] | .state') || return 0
  [ -n "$subs" ] && ! grep -qx open <<<"$subs" || return 0
  mut gh issue close "$e" -R "$REPO" --comment "Step $(step_title "$1") is done. $CANCCU_MARK" && log "epic #$e closed"
}
# step_holds_epic <n>: the issue is the epic of a step that is not done
step_holds_epic() {
  local f m
  for f in "$CANCCU_HOME"/steps/*; do
    m=${f##*/}; [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] || continue
    [ "$(step_get "$m" epic)" = "$1" ] && [ "$(step_get "$m" phase)" != "done" ] && return 0
  done
  return 1
}
# step_stop_reason <m>: what the dispatcher does not handle on its own, for the lead: an open
# checkpoint or new open work after the step was done, its epic closed while it runs. Nothing when
# there is none. A finished package's issue open again is not one: like any issue of the step, the
# planner takes it with `ready` (merged_left leaves one with needs-you until a person looked).
step_stop_reason() {
  local m=$1 c e
  if [ -n "$(step_get "$m" done_at)" ]; then
    c=$(cur "$m" 'select(.checkpoint.state == "open") | .checkpoint.issue')
    [ -n "$c" ] && { echo "checkpoint #$c is open again, but the step was done"; return 0; }
    if (( $(cur "$m" .work_open) > 0 )); then
      echo "the step was done and has new open work: $(step_open_work "$m")"
      return 0
    fi
  fi
  e=$(step_get "$m" epic)
  [ -n "$e" ] && [ "$(step_get "$m" phase)" != "done" ] && ! _issue_open "$e" && echo "its epic #$e is closed while the step runs"
  return 0
}

# step_open_work <m>: its open work issues, "#a, #b"
step_open_work() {
  jqr --arg t "$(step_title "$1")" '[.[] | select((.milestone.title // null) == $t)
    | select([.labels[].name] | (index("epic") or index("checkpoint") or index("follow-up")) | not) | "#\(.number)"] | join(", ")' <<<"$ISSUES"
}
# checkpoint_back <m>: the checkpoint's "not yet, polish these first" is new work in the step
# (#243), which must not wait for the checkpoint-ok it is meant to earn: the step plans it like
# any, and once it is closed the health pass and the checkpoint come again, with a fresh summary.
# The deep review is not redone: the polish is what it asked for.
checkpoint_back() {
  local m=$1 c; c=$(cur "$m" '.checkpoint.issue // empty')
  [ -z "$c" ] || mut gh issue edit "$c" -R "$REPO" --remove-label needs-you || true
  step_set "$m" phase=idle health= health_pr= checkpoint_at= checkpoint_url=
  feed_settle "checkpoint-$m" "new work"
  log "step $(step_title "$m"): new open work at its checkpoint ($(step_open_work "$m")); back to planning"
}

# ---------------------------------------------------------------- one step, once per pass

# step_tick <m> <may start 0|1>: the step's bookkeeping, then its planner or health pass if due
step_tick() {
  local m=$1 go=${2:-1} ph
  local r
  step_init "$m"
  # what the dispatcher does not handle on its own stops the step: nothing starts for it, the
  # lead is asked (needs-you, one line); once it is gone the step goes on where it was
  r=$(step_stop_reason "$m")
  if [ -n "$r" ]; then
    [ "$(step_get "$m" ny_kind)" = stop ] && [ "$(step_get "$m" ny_reason)" = "$(oneline 300 "$r")" ] ||
      step_needs_you "$m" "$r" stop
    return 0
  fi
  if [ "$(step_get "$m" phase)" = needs-you ] && [ "$(step_get "$m" ny_kind)" = stop ]; then
    r=$(step_get "$m" ny_from); step_set "$m" phase="${r:-needs-you}" ny_kind= ny_from=
    # back to the plan's needs-you (it failed during the stop): its reason; else none
    [ -n "$r" ] && step_set "$m" ny_reason="$(step_get "$m" ny_next)" ny_next=
    log "step $(step_title "$m"): the stop is resolved; it goes on"; step_ny_clear "$m"
  fi
  pre5_tick "$m"
  xblock_tick "$m"; budget_tick "$m"; notes_tick "$m"; cadence_tick "$m" "$go"
  ph=$(step_get "$m" phase)
  case $ph in
    needs-you) plan_retry "$m" ;;
    running)
      if wave_over "$m"; then step_set "$m" phase=idle; log "step $(step_title "$m"): wave $(step_get "$m" wave) is over"
      elif wave_rolls "$m"; then step_set "$m" phase=idle; log "step $(step_title "$m"): wave $(step_get "$m" wave) rolls on; planning the next one"; fi ;;
    # an accept that came after the wave was over lets a dependant start: the wave goes on
    idle) wave_can_start "$m" && { step_set "$m" phase=running; log "step $(step_title "$m"): wave $(step_get "$m" wave) goes on"; } ;;
    # a polish issue filed just now is not in this pass's snapshot (work_open 0): the health
    # pass would start with it open, so the step waits for the next pass's snapshot
    deep) deep_tick "$m"; [ "$(step_get "$m" phase)" = idle ] && return 0 ;;
    checkpoint) if (( $(cur "$m" .work_open) > 0 )); then checkpoint_back "$m"; else checkpoint_tick "$m"; fi ;;
    health) checkpoint_tick "$m" ;;
  esac
  ph=$(step_get "$m" phase)
  # every work issue closed: the step stays current (health-due) until its health pass starts
  [ "$ph" = idle ] && health_due "$m" && { step_set "$m" phase=health-due; ph=health-due; }
  case $ph in idle|planning|health-due) ;; *) return 0 ;; esac
  [ "$ph" = planning ] && [ -n "$(step_get "$m" planner_started)" ] && return 0
  (( go )) || return 0
  if health_due "$m"; then if deep_due "$m"; then start_deep "$m"; else start_health "$m"; fi
  else start_planner "$m" || { [ "$ph" = planning ] && [ -z "$(planner_issues "$1" | head -1)" ] && step_set "$m" phase=idle; }; fi
  return 0
}
