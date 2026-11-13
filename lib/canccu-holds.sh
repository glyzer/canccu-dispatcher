# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# lib/canccu-holds.sh — holds a pass keeps without a person: low disk (nothing new starts) and a
# GitHub rate limit (the pass does nothing until the reset). Sourced by lib/canccu-common.sh.

# ---------------------------------------------------------------- low disk

# disk_free_mb: the free MB of the file system the worktrees live on; nothing when df fails
disk_free_mb() {
  local d=$WORKERS_DIR
  [ -d "$d" ] || d=$CANCCU_HOME
  df -Pm "$d" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }'
}
# disk_low: free space is below DISK_MIN_MB; prints the free MB. An unreadable df holds nothing:
# a broken df must not stop every start.
disk_low() {
  local free; free=$(disk_free_mb)
  [[ $free =~ ^[0-9]+$ ]] || return 1
  echo "$free"
  (( free < ${DISK_MIN_MB:-200} ))
}
# disk_tick: the pass's disk check; true while it holds. The marker .disk-low makes the hold and
# its end one log line each, not one per pass.
disk_tick() {
  local free f="$CANCCU_HOME/.disk-low" d=$WORKERS_DIR
  [ -d "$d" ] || d=$CANCCU_HOME
  if free=$(disk_low); then
    if (( CANCCU_DRY )); then echo "  disk low: $free MB free for $d: nothing new starts"
    elif [ ! -e "$f" ]; then
      : > "$f"; log "disk: $free MB free for $d, below DISK_MIN_MB (${DISK_MIN_MB:-200}); nothing new starts"
      feed_open hold-disk po ask hold - - - "disk: $free MB free, below DISK_MIN_MB (${DISK_MIN_MB:-200}); nothing new starts"
    fi
    return 0
  fi
  if [ -e "$f" ] && (( ! CANCCU_DRY )); then
    rm -f "$f"; log "disk: ${free:-?} MB free again; starts resume"; feed_settle hold-disk "disk free again"
  fi
  return 1
}

# ---------------------------------------------------------------- GitHub rate limit

GH_LIMIT_RE='api rate limit exceeded|secondary rate limit|rate limit exceeded'
# gh_limit_seen <gh output>: a failed gh call's output names a rate limit → gh_limit holds the
# reset epoch. Only failed calls are read: a successful read's data (an issue body) may quote the
# words. The secondary limit has no reset to read; neither has a primary one whose read fails.
gh_limit_seen() {
  local r="" t=$1
  grep -qiE "$GH_LIMIT_RE" <<<"$t" || return 0
  (( CANCCU_DRY )) && return 0
  grep -qi 'secondary rate limit' <<<"$t" || r=$(guard 30 gh api rate_limit -q .resources.core.reset 2>/dev/null)
  [[ $r =~ ^[0-9]+$ ]] && (( r > $(now) )) || r=$(( $(now) + 900 ))
  echo "$r" > "$CANCCU_HOME/gh_limit"
}
# gh_limit_until: the reset epoch while the limit holds, else nothing
gh_limit_until() {
  local u; u=$(cat "$CANCCU_HOME/gh_limit" 2>/dev/null)
  [[ $u =~ ^[0-9]+$ ]] && (( u > $(now) )) && echo "$u"
  return 0
}
# gh_limit_tick: true while the pass must do nothing (logged once per limit); a limit that has
# passed is removed and logged.
gh_limit_tick() {
  local f="$CANCCU_HOME/gh_limit" u
  [ -e "$f" ] || return 1
  u=$(gh_limit_until)
  if [ -n "$u" ]; then
    warn_once gh-limit "GitHub rate limit: passes pause until $(iso "$u")"
    feed_open hold-github - info hold - - - "GitHub rate limit: passes pause until $(iso "$u")"; return 0
  fi
  (( CANCCU_DRY )) && return 1
  rm -f "$f" "$CANCCU_HOME/.warned-gh-limit"; log "GitHub rate limit over; passes resume"
  feed_settle hold-github "the rate limit is over"
  return 1
}
