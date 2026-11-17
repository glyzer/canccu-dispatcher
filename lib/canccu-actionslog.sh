# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# lib/canccu-actionslog.sh — the actions log of docs/plan/contracts.md §7: one line in the
# project's actions.log per command a person or the leader ran. Sourced by lib/canccu-common.sh
# and lib/canccu-configcmd.sh (bin/canccu-dispatcher reads no common), never run; it needs
# nothing but CANCCU_HOME, or the homes a command names in ACT_HOMES.

# cfg_actor: who called: leader or run by the CANCCU_ACTOR marker (libexec/canccu-worker exports
# run), the product owner (po) otherwise. Not a security boundary: a process can unset it.
cfg_actor() { case ${CANCCU_ACTOR-} in leader|run) echo "$CANCCU_ACTOR" ;; *) echo po ;; esac; }

# act_track <command> [unit]: this call writes its one line when the shell exits, whichever way
# it goes: ok on status 0, else ACT_WHY (die and _cmd_die set it) or "exit <status>". ACT_UNIT
# and ACT_CMD may be changed later (the unit once it is known).
act_track() { ACT_CMD=$1 ACT_UNIT=${2:--} ACT_WHY=""; trap _act_exit EXIT; }
_act_exit() {
  local rc=$? r=ok
  (( rc == 0 )) || r=${ACT_WHY:-exit $rc}
  actions_log "$ACT_CMD" "$ACT_UNIT" "${r%%$'\n'*}"
}
# actions_log <command> <unit> <result>: appends the line to every home in ACT_HOMES (an array;
# default CANCCU_HOME). A failed write is silent and returns 0: the log never fails a command.
actions_log() {
  local l x d homes=()
  l=$(date -u -d "@${CANCCU_NOW:-$(date +%s)}" +%Y-%m-%dT%H:%M:%SZ)$'\t'$(cfg_actor)
  for x in "$@"; do x=${x//[$'\t\n\r']/ }; l+=$'\t'${x:--}; done
  if [ -n "${ACT_HOMES+x}" ]; then homes=("${ACT_HOMES[@]}"); elif [ -n "${CANCCU_HOME:-}" ]; then homes=("$CANCCU_HOME"); fi
  for d in "${homes[@]}"; do
    [ -d "$d" ] && ( umask 077; printf '%s\n' "$l" >> "$d/actions.log" ) 2>/dev/null
  done
  return 0
}
