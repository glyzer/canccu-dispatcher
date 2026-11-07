#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# install.sh [--prefix DIR] [--host-profile NAME] [--venv DIR] [--no-monitor] [--replace-links] [--dev]
# install.sh --check
#   Installs this tree (a release tarball or a checkout) as a release under
#   PREFIX/lib/canccu-dispatcher/releases/<version>/ (PREFIX: ~/.local), switches current to it
#   and links each command into PREFIX/bin through current. --dev points current at this checkout
#   instead, for work on the tool. --check only checks the dependencies. The state dir
#   (~/.canccu, or CANCCU_ROOT) is never changed, but for a missing config and --host-profile;
#   no project is ever created, moved or migrated. docs/install.md
# Exit 0 installed, 1 failed, 2 a usage error or a missing dependency (nothing installed then).
set -uo pipefail
src=$(dirname "$(realpath "$0")")
# shellcheck source=lib/canccu-projects.sh
. "$src/lib/canccu-projects.sh"
# shellcheck source=lib/canccu-version.sh
. "$src/lib/canccu-version.sh"
# shellcheck source=lib/canccu-deps.sh
. "$src/lib/canccu-deps.sh"
# shellcheck source=lib/canccu-install.sh
. "$src/lib/canccu-install.sh"

usage() { sed -n '3,4s/^# \{0,1\}//p' "$src/install.sh" >&2; exit 2; }
# resolved like an explicit value (and like the prefix canccu-dispatcher derives from its real
# path): a HOME reached through a symlink must name its links one way only
prefix=$(realpath -m "$HOME/.local") profile="" venv=$(realpath -m "${CANCCU_VENV:-$HOME/.local/share/canccu/venv}")
monitor=1 replace=0 dev=0 check=0
while [ $# -gt 0 ]; do
  case $1 in
    --prefix|--host-profile|--venv)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "install.sh: $1 needs a value" >&2; usage; }
      case $1 in --prefix) prefix=$(realpath -m "$2") ;; --host-profile) profile=$2 ;; --venv) venv=$(realpath -m "$2") ;; esac
      shift 2 ;;
    --no-monitor) monitor=0; shift ;;
    --replace-links) replace=1; shift ;;
    --dev) dev=1; shift ;;
    --check) check=1; shift ;;
    *) echo "install.sh: unknown option $1" >&2; usage ;;
  esac
done

# ---------------------------------------------------------------- checks first: nothing changes before them
if ! problems=$(canccu_check_deps); then
  echo "install.sh: missing or too old (nothing installed):" >&2
  printf '%s\n' "$problems" >&2
  exit 2
fi
(( check )) && { echo "all dependencies found"; exit 0; }
if [ -n "$profile" ] && ! canccu_host_conf "$profile" >/dev/null; then
  echo "install.sh: no host profile '$profile'. Profiles: $(canccu_host_profiles); nothing installed" >&2; exit 2
fi
if (( dev )) && [ -z "$(canccu_commit "$src")" ]; then
  echo "install.sh: --dev needs a git checkout of canccu-dispatcher; $(canccu_tilde "$src") is none. Nothing installed" >&2; exit 2
fi

if (( ! dev )); then
  want=$(canccu_tree_files "$src" | canccu_tree_hash "$src")
  id=$(canccu_release_id "$src" "$want")
  # the id names a dir under releases/: a VERSION with a / or a leading . would leave it
  canccu_valid_release "$id" ||
    { echo "install.sh: '$id' (from VERSION) is no release name (letters, digits, . + _ -); nothing installed" >&2; exit 2; }
fi

base=$(canccu_base "$prefix")
mkdir -p "$base/releases" "$prefix/bin" || { echo "install.sh: cannot create $(canccu_tilde "$base")" >&2; exit 1; }
canccu_install_lock "$base" || exit 1

# ---------------------------------------------------------------- the release and current
if (( dev )); then
  tree=$src name="the checkout $(canccu_tilde "$src")"
  canccu_switch "$base" "$src" || exit 1
  echo "current is $name (--dev): every command runs this checkout as it is, for work on the tool: live projects must not run on it (a branch switch or an edit changes the dispatcher under them; install a release for them)"
else
  tree=$base/releases/$id name="release $id"
  canccu_stage "$src" "$base" "$id" "$want" || exit 1
  was=$(canccu_current "$base")
  canccu_switch "$base" "releases/$id" || exit 1
  # made current again: the newest for rollback and pruning (install A, B, A: rollback goes to B)
  [ "$STAGED" = same ] && [ "$was" != "releases/$id" ] && date +%s%N > "$tree/.installed"
  if [ "$STAGED" = same ] && [ "$was" = "releases/$id" ]; then echo "canccu-dispatcher $id is installed already"
  else echo "installed canccu-dispatcher $id in $(canccu_tilde "$tree")"; fi
fi
canccu_link "$prefix" "$base" "$tree" "$replace"
# read once: the processes that run from a release, for pruning and the report below
inuse=$(canccu_in_use "$base")
canccu_prune "$base" "$inuse"

# ---------------------------------------------------------------- the monitor and the state dir
if (( monitor )); then
  # recorded only once it is ours: uninstall removes the venv .venv names
  if canccu_venv "$tree/lib/canccu-monitor.requirements.txt" "$venv" "$(cat "$base/.venv" 2>/dev/null)"; then
    [ "$(cat "$base/.venv" 2>/dev/null)" = "$venv" ] || echo "$venv" > "$base/.venv"
  fi
  [ "$venv" = "$(realpath -m "${CANCCU_VENV:-$HOME/.local/share/canccu/venv}")" ] ||
    echo "the monitor finds its venv through CANCCU_VENV: export CANCCU_VENV=$(canccu_tilde "$venv")"
fi
canccu_state_config "$tree" "$profile"

# a dispatcher or run started before keeps its release until it is restarted
cur=$(canccu_current_id "$base")
while read -r rid pid; do
  [ -n "$rid" ] && [ "$rid" != "$cur" ] || continue
  echo "pid $pid still runs release $rid ($({ tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null | cut -c1-80)): restart it to run $name"
done <<<"$inuse"
canccu_on_path "$prefix/bin" "$PATH" || echo "note: $(canccu_tilde "$prefix/bin") is not on PATH"
exit 0
