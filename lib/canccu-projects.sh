# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The projects of canccu-dispatch: names, the default one, tmux sessions. Sourced by
# canccu-common.sh and canccu-init, never run. docs/canccu-dispatch.md, "Projects".
# Every project lives in $CANCCU_ROOT/projects/<name>/ (CANCCU_HOME): config, rules, state,
# workers, reviews, digest, log, lock. Global in CANCCU_ROOT: config (TOTAL_CAP), the reviewer
# token, default-project and the usage-limit back-off (one Claude account for all projects).
CANCCU_ROOT=${CANCCU_ROOT:-$HOME/.canccu}
_canccu_hosts=$(dirname "${BASH_SOURCE[0]}")/../hosts
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
# canccu_host_profile: the host profile's name: CANCCU_HOST_PROFILE, else HOST_PROFILE in
# ~/.canccu/config. That file is read in a subshell: nothing else of it may be set before the
# profile, whose values it overrides.
canccu_host_profile() {
  if [ -n "${CANCCU_HOST_PROFILE:-}" ]; then printf '%s\n' "$CANCCU_HOST_PROFILE"; return; fi
  canccu_config_host_profile "$CANCCU_ROOT/config"
}
# canccu_config_host_profile <config file>: the HOST_PROFILE that file sets, as the shell reads it
# (quotes and comments gone). The defaults come first, as in the real load: a line that builds on
# one (TOTAL_CAP=$((CAP * 2))) must not end the read before HOST_PROFILE; nor must an unset name.
canccu_config_host_profile() {
  [ -f "$1" ] || return 0
  ( set +u
    # shellcheck source=canccu-config.default
    . "$(dirname "${BASH_SOURCE[0]}")/canccu-config.default" >/dev/null 2>&1
    HOST_PROFILE=""
    # shellcheck source=/dev/null
    . "$1" >/dev/null 2>&1
    printf '%s\n' "$HOST_PROFILE" ) | grep .
  return 0
}
# canccu_host_profiles: the shipped profiles' names, comma-separated
canccu_host_profiles() {
  local f out=()
  for f in "$_canccu_hosts"/*.conf; do [ -f "$f" ] && out+=("$(basename "$f" .conf)"); done
  local IFS=,; printf '%s\n' "${out[*]}" | sed 's/,/, /g'
}
# canccu_host_conf <name>: the profile's file; fails for an unknown name (or one that is a path)
canccu_host_conf() {
  canccu_valid_name "$1" && [ -f "$_canccu_hosts/$1.conf" ] || return 1
  printf '%s\n' "$(realpath -m "$_canccu_hosts/$1.conf")"
}
# canccu_host_where: where the profile's name came from, for a message
canccu_host_where() {
  if [ -n "${CANCCU_HOST_PROFILE:-}" ]; then echo CANCCU_HOST_PROFILE; else echo "HOST_PROFILE in $(canccu_tilde "$CANCCU_ROOT")/config"; fi
}
