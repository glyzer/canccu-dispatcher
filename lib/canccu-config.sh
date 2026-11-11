# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# Reading the config files, at load and again when one changed (docs/reference/config.md, "When a
# change applies"). Sourced by canccu-common.sh, which sets _canccu_lib, _canccu_hp and
# _canccu_hpf (the host profile and its file) before it calls canccu_load_config.

# canccu_load_config: the defaults, the host profile, ~/.canccu/config, the project's rules, its
# config. TOTAL_CAP is the global files' (a project cannot raise it); HOST_PROFILE is fixed
# before any of them: neither a profile nor a later file changes it.
canccu_load_config() {
  local total
  # shellcheck source=canccu-config.default
  . "$_canccu_lib/canccu-config.default"
  # shellcheck source=/dev/null
  [ -n "$_canccu_hpf" ] && . "$_canccu_hpf"
  # shellcheck source=/dev/null
  [ -f "$CANCCU_ROOT/config" ] && . "$CANCCU_ROOT/config"
  total=$TOTAL_CAP
  # shellcheck source=/dev/null
  . "$CANCCU_HOME/rules"
  # shellcheck source=/dev/null
  . "$CANCCU_HOME/config"
  TOTAL_CAP=$total HOST_PROFILE=$_canccu_hp
}
# canccu_cfg_files: the four files a user edits (the defaults change only with an update, which
# restarts the dispatcher anyway)
canccu_cfg_files() { printf '%s\n' "$_canccu_hpf" "$CANCCU_ROOT/config" "$CANCCU_HOME/rules" "$CANCCU_HOME/config"; }
# canccu_cfg_stamp: their modification times, 0 for a file that is not there
canccu_cfg_stamp() {
  local f
  while IFS= read -r f; do
    if [ -n "$f" ] && [ -f "$f" ]; then stat -c %Y "$f"; else echo 0; fi
  done < <(canccu_cfg_files) | tr '\n' ' '
}
# canccu_reload_config: read the files again when one changed since the last read, between two
# passes. A file with a syntax error keeps every value as it is (a half-read config is worse than
# an old one). REPO, CLONE and the gh login were used to set up this process: a change to them is
# undone and needs a restart. GH_CONFIG_DIR is compared as the files set it (_canccu_cfg_ghdir);
# the variable itself holds the dir canccu-common.sh derived and exported from it.
canccu_reload_config() {
  local stamp f repo=$REPO clone=$CLONE gh=${GH_CONFIG_DIR-} gh_set=${GH_CONFIG_DIR+x} k
  stamp=$(canccu_cfg_stamp)
  [ "$stamp" = "$CANCCU_CFG_STAMP" ] && return 0
  CANCCU_CFG_STAMP=$stamp
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null && continue
    warn_once config-syntax "$(canccu_tilde "$f"): syntax error; the dispatcher keeps the values it has"
    return 0
  done < <(canccu_cfg_files)
  canccu_load_config
  for k in REPO CLONE GH_CONFIG_DIR; do
    case $k in
      REPO) [ "$REPO" = "$repo" ] && continue; REPO=$repo ;;
      CLONE) [ "$CLONE" = "$clone" ] && continue; CLONE=$clone ;;
      GH_CONFIG_DIR) [ "${GH_CONFIG_DIR-}" = "$_canccu_cfg_ghdir" ] && continue ;;
    esac
    warn_once "config-restart-$k" "$k changed in the config: restart the dispatcher to apply it"
  done
  if [ -n "$gh_set" ]; then GH_CONFIG_DIR=$gh; else unset GH_CONFIG_DIR; fi
  log "config read again"
}
