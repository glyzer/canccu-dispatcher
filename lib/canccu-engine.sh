# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The run engine's plumbing: guard, locks, tmux, repo lookup. Sourced by lib/canccu-common.sh and
# libexec/canccu-worker, never run. CODE_ROOT, WORKERS_DIR and TMUX_SESSION have no defaults here:
# lib/canccu-common.sh derives them from the project, so a value from another context never counts.

WORKER_CAP="${WORKER_CAP:-3}"
WORKER_REPO_CAP="${WORKER_REPO_CAP:-3}"
WORKER_EXCLUSIVE_RE="${WORKER_EXCLUSIVE_RE:-}"   # canccu-worker: issues matching it run one at a time per repo

# cron and fresh tmux servers start with a bare PATH
for _d in "$HOME/.bun/bin" "$HOME/.local/bin"; do
  case ":$PATH:" in *":$_d:"*) ;; *) [ -d "$_d" ] && PATH="$_d:$PATH" ;; esac
done
export PATH
[ -n "${WORKERS_DIR:-}" ] && mkdir -p "$WORKERS_DIR"

TAB=$'\t'
die() { echo "$(basename "$0"): $*" >&2; exit 1; }

# guard <duration> <cmd...>: every gh, jq and python3 call goes through this. A wall-clock
# limit plus a virtual-memory cap, so a runaway kills itself, not the container.
GUARD_VMEM_KB="${GUARD_VMEM_KB:-2000000}"
guard() { ( guard_exec "$@" ); }
# guard_exec: the same, replacing the current (already forked) shell, so its pid is timeout's
guard_exec() {
  local t=$1; shift
  ulimit -v "$GUARD_VMEM_KB" && exec timeout -k 10 "$t" "$@"
}
# timed_exec <duration> <cmd...>: wall-clock limit only, replacing the current shell. For the
# worker's claude -p: ulimit -v breaks the Node test suites it runs (WebAssembly reserves far
# more address space than it uses); its budgets and the container cgroup bound its memory.
timed_exec() {
  local t=$1; shift
  exec timeout -k 10 "$t" "$@"
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# tree_pids <pid>: the pid and all its descendants. `timeout` puts claude in its own process
# group, so a tmux hangup or a plain `kill <wrapper>` never reaches it; walk the tree instead.
tree_pids() { local k; echo "$1"; for k in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$k"; done; }
# tool_ticks <pid>: "<pid> <cpu ticks>" for each process the run's tools started: the tree below
# claude, the child of the run's `timeout`. Claude's own ticks are left out: it spends CPU while it
# hangs too, a test runner it started spends it only while it works (#26)
tool_ticks() {
  local p c="" f
  for p in $(tree_pids "$1"); do
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" = timeout ] && { c=$(pgrep -P "$p" 2>/dev/null | head -n1); break; }
  done
  [ -n "$c" ] || return 0
  for p in $(tree_pids "$c"); do
    [ "$p" = "$c" ] && continue
    f=$(cat "/proc/$p/stat" 2>/dev/null) || continue
    # the fields after the command, which may hold spaces: utime and stime are the 12th and 13th
    read -ra f <<<"${f##*) }"
    echo "$p $(( f[11] + f[12] ))"
  done
}
# tools_busy <pid> <file>: a tool process of the run is new or spent CPU since the ticks in file
# (rewritten with the current ones)
tools_busy() {
  local now; now=$(tool_ticks "$1")
  printf '%s\n' "$now" > "$2.new"
  [ -n "$now" ] && awk 'FILENAME == ARGV[1] { t[$1] = $2; next } !($1 in t) || $2 > t[$1] { busy = 1 } END { exit !busy }' "$2" "$2.new" 2>/dev/null
  local r=$?; mv -f "$2.new" "$2"; return $r
}
# kill_tree <pid>: TERM the whole tree, KILL what is left after 3 s
kill_tree() {
  local pids; pids=$(tree_pids "$1")
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null; sleep 3; kill -KILL $pids 2>/dev/null
  return 0
}

# Every repo under CODE_ROOT (a folder with .git, depth 1 or 2, symlinked folders included),
# relative to it. A repo reached twice is listed once, real folders before symlinks; the fixed
# depth means a symlink cycle cannot loop.
list_repos() {
  local d real pass seen=$'\n'
  for pass in real link; do
    for d in "$CODE_ROOT"/*/ "$CODE_ROOT"/*/*/; do
      [ -e "$d.git" ] || continue
      d=${d%/}
      [[ $pass == link ]] && [ ! -L "$d" ] && continue
      [[ $pass == real ]] && [ -L "$d" ] && continue
      real=$(realpath "$d")
      [[ $seen == *$'\n'"$real"$'\n'* ]] && continue
      seen+="$real"$'\n'
      echo "${d#"$CODE_ROOT"/}"
    done
  done
}

# resolve_repo <repo | workspace/repo> → absolute path. Fails if missing or ambiguous.
resolve_repo() {
  local want=${1%/} rel matches=()
  while read -r rel; do
    [[ $rel == "$want" || ${rel##*/} == "$want" ]] && matches+=("$rel")
  done < <(list_repos)
  case ${#matches[@]} in
    0) echo "no repo named '$want' under $CODE_ROOT" >&2; return 1 ;;
    1) echo "$CODE_ROOT/${matches[0]}" ;;
    *) echo "'$want' is ambiguous (${matches[*]}); use <workspace>/<repo>" >&2; return 1 ;;
  esac
}

# --- locks: key=value lines (repo, key, kind=worker, pid, pstart, window, session, wname, word,
# started, exclusive, isolated). An old install may have left kind=cc locks: they count as alive
# like any other, but are never this engine's to kill.

lock_path() { echo "$WORKERS_DIR/$1-$2.lock"; }
# lock_get <file> <key>: the key's first value. Pure bash: every pass reads every lock many times.
lock_get() {
  local l
  [ -r "$1" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l == "$2="* ]] && { printf '%s\n' "${l#"$2="}"; return 0; }
  done < "$1"
  return 0
}

# proc_start <pid>: the process's start time in clock ticks since boot (/proc/<pid>/stat field 22;
# the fields are counted after the last ")", since the command name may contain spaces)
proc_start() {
  local s; { s=$(< "/proc/$1/stat"); } 2>/dev/null || return 1
  s=${s##*) }
  # shellcheck disable=SC2086
  set -- $s; [ -n "${20:-}" ] && echo "${20}"
}

# lock_pid_alive <lock>: its pid runs and, when the lock recorded one, with the same start time,
# so a pid reused after a reboot is not mistaken for the run
lock_pid_alive() {
  local pid ps; pid=$(lock_get "$1" pid); ps=$(lock_get "$1" pstart)
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  [ -z "$ps" ] || [ "$(proc_start "$pid")" = "$ps" ]
}
# lock_window_alive <lock>: its window id exists and, when the lock recorded them, still has the
# same session and name, so a window id reused after a tmux restart is not mistaken for the run
lock_window_alive() {
  local win ses name; win=$(lock_get "$1" window); ses=$(lock_get "$1" session); name=$(lock_get "$1" wname)
  [ -n "$win" ] || return 1
  tmux list-windows -a -F "#{window_id}${TAB}#{session_name}${TAB}#{window_name}" 2>/dev/null |
    awk -F '\t' -v w="$win" -v s="$ses" -v n="$name" \
      '$1 == w && (s == "" || $2 == s) && (n == "" || $3 == n) { f = 1 } END { exit !f }'
}
# A lock is alive while its process runs or its tmux window still exists.
lock_alive() { lock_pid_alive "$1" || lock_window_alive "$1"; }

# --- tmux

# tmux_env: -e flags that carry this process's settings into a new window. The tmux server's
# environment is the one it started with, so without them a WORKERS_DIR or TMUX_SESSION
# override (canccu-dispatch) is lost inside the run and its state lands in the default dir.
# Credentials never travel this way: GH_TOKEN, GITHUB_TOKEN and the old WORKER_GH_TOKEN_FILE are
# always sent empty, so a value the tmux server inherited when it started is overridden too.
# tmux_gh_env: -e flags for the gh config dir (GH_CONFIG_DIR: a canccu project's own login, a
# path, never a token), its owner (CANCCU_GH_OWNER) and git's environment config
# (GIT_CONFIG_COUNT/KEY_n/VALUE_n: its credential helper). Always sent, empty when unset, so a
# window never inherits another project's from the tmux server. tmux_env and canccu-up use it.
tmux_gh_env() {
  local v
  printf '%s\0' -e "GH_CONFIG_DIR=${GH_CONFIG_DIR:-}" -e "GIT_CONFIG_COUNT=${GIT_CONFIG_COUNT:-}" \
    -e "CANCCU_GH_OWNER=${CANCCU_GH_OWNER:-}"
  for v in $(compgen -v GIT_CONFIG_KEY_) $(compgen -v GIT_CONFIG_VALUE_); do printf '%s\0' -e "$v=${!v}"; done
}
# tmux_token_blanks: -e flags that blank the token variables
tmux_token_blanks() { local v; for v in GH_TOKEN GITHUB_TOKEN WORKER_GH_TOKEN_FILE REVIEWER_TOKEN_FILE; do printf '%s\0' -e "$v="; done; }
tmux_env() {
  local v
  for v in PATH CANCCU_HOME CODE_ROOT WORKERS_DIR TMUX_SESSION GUARD_VMEM_KB $(compgen -v WORKER_); do
    case $v in WORKER_RULES|WORKER_GH_TOKEN_FILE) continue ;; esac
    [ -n "${!v+x}" ] && printf '%s\0' -e "$v=${!v}"
  done
  tmux_gh_env
  tmux_token_blanks
}
# without_gh_env <cmd...>: run it without the gh config dir, its owner and git's environment
# config. For a tmux client that may start the server (new-session): the server keeps that
# client's environment as its global one, which every later session, canccu or not, inherits.
# The new session's own panes get the values through -e.
without_gh_env() {
  local u=(-u GH_CONFIG_DIR -u CANCCU_GH_OWNER -u GIT_CONFIG_COUNT) v
  for v in $(compgen -v GIT_CONFIG_KEY_) $(compgen -v GIT_CONFIG_VALUE_); do u+=(-u "$v"); done
  env "${u[@]}" "$@"
}

# tmux_window <name> <dir> <cmd...>: detached window in session $TMUX_SESSION; prints its window id.
tmux_window() {
  local name=$1 dir=$2 env; shift 2
  mapfile -d '' env < <(tmux_env)
  if tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
    tmux new-window -d -P -F '#{window_id}' -t "=$TMUX_SESSION:" -n "$name" -c "$dir" "${env[@]}" "$@"
  else
    without_gh_env tmux new-session -d -P -F '#{window_id}' -s "$TMUX_SESSION" -n "$name" -c "$dir" "${env[@]}" "$@"
  fi
}

window_by_name() {
  tmux list-windows -t "=$TMUX_SESSION" -F '#{window_id} #{window_name}' 2>/dev/null |
    awk -v n="$1" '$2 == n { print $1; exit }'
}

# Bring a window to the front: switch to it inside tmux, attach to it outside.
tmux_show() {
  if [ -n "$TMUX" ]; then tmux switch-client -t "$1"
  else tmux select-window -t "$1" \; attach -t "=$TMUX_SESSION"; fi
}

ago() {
  local s=$(( ${CANCCU_NOW:-$(date +%s)} - $1 ))   # CANCCU_NOW: the tests' clock
  if   (( s < 60 ));    then echo "${s}s"
  elif (( s < 3600 ));  then echo "$((s / 60))m"
  elif (( s < 86400 )); then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"; fi
}
