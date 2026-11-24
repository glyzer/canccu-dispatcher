# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# lib/canccu-upgrade.sh — the upgrade between passes (#20). The loop runs from a release dir
# (releases/<id>); once `current` points at another one, the upgrade is pending: under UPGRADE=auto
# nothing new starts, and once no run of the project is live the loop runs current's
# canccu-dispatch in its own place (same pane, project and lock). UPGRADE=manual only says so.
# Sourced by lib/canccu-common.sh, never run.

# upgrade_pending: the pending upgrade's version, empty for none. The loop writes the file;
# canccu-status and the snapshot read it, and a stop removes it.
upgrade_pending() { cat "$CANCCU_HOME/upgrade" 2>/dev/null || true; }
# upgrade_holds: a pending upgrade under UPGRADE=auto holds every new run, as the pause does
upgrade_holds() { [ "${UPGRADE:-auto}" = auto ] && [ -s "$CANCCU_HOME/upgrade" ]; }
# upgrade_current <script>: the `current` of the install the script's release belongs to; fails for
# a checkout (or a --dev install's checkout), which has no release to leave
upgrade_current() {
  local rel; rel=$(realpath "$(dirname "$1")/..") || return 1
  [ "$(basename "$(dirname "$rel")")" = releases ] || return 1
  echo "$(dirname "$(dirname "$rel")")/current"
}
# upgrade_check <script>: the loop's check before each pass. Notes a pending upgrade (or that none
# is) and succeeds when the loop should run the new release now.
upgrade_check() {
  local cur rel new v
  # a checkout or --dev loop has no release to leave: a file a killed loop left behind would hold
  # every new run for good, so it goes
  cur=$(upgrade_current "$1") && [ -e "$cur" ] || { rm -f "$CANCCU_HOME/upgrade"; return 1; }
  rel=$(realpath "$(dirname "$1")/..") && new=$(realpath "$cur") || return 1
  if [ "$new" = "$rel" ]; then rm -f "$CANCCU_HOME/upgrade" "$CANCCU_HOME/.warned-upgrade"; return 1; fi
  v=$(canccu_version "$new")
  if [ ! -x "$new/bin/canccu-dispatch" ]; then
    warn_once upgrade-missing "current (${new/#$HOME/\~}) has no bin/canccu-dispatch: this release goes on"
    return 1
  fi
  [ "$(upgrade_pending)" = "$v" ] || echo "$v" > "$CANCCU_HOME/upgrade"
  if [ "${UPGRADE:-auto}" != auto ]; then
    warn_once upgrade "upgrade to $v pending (UPGRADE=manual: a restart of canccu-dispatch runs it)"
    return 1
  fi
  warn_once upgrade "upgrade to $v pending: nothing new starts; it runs once no run of project $CANCCU_PROJECT is live"
  (( $(count_live "$WORKERS_DIR"/*.lock) == 0 ))
}
