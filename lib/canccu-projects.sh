# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The projects of canccu-dispatch: names, the default one, tmux sessions. Sourced by
# canccu-common.sh and canccu-init, never run. docs/canccu-dispatch.md, "Projects".
# Every project lives in $CANCCU_ROOT/projects/<name>/ (CANCCU_HOME): config, rules, state,
# workers, reviews, digest, log, lock. Global in CANCCU_ROOT: config (TOTAL_CAP), the reviewer
# token, default-project and the usage-limit back-off (one Claude account for all projects).
CANCCU_ROOT=${CANCCU_ROOT:-$HOME/.canccu}
# canccu_profiles: the project names (a dir under projects/ with a config file)
canccu_profiles() {
  local d
  for d in "$CANCCU_ROOT"/projects/*/; do [ -f "$d/config" ] && basename "$d"; done
  return 0
}
# canccu_default_profile: the name in default-project, else the only project; nothing otherwise
canccu_default_profile() {
  local d; d=$(tr -d '[:space:]' 2>/dev/null < "$CANCCU_ROOT/default-project")
  [ -n "$d" ] || { d=$(canccu_profiles); [ "$(grep -c . <<<"$d")" = 1 ] || d=""; }
  printf '%s\n' "$d" | grep .
  return 0
}
# canccu_session <name>: the project's tmux session: canccu for the default one (or
# CANCCU_TMUX_SESSION, which renames only that one), else canccu-<name>
canccu_session() {
  if [ "$1" = "$(canccu_default_profile)" ]; then echo "${CANCCU_TMUX_SESSION:-canccu}"; else echo "canccu-$1"; fi
}
# canccu_tilde <path>: the path with $HOME shown as ~, only as a whole leading component (a
# sibling directory whose name starts with $HOME's last part stays as it is)
canccu_tilde() {
  if [[ $1 == "$HOME" || $1 == "$HOME"/* ]]; then printf '~%s' "${1#"$HOME"}"; else printf '%s' "$1"; fi
}
canccu_valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]]; }
# canccu_repo_clone <config file>: "<REPO><TAB><CLONE>" as that config sets them, read in a
# subshell (the canccu-config.default values are none)
canccu_repo_clone() {
  ( REPO="" CLONE=""
    # shellcheck source=/dev/null
    . "$1" >/dev/null 2>&1
    printf '%s\t%s\n' "$REPO" "$CLONE" )
}
