# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# canccu-dispatcher doctor: one line per problem of the host, the install and the projects.
# Sourced by bin/canccu-dispatcher after canccu-projects.sh, canccu-version.sh, canccu-install.sh,
# canccu-engine.sh, canccu-deps.sh and canccu-install-cmds.sh; never run. Changes nothing, and
# never reads the reviewer token (only its mode and the rules that keep Claude off it).

# _doc_install <prefix>: the install this command belongs to: a complete release, every command
# linked through current and first on PATH, no process left on an older release
_doc_install() {
  local prefix base id tree c n l t p cur
  prefix=$1; base=$(canccu_base "$prefix")
  [ -L "$base/current" ] || { echo "canccu-dispatcher is not installed in $(canccu_tilde "$prefix") (install.sh)"; return; }
  id=$(canccu_current_id "$base") cur=$(canccu_current "$base")
  if [ -n "$id" ]; then
    tree=$base/releases/$id
    canccu_release_intact "$tree" ||
      echo "release $id is incomplete or changed ($(canccu_tilde "$tree")): make another release current (install one, or canccu-dispatcher rollback), then install this one again"
  else
    tree=$cur
    [ -d "$tree/bin" ] || { echo "release: current points at $(canccu_tilde "$cur"), which is no tree"; return; }
  fi
  canccu_on_path "$prefix/bin" "${CANCCU_USER_PATH:-$PATH}" || echo "canccu-dispatcher: $(canccu_tilde "$prefix/bin") is not on PATH"
  for c in "$tree"/bin/*; do
    n=${c##*/} l=$prefix/bin/${c##*/}
    if [ -L "$l" ]; then
      t=$(readlink "$l")
      canccu_link_cmd "$t" "$base" "$n" || { echo "$n links to $t, not to this install (install.sh --replace-links)"; continue; }
    elif [ -e "$l" ]; then echo "$n in $(canccu_tilde "$prefix/bin") is a file, not a link to this install"; continue
    else echo "$n is not linked in $(canccu_tilde "$prefix/bin") (install.sh)"; continue; fi
    p=$(PATH=${CANCCU_USER_PATH:-$PATH} command -v "$n" 2>/dev/null)
    # the dirs resolved on both sides: PREFIX/bin may itself be a link
    [ -z "$p" ] || [ "$(realpath -m "${p%/*}")" = "$(realpath -m "$prefix/bin")" ] || echo "$n on PATH is $(canccu_tilde "$p"), not this install's $(canccu_tilde "$l")"
  done
  canccu_in_use "$base" | while read -r t p; do
    [ "$t" = "$id" ] && continue
    echo "release $t is still in use: pid $p ($({ tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | cut -c1-60)) runs release $t; current is ${id:-the checkout}: restart it"
  done
}

# _doc_glob <glob> <path>: a Claude permission path glob matches the path (** any dirs, * and ?
# within one)
_doc_glob() {
  local re
  re=$(printf '%s' "$1" | sed -e 's/[][\.^$+(){}|]/\\&/g' -e 's/\*\*/\x01/g' -e 's/\*/[^\/]*/g' -e 's/?/[^\/]/g' -e 's/\x01/.*/g')
  [[ $2 =~ ^$re$ ]]
}
# _doc_denied <path>: a Read deny rule of the user's or the managed Claude settings covers it.
# Rules relative to a project or the working dir cannot cover it everywhere: they do not count.
_doc_denied() {
  local s r pat f
  for s in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" /etc/claude-code/managed-settings.json; do
    [ -f "$s" ] || continue
    while IFS= read -r r; do
      [ "$r" = Read ] && return 0
      [[ $r =~ ^Read\((.*)\)$ ]] || continue
      pat=${BASH_REMATCH[1]}
      # shellcheck disable=SC2088  # Claude's ~, not the shell's
      case $pat in "//"*) pat=${pat#/} ;; "~/"*) pat=$HOME/${pat#"~/"} ;; *) continue ;; esac
      [[ $pat == */ ]] && pat+="**"
      for f in "$1" "$(realpath -m "$1")"; do _doc_glob "$pat" "$f" && return 0; done
    done < <(jq -r '.permissions.deny[]? | strings' "$s" 2>/dev/null)
  done
  return 1
}
# _doc_token <file>: present, mode 600, behind a deny rule
_doc_token() {
  local t; t=$(canccu_tilde "$1")
  [ -e "$1" ] || { echo "reviewer token $t: missing (one token for all projects, mode 600); no review starts"; return; }
  [ "$(stat -c %a "$1")" = 600 ] || echo "reviewer token $t has mode $(stat -c %a "$1"), not 600 (chmod 600 $t)"
  # the rule in Claude's own path forms: ~/… under HOME, //… for an absolute path (a single /
  # would be relative to the settings file)
  local r=$t; [[ $1 == "$HOME"/* ]] || r=/$1
  _doc_denied "$1" || echo "reviewer token $t: no Claude deny rule covers it (add \"Read($r)\" to permissions.deny in ~/.claude/settings.json)"
}

# _doc_project: the project loaded by canccu-common.sh (in a subshell). Prints its problems, and
# "@token <file>" for the token check that runs once per file.
_doc_project() {
  local l held=0 f at age sz
  echo "@token ${REVIEWER_TOKEN_FILE:-}"
  login_problem
  [ -n "$REVIEWER_LOGIN" ] || echo "REVIEWER_LOGIN is not set (the reviewer bot's login, in $(login_where)): no reviews"
  git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 ||
    echo "the clone $(canccu_tilde "$CLONE") is not a git checkout (git clone https://github.com/$REPO $(canccu_tilde "$CLONE"))"
  gh_credential_problem 2>/dev/null
  l=$CANCCU_HOME/.dispatch.lock
  [ -e "$l" ] && ! flock -n "$l" true 2>/dev/null && held=1
  (( held )) && ! dispatcher_running &&
    echo "its dispatcher lock is held, but no canccu-dispatch runs (dispatch.pid): another process holds $(canccu_tilde "$l")"
  f=$CANCCU_HOME/status.json
  if (( held )); then
    at=$(jq -r '.pass.at // empty' "$f" 2>/dev/null)
    if [[ $at =~ ^[0-9]+$ ]]; then
      age=$(( $(date +%s) - at ))
      (( age > 3 * INTERVAL + 300 )) && echo "the status snapshot is $(( age / 60 )) min old while its dispatcher runs (canccu-status, dispatch.log)"
    else echo "no status snapshot while its dispatcher runs ($(canccu_tilde "$f"))"; fi
  fi
  [ "$(jq -r '.pass.ok' "$f" 2>/dev/null)" = false ] && echo "the last pass failed: $(jq -r '.pass.error // "unknown error"' "$f")"
  # a run removes its temp dir and the dispatcher's start the ones left: this much means a run
  # leaks, or one fills it now (apparent size: what the runs wrote, sparse files included)
  f=$WORKERS_DIR/tmp
  sz=$( { du -s --apparent-size -B1 "$f" | cut -f1; } 2>/dev/null)
  (( ${sz:-0} > 5 * 1024 ** 3 )) &&
    echo "run temp dirs use $(numfmt --to=iec --round=nearest --format=%.1f "$sz"); a run may leak, check $(canccu_tilde "$f")"
  for l in "$WORKERS_DIR"/*.lock; do
    [ -e "$l" ] && ! lock_alive "$l" &&
      echo "stale run lock $(canccu_tilde "$l") (no process or window of it; canccu-worker --unlock $(lock_get "$l" repo) $(lock_get "$l" key), or remove it)"
  done
  return 0
}

# canccu_doctor <tree> <project or empty> <prefix>: every problem, one per line; fails when there
# is one
canccu_doctor() {
  local here=$1 only=$2 out="" hp p res tokens="" t
  out+=$(canccu_check_deps | sed 's/^  //')$'\n'
  out+=$(_doc_install "$3")$'\n'
  hp=$(canccu_host_profile)
  if [ -z "$hp" ]; then
    out+="HOST_PROFILE is not set ($(canccu_tilde "$CANCCU_ROOT")/config, or install.sh --host-profile max): the defaults apply"$'\n'
  elif ! canccu_host_conf "$hp" >/dev/null; then
    out+="HOST_PROFILE: no host profile '$hp' ($(canccu_host_where)). Profiles: $(canccu_host_profiles); the projects are not checked until it loads"$'\n'
    hp="-"
  fi
  if [ "$hp" != - ]; then
    for p in $(canccu_profiles); do
      [ -z "$only" ] || [ "$p" = "$only" ] || continue
      res=$( ( set --; CANCCU_PROJECT=$p
               # shellcheck source=canccu-common.sh
               . "$here/lib/canccu-common.sh" >/dev/null 2>&1 || exit 1
               _doc_project ) 2>/dev/null ) ||
        res=$( ( set --; CANCCU_PROJECT=$p; . "$here/lib/canccu-common.sh" ) 2>&1 >/dev/null | sed 's/^canccu-dispatcher: //' | head -n1)
      tokens+=$(grep '^@token ' <<<"$res" | cut -d' ' -f2-)$'\n'
      out+=$(grep -v '^@token ' <<<"$res" | grep . | sed "s/^/project $p: /")$'\n'
    done
    # no project: the token and the logins the global config sets
    if [ -z "$(canccu_profiles)" ]; then
      res=$( ( . "$here/lib/canccu-config.default"
               # shellcheck source=/dev/null
               [ "$hp" = "" ] || . "$(canccu_host_conf "$hp")"
               [ -f "$CANCCU_ROOT/config" ] && . "$CANCCU_ROOT/config"
               [ -n "$USER_LOGIN" ] || echo "USER_LOGIN is not set in $(canccu_tilde "$CANCCU_ROOT")/config"
               [ -n "$REVIEWER_LOGIN" ] || echo "REVIEWER_LOGIN is not set in $(canccu_tilde "$CANCCU_ROOT")/config"
               echo "@token $REVIEWER_TOKEN_FILE" ) 2>/dev/null )
      tokens+=$(grep '^@token ' <<<"$res" | cut -d' ' -f2-)$'\n'
      out+=$(grep -v '^@token ' <<<"$res")$'\n'
    fi
  fi
  while IFS= read -r t; do [ -n "$t" ] && out+=$(_doc_token "$t")$'\n'; done < <(sort -u <<<"$tokens")
  out=$(grep . <<<"$out")
  if [ -z "$out" ]; then echo "no problems found"; return 0; fi
  printf '%s\n' "$out"; return 1
}
