# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# canccu-dispatcher rollback and uninstall. Sourced by bin/canccu-dispatcher after
# canccu-projects.sh, canccu-version.sh, canccu-install.sh and canccu-engine.sh (lock_alive),
# never run. Each defines everything it needs before it removes a file: uninstall deletes the
# tree this script runs from (bash keeps reading it through its open descriptor).

_cmd_die() { echo "canccu-dispatcher: $1" >&2; exit "${2:-1}"; }
# canccu_default_prefix <tree> [the path it was run as]: the prefix the running release was
# installed in; for a checkout (--dev) the prefix of the PREFIX/bin link it was run through, else
# ~/.local. Resolved either way, as install.sh resolves the prefix it writes the links with:
# through a symlinked HOME both name the same path.
canccu_default_prefix() {
  local t l; t=$(realpath -m "$1")
  if [[ $t == */lib/canccu-dispatcher/releases/* ]]; then printf '%s\n' "${t%/lib/canccu-dispatcher/releases/*}"; return; fi
  if [ -n "${2:-}" ] && [ -L "$2" ]; then
    l=$(readlink "$2")
    [[ $l == */lib/canccu-dispatcher/current/bin/* ]] && { realpath -m "${l%%/lib/canccu-dispatcher/current/bin/*}"; return; }
  fi
  realpath -m "$HOME/.local"
}
# _cmd_installed <base>: refuses where nothing is installed; else takes the install lock (fd 9)
_cmd_installed() {
  [ -L "$1/current" ] || _cmd_die "nothing installed in $(canccu_tilde "$1") (install.sh installs; --prefix names another prefix)"
  canccu_install_lock "$1" || exit 1
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
  # PREFIX/bin as that release has it: a command the newer one dropped is linked again, one only
  # it had goes
  canccu_link "$1" "$base" "$base/releases/$prev" 0
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
# lock is held. Refuses while a dispatcher holds its lock or a run's lock is live, unless force.
canccu_uninstall() {
  local prefix=$1 purge=$2 yes=$3 force=$4 base held venv l
  (( purge && ! yes )) && _cmd_die "--purge-state removes $(canccu_tilde "$CANCCU_ROOT") with every project's state; add --yes to mean it. Nothing removed" 2
  base=$(canccu_base "$prefix")
  [ -e "$base" ] || _cmd_die "nothing installed in $(canccu_tilde "$base")"
  held=$(canccu_held_locks)
  if (( purge )) && [ -n "$held" ]; then
    _cmd_die "the state dir is never removed while a lock is held: $(paste -sd ';' <<<"$held" | sed 's/;/; /g'). Stop them first. Nothing removed"
  fi
  # a run whose dispatcher has stopped still runs from the release as much as a dispatcher does
  if [ -n "$held" ] && (( ! force )); then
    _cmd_die "still running: $(paste -sd ';' <<<"$held" | sed 's/;/; /g'). Stop them first, or --force (they keep running from deleted files until they stop). Nothing removed"
  fi
  canccu_install_lock "$base" || exit 1
  # only the venv this install recorded: the default place may hold an older install's (the
  # same marker), and --no-monitor records none
  venv=$(cat "$base/.venv" 2>/dev/null)
  for l in "$prefix"/bin/*; do
    [ -L "$l" ] && canccu_link_ours "$(readlink "$l")" "$base" && rm -f "$l" && echo "removed $(canccu_tilde "$l")"
  done
  rm -rf "$base" && echo "removed $(canccu_tilde "$base")" || _cmd_die "could not remove all of $(canccu_tilde "$base")"
  # the recorded venv only when the installer built it (it holds the requirements' hash)
  if [ -n "$venv" ] && [ -f "$venv/.requirements.sha256" ]; then rm -rf "$venv" && echo "removed the monitor's venv $(canccu_tilde "$venv")"
  elif [ -n "$venv" ] && [ -e "$venv" ]; then echo "kept $(canccu_tilde "$venv"): not a venv the installer built"; fi
  if (( purge )); then
    rm -rf "$CANCCU_ROOT" && echo "removed the state dir $(canccu_tilde "$CANCCU_ROOT")"
  elif [ -e "$CANCCU_ROOT" ]; then
    echo "kept the state dir $(canccu_tilde "$CANCCU_ROOT") (--purge-state --yes removes it)"
  fi
  return 0
}
