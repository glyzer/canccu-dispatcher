# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# canccu-dispatcher rollback and uninstall. Sourced by bin/canccu-dispatcher after
# canccu-projects.sh, canccu-version.sh, canccu-install.sh and canccu-engine.sh (lock_alive),
# never run. Each defines everything it needs before it removes a file: uninstall deletes the
# tree this script runs from (bash keeps reading it through its open descriptor).

_cmd_die() { echo "canccu-dispatcher: $1" >&2; exit "${2:-1}"; }
# canccu_default_prefix <tree>: the prefix the running release was installed in; ~/.local for a
# checkout
canccu_default_prefix() {
  local t; t=$(realpath -m "$1")
  if [[ $t == */lib/canccu-dispatcher/releases/* ]]; then printf '%s\n' "${t%/lib/canccu-dispatcher/releases/*}"
  else printf '%s\n' "$HOME/.local"; fi
}
# _cmd_installed <base>: refuses where nothing is installed; else takes the install lock (fd 9)
_cmd_installed() {
  [ -L "$1/current" ] || _cmd_die "nothing installed in $(canccu_tilde "$1") (install.sh installs; --prefix names another prefix)"
  exec 9>>"$1/.install.lock"
  flock -n 9 || _cmd_die "an install, rollback or uninstall runs on $(canccu_tilde "$1"); try again"
}

# canccu_rollback <prefix>: current back to the release installed before it (from a checkout:
# to the newest release). Prunes nothing: a rollback after a rollback goes further back.
canccu_rollback() {
  local base cur prev="" id was
  base=$(canccu_base "$1"); _cmd_installed "$base"
  cur=$(canccu_current_id "$base"); was=${cur:-the checkout $(canccu_tilde "$(canccu_current "$base")")}
  for id in $(canccu_releases "$base"); do
    [ -n "$cur" ] && [ "$id" = "$cur" ] && break
    prev=$id
  done
  [ -n "$prev" ] || _cmd_die "no release before ${cur:-the checkout} in $(canccu_tilde "$base/releases"); current is unchanged"
  canccu_switch "$base" "releases/$prev" || exit 1
  echo "current is release $prev (was $was)"
  echo "a running dispatcher keeps its release until it is restarted (canccu-dispatcher doctor names them)"
}

# canccu_held_locks: "<what>" per held lock: a dispatcher's lock (another process holds it) or a
# live run's lock, of every project
canccu_held_locks() {
  local l p
  for l in "$CANCCU_ROOT"/projects/*/.dispatch.lock; do
    [ -e "$l" ] || continue
    p=${l%/.dispatch.lock}; p=${p##*/}
    flock -n "$l" true 2>/dev/null || echo "dispatcher $(canccu_tilde "$l") (project $p)"
  done
  for l in "$CANCCU_ROOT"/projects/*/workers/*.lock; do
    [ -e "$l" ] && lock_alive "$l" && echo "run $(canccu_tilde "$l")"
  done
  return 0
}

# canccu_uninstall <prefix> <purge 0|1> <yes 0|1> <force 0|1>: removes the links into its own
# tree, the tree and the monitor venv; the state dir only with purge and yes, and never while a
# lock is held. Refuses while a dispatcher holds its lock, unless force.
canccu_uninstall() {
  local prefix=$1 purge=$2 yes=$3 force=$4 base held disp venv l
  (( purge && ! yes )) && _cmd_die "--purge-state removes $(canccu_tilde "$CANCCU_ROOT") with every project's state; add --yes to mean it. Nothing removed" 2
  base=$(canccu_base "$prefix")
  [ -e "$base" ] || _cmd_die "nothing installed in $(canccu_tilde "$base")"
  held=$(canccu_held_locks); disp=$(grep '^dispatcher ' <<<"$held")
  if (( purge )) && [ -n "$held" ]; then
    _cmd_die "the state dir is never removed while a lock is held: $(paste -sd ';' <<<"$held" | sed 's/;/; /g'). Stop them first. Nothing removed"
  fi
  if [ -n "$disp" ] && (( ! force )); then
    _cmd_die "a dispatcher runs: $(paste -sd ';' <<<"$disp" | sed 's/;/; /g'). Stop it first, or --force (it keeps running from deleted files until stopped). Nothing removed"
  fi
  exec 9>>"$base/.install.lock"
  flock -n 9 || _cmd_die "an install, rollback or uninstall runs on $(canccu_tilde "$base"); try again"
  venv=$(cat "$base/.venv" 2>/dev/null); venv=${venv:-${CANCCU_VENV:-$HOME/.local/share/canccu/venv}}
  for l in "$prefix"/bin/*; do
    [ -L "$l" ] && [[ $(readlink "$l") == "$base"/* ]] && rm -f "$l" && echo "removed $(canccu_tilde "$l")"
  done
  rm -rf "$base" && echo "removed $(canccu_tilde "$base")" || _cmd_die "could not remove all of $(canccu_tilde "$base")"
  # only a venv the installer built (it holds the requirements' hash)
  if [ -f "$venv/.requirements.sha256" ]; then rm -rf "$venv" && echo "removed the monitor's venv $(canccu_tilde "$venv")"
  elif [ -e "$venv" ]; then echo "kept $(canccu_tilde "$venv"): not a venv the installer built"; fi
  if (( purge )); then
    rm -rf "$CANCCU_ROOT" && echo "removed the state dir $(canccu_tilde "$CANCCU_ROOT")"
  elif [ -e "$CANCCU_ROOT" ]; then
    echo "kept the state dir $(canccu_tilde "$CANCCU_ROOT") (--purge-state --yes removes it)"
  fi
  return 0
}
