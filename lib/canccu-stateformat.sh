# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# lib/canccu-stateformat.sh — the format of a project's state/ and steps/ files and its migrations
# (docs/reference/state.md, "The state format"). Sourced by lib/canccu-common.sh.

# state.format holds the format of state/ and steps/ (a missing file: 0, a release before it).
# A release that adds or changes a state field raises STATE_FORMAT and adds state_migrate_<new>,
# which prints what it did (docs/reference/state.md).
STATE_FORMAT=3
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
# 3: preview_fix (the PR whose worker was sent back once for its "What you will see" section)
state_migrate_3() { echo "no field changes (preview_fix starts empty)"; }
# state_migrate: run by canccu-dispatch under its lock before the first pass. An older release
# after a newer one would misread fields it does not know: it stops instead. Under --dry-run it
# only checks.
state_migrate() {
  local f="$CANCCU_HOME/state.format" v=0 what
  if [ -e "$f" ]; then
    v=$(tr -d '[:space:]' < "$f")
    [[ $v =~ ^[0-9]+$ ]] || die "state format file ${f/#$HOME/\~} holds '$v', not a number"
  fi
  (( v > STATE_FORMAT )) && die "state format $v is newer than this release knows ($STATE_FORMAT); install a newer release"
  while (( v < STATE_FORMAT )); do
    if (( CANCCU_DRY )); then echo "  would: migrate the state format $v → $((v + 1))"; v=$((v + 1)); continue; fi
    what=$("state_migrate_$((v + 1))") || die "state format $v → $((v + 1)) failed; the state stays at format $v"
    # the number is written after each step: a migration that dies later starts from there
    echo "$((v + 1))" > "$f.tmp" && mv -f "$f.tmp" "$f" || die "cannot write ${f/#$HOME/\~}"
    log "state format $v → $((v + 1)): $what"
    v=$((v + 1))
  done
}
