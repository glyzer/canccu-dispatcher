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
prefix=$HOME/.local profile="" venv=${CANCCU_VENV:-$HOME/.local/share/canccu/venv}
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

base=$(canccu_base "$prefix")
mkdir -p "$base/releases" "$prefix/bin" || { echo "install.sh: cannot create $(canccu_tilde "$base")" >&2; exit 1; }
# append, never truncate: a re-install that changes nothing leaves even the lock's time alone
exec 9>>"$base/.install.lock"
flock -n 9 || { echo "install.sh: another install, rollback or uninstall runs on $(canccu_tilde "$base"); try again" >&2; exit 1; }

# ---------------------------------------------------------------- the release and current
if (( dev )); then
  tree=$src name="the checkout $(canccu_tilde "$src")"
  canccu_switch "$base" "$src" || exit 1
  echo "current is $name (--dev): every command runs this checkout as it is, for work on the tool: live projects must not run on it (a branch switch or an edit changes the dispatcher under them; install a release for them)"
else
  id=$(canccu_release_id "$src") tree=$base/releases/$id name="release $id"
  canccu_stage "$src" "$base" "$id" || exit 1
  was=$(canccu_current "$base")
  canccu_switch "$base" "releases/$id" || exit 1
  if [ "$STAGED" = same ] && [ "$was" = "releases/$id" ]; then echo "canccu-dispatcher $id is installed already"
  else echo "installed canccu-dispatcher $id in $(canccu_tilde "$tree")"; fi
fi
canccu_link "$prefix" "$base" "$tree" "$replace"
canccu_prune "$base"

# ---------------------------------------------------------------- the monitor and the state dir
if (( monitor )); then
  canccu_venv "$tree/lib/canccu-monitor.requirements.txt" "$venv"
  [ "$(cat "$base/.venv" 2>/dev/null)" = "$venv" ] || echo "$venv" > "$base/.venv"
  [ "$venv" = "$HOME/.local/share/canccu/venv" ] || [ "$venv" = "${CANCCU_VENV:-}" ] ||
    echo "the monitor finds its venv through CANCCU_VENV: export CANCCU_VENV=$(canccu_tilde "$venv")"
fi
canccu_state_config "$tree" "$profile"

# a dispatcher or run started before keeps its release until it is restarted
cur=$(canccu_current_id "$base")
canccu_in_use "$base" | while read -r rid pid; do
  [ "$rid" = "$cur" ] && continue
  echo "pid $pid still runs release $rid ($(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-80)): restart it to run $name"
done
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "note: $(canccu_tilde "$prefix/bin") is not on PATH" ;; esac
exit 0
