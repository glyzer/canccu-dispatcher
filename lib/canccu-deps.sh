# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The dependency check of install.sh (--check) and canccu-dispatcher doctor. Sourced, never run.
# canccu_check_deps prints one line per missing or too-old tool, each with how to get it, and
# fails when there is one. docs/install.md lists the same.

# every flag libexec/canccu-worker passes to claude, by its long name (-p is --print, -n --name);
# tests/canccu-install.sh fails when the engine passes one that is not here
CANCCU_CLAUDE_FLAGS="--print --output-format --verbose --permission-mode --permission-prompts --max-budget-usd
--name --session-id --resume --append-system-prompt --model --setting-sources --strict-mcp-config --settings --add-dir"
# the oldest Claude Code the run engine was tested with (docs/install.md)
CANCCU_CLAUDE_TESTED=2.1.319

# _dep_ver_ge <have> <want>: have is want or newer (sort -V also orders tmux's 3.0a before 3.2)
_dep_ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
# _dep_ver <regex> <cmd...>: the first match of the version regex in the command's output
_dep_ver() { local re=$1; shift; timeout 20 "$@" 2>&1 | grep -oE "$re" | head -n1; }
# _dep_min <name> <want> <found> <how>: the line for a tool older than want, or nothing
_dep_min() {
  if [ -z "$3" ]; then echo "$1 ≥ $2: not found; $4"
  elif ! _dep_ver_ge "$3" "$2"; then echo "$1 ≥ $2 (found $3); $4"; fi
}
# _dep_gh_login: gh has a login: the default one, or a project's own config dir (canccu-init's
# narrow token per project). Only gh's exit code is looked at, never a token.
_dep_gh_login() {
  local d
  timeout 20 gh auth status >/dev/null 2>&1 && return 0
  for d in "${CANCCU_ROOT:-$HOME/.canccu}"/projects/*/gh; do
    [ -d "$d" ] && GH_CONFIG_DIR=$d timeout 20 gh auth status >/dev/null 2>&1 && return 0
  done
  return 1
}

# canccu_check_deps: one line per problem ("  <tool>: …; <how to get it>"); fails when any
canccu_check_deps() {
  local out=() v f help miss=()
  [ "$(uname -s)" = Linux ] || out+=("Linux: this is $(uname -s); canccu-dispatcher runs on Linux only")
  date --version 2>/dev/null | grep -q 'GNU coreutils' ||
    out+=("GNU coreutils: not found (date, stat, realpath); apt install coreutils")
  command -v flock >/dev/null 2>&1 || out+=("flock: not found; apt install util-linux")
  ps --version 2>&1 | grep -qi procps || out+=("procps (ps, pgrep): not found; apt install procps")
  v=$(_dep_ver '[0-9]+\.[0-9]+(\.[0-9]+)?' bash --version)
  out+=("$(_dep_min bash 5.0 "$v" "apt install bash")")
  v=$(command -v git >/dev/null && _dep_ver '[0-9]+\.[0-9]+(\.[0-9]+)?' git --version)
  out+=("$(_dep_min git 2.30 "$v" "apt install git, or https://git-scm.com/downloads")")
  v=$(command -v jq >/dev/null && _dep_ver '[0-9]+\.[0-9]+(\.[0-9]+)?' jq --version)
  out+=("$(_dep_min jq 1.6 "$v" "apt install jq, or https://jqlang.org/download/")")
  v=$(command -v tmux >/dev/null && _dep_ver '[0-9]+\.[0-9]+[a-z]?' tmux -V)
  out+=("$(_dep_min tmux 3.2 "$v" "apt install tmux, or https://github.com/tmux/tmux/wiki/Installing")")
  v=$(command -v python3 >/dev/null && _dep_ver '[0-9]+\.[0-9]+(\.[0-9]+)?' python3 --version)
  out+=("$(_dep_min python3 3.10 "$v" "apt install python3 (the monitor's pinned packages need 3.10)")")
  if ! command -v gh >/dev/null 2>&1; then out+=("gh: not found; https://cli.github.com (apt install gh)")
  elif ! _dep_gh_login; then out+=("gh: not logged in; gh auth login (or a project's own login: canccu-init prints the steps)"); fi
  if ! command -v claude >/dev/null 2>&1; then
    out+=("claude: not found; install Claude Code $CANCCU_CLAUDE_TESTED or newer: https://docs.claude.com/en/docs/claude-code")
  else
    help=$(timeout 30 claude --help 2>&1)
    for f in $CANCCU_CLAUDE_FLAGS; do grep -qE -- "(^|[[:space:],])$f([[:space:],=]|$)" <<<"$help" || miss+=("$f"); done
    (( ${#miss[@]} )) && out+=("claude: its --help lacks ${miss[*]}, which the run engine passes; update Claude Code (claude update) to $CANCCU_CLAUDE_TESTED or newer")
  fi
  local n=0 l
  for l in "${out[@]}"; do [ -n "$l" ] && { echo "  $l"; n=$((n + 1)); }; done
  (( n == 0 ))
}
