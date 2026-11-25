# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# lib/canccu-stateformat.sh — the format of a project's state/ and steps/ files and its migrations
# (docs/reference/state.md, "The state format"). Sourced by lib/canccu-common.sh.

# state.format holds the format of state/ and steps/ (a missing file: 0, a release before it).
# A release that adds or changes a state field raises STATE_FORMAT and adds state_migrate_<new>,
# which prints what it did (docs/reference/state.md).
STATE_FORMAT=5
state_migrate_1() { echo "no field changes (the format file is new)"; }
# 2: owner (who a waiting unit is for), ev_id and idle_ev (its open feed lines; none before)
state_migrate_2() {
  local k n=0
  for k in $(managed); do
    case $(st_get "$k" phase) in
      accept) _st_put "$k" owner="$(owner_of "$k" accept)" || return 1; n=$((n + 1)) ;;
      needs-you) _st_put "$k" owner="$(owner_of "$k" "$(ny_item_kind "$k")")" || return 1; n=$((n + 1)) ;;
    esac
  done
  echo "the owner of $n waiting unit(s) set"
}
# 3: workflow v2 (#216): review_asked, nb_sha, plan_lines, light; the step fields deep*, polish,
# round*, cadence_at. Empty means the behaviour before them, so no file changes; the number still
# moves, so a release before them refuses this state instead of dropping fields it does not know.
state_migrate_3() { echo "no field changes (workflow v2's new fields start empty)"; }
# 4: the step field round_from (the head of the last cadence round whose report merged); empty
# means a fresh base each round
state_migrate_4() { echo "no field changes (round_from starts empty)"; }
# 5 (#277): 0.3 turned the step deep review and the health pass on by default, so a step that was
# done before the upgrade looked overdue and the first pass started both. The migration reads no
# GitHub data: it marks pre5=1 on each step that is idle or health-due, has had neither (their
# fields are empty), is in no cadence round and has no unit of its own. step_tick decides on the
# step's issues (pre5_tick): none open, work done: the step's end passes are skipped and it goes
# on to its checkpoint; open work: the marker is dropped, the step is not finished.
state_migrate_5() {
  local f m n=0 k owned
  owned=" $(for k in $(managed); do st_get "$k" step; done | tr '\n' ' ') "
  for f in "$CANCCU_HOME"/steps/*; do
    m=${f##*/}
    [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] || continue
    case $(step_get "$m" phase) in idle|health-due) ;; *) continue ;; esac
    [ -z "$(step_get "$m" deep)$(step_get "$m" health)$(step_get "$m" round_phase)" ] || continue
    [[ $owned == *" $m "* ]] && continue
    step_set "$m" pre5=1 || return 1
    n=$((n + 1))
  done
  echo "$n step(s) that may be finished marked (pre5); their end passes are decided from their issues"
}
# pre5_tick <m>: a step marked by state_migrate_5. Current with no open work and work done: it was
# finished before the upgrade, so no deep review or health pass is owed and its checkpoint (or
# its end) follows. Open work: it is not finished, the marker goes and its end passes stay owed.
pre5_tick() {
  local m=$1
  [ "$(step_get "$m" pre5)" = 1 ] || return 0
  if (( $(cur "$m" .work_open) > 0 )); then step_set "$m" pre5=; return 0; fi
  (( $(cur "$m" .work_closed) > 0 )) || return 0
  case $(step_get "$m" phase) in idle|health-due) ;; *) step_set "$m" pre5=; return 0 ;; esac
  step_set "$m" pre5= deep=skipped health=skipped phase=health
  log "step $(step_title "$m"): finished before the upgrade; no deep review or health pass owed"
}
# state_migrate: run by canccu-dispatch under its lock before the first pass. An older release
# after a newer one would misread fields it does not know: it stops instead. Under --dry-run the
# migrations run in memory (every write goes through _st_put or step_set, so into DRY_ST): the
# pass after them shows what the first real pass would do. Not in $(…), which would lose DRY_ST.
state_migrate() {
  local f="$CANCCU_HOME/state.format" v=0 what
  if [ -e "$f" ]; then
    v=$(tr -d '[:space:]' < "$f")
    [[ $v =~ ^[0-9]+$ ]] || die "state format file ${f/#$HOME/\~} holds '$v', not a number"
  fi
  (( v > STATE_FORMAT )) && die "state format $v is newer than this release knows ($STATE_FORMAT); install a newer release"
  while (( v < STATE_FORMAT )); do
    if (( CANCCU_DRY )); then
      echo "  would: migrate the state format $v → $((v + 1))"
      "state_migrate_$((v + 1))" > /dev/null || die "state format $v → $((v + 1)) failed; the state stays at format $v"
      v=$((v + 1)); continue
    fi
    what=$("state_migrate_$((v + 1))") || die "state format $v → $((v + 1)) failed; the state stays at format $v"
    # the number is written after each step: a migration that dies later starts from there
    echo "$((v + 1))" > "$f.tmp" && mv -f "$f.tmp" "$f" || die "cannot write ${f/#$HOME/\~}"
    log "state format $v → $((v + 1)): $what"
    v=$((v + 1))
  done
}
