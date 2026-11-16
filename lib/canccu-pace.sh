# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): pacing (PACE). One account's weekly limit
# has to last the week: the weekly share is compared with the share of the week gone, and a project
# ahead by more than PACE_MARGIN points is told (notify), held to PACE_CAP runs over all projects
# (cap), or starts nothing new (pause). Pacing never writes CAP or TOTAL_CAP: it ends by itself
# once the week catches up. An unknown or stale reading is never ahead, so a run can refresh it.

# pace_read → "<weekly %> <gone %> <points ahead>" from the pass's reading; nothing when unknown.
# gone: the share of the week since the weekly window started (its reset minus 7 days), rounded.
pace_read() {
  local w r s g
  read -r _ w _ r _ <<<"${USAGE_NOW:-$(usage_read)}"
  [[ $w =~ ^[0-9]+$ && $r =~ ^[0-9]+$ ]] || return 0
  s=$(( $(now) - (r - 604800) ))
  g=$(( (200 * s + 604800) / 1209600 )); (( s < 0 )) && g=0; (( g > 100 )) && g=100
  echo "$w $g $(( w - g ))"
}
# pace_margin: PACE_MARGIN, or its default when it is no number
pace_margin() { [[ ${PACE_MARGIN:-10} =~ ^[0-9]+$ ]] && echo "${PACE_MARGIN:-10}" || echo 10; }
# pace_mode: PACE when pacing is on (notify, cap or pause), else nothing
pace_mode() { case ${PACE:-off} in notify|cap|pause) echo "$PACE" ;; esac; }
# pace_ahead: pacing is on and the reading is more than PACE_MARGIN points ahead of the week
pace_ahead() {
  local d
  [ -n "$(pace_mode)" ] || return 1
  read -r _ _ d <<<"$(pace_read)"
  [[ $d =~ ^-?[0-9]+$ ]] && (( d > $(pace_margin) ))
}
# pace_holds: PACE=pause and ahead: nothing new starts, a resume neither
pace_holds() { [ "$(pace_mode)" = pause ] && pace_ahead; }
# pace_cap: the runs PACE=cap allows over all projects while ahead (PACE_CAP, at least 1)
pace_cap() { [[ ${PACE_CAP:-1} =~ ^[1-9][0-9]*$ ]] && echo "${PACE_CAP:-1}" || echo 1; }
# pace_effect: what the mode does while ahead, in words
pace_effect() {
  case $(pace_mode) in
    notify) echo "notice only" ;; cap) echo "at most $(pace_cap) run(s) at once over all projects" ;; pause) echo "nothing new starts" ;;
  esac
}

# pace_tick: the pass's transitions, each logged once. $CANCCU_HOME/pace (since=<epoch>, mode=<PACE>)
# exists while ahead; PACE=pause also keeps a hold line in the feed. PACE changed while ahead is a
# transition too: the hold line follows the mode. An unknown reading changes nothing.
pace_tick() {
  local f="$CANCCU_HOME/pace" r w g d m o hold
  m=$(pace_mode)
  if [ -z "$m" ]; then
    [ -e "$f" ] && (( ! CANCCU_DRY )) && { rm -f "$f"; feed_settle hold-pace "PACE is off"; }
    return 0
  fi
  r=$(pace_read); [ -n "$r" ] || return 0
  read -r w g d <<<"$r"
  (( CANCCU_DRY )) && return 0
  hold="pace: weekly usage $w% is ahead of the week; nothing new starts until it is back on pace"
  if (( d > $(pace_margin) )); then
    if [ -e "$f" ]; then
      o=$(sed -n 's/^mode=//p' "$f")
      [ "$o" = "$m" ] && return 0
      printf 'since=%s\nmode=%s\n' "$(pace_since)" "$m" > "$f"
      log "pace: PACE is now $m while $d points ahead: $(pace_effect)"
      [ "$o" = pause ] && feed_settle hold-pace "PACE is now $m"
      [ "$m" = pause ] && feed_open hold-pace - info hold - - - "$hold"
      return 0
    fi
    printf 'since=%s\nmode=%s\n' "$(now)" "$m" > "$f"
    log "pace: weekly usage $w% is $d points ahead of the week ($g% gone, PACE_MARGIN $(pace_margin)); PACE=$m: $(pace_effect)"
    [ "$m" = pause ] && feed_open hold-pace - info hold - - - "$hold"
  elif [ -e "$f" ]; then
    rm -f "$f"
    log "pace: back on pace (weekly $w%, $g% of the week gone); PACE=$m no longer limits runs"
    feed_settle hold-pace "back on pace"
  fi
  return 0
}
# pace_since: the epoch the project went ahead, or nothing
pace_since() { sed -n 's/^since=\([0-9]*\)$/\1/p' "$CANCCU_HOME/pace" 2>/dev/null; }

# pace_digest: the digest's section, only with PACE on
pace_digest() {
  local m r w g d s
  m=$(pace_mode); [ -n "$m" ] || return 0
  r=$(pace_read)
  [ -n "$r" ] || { echo "**Pace:** weekly usage unknown (no fresh reading)"; return 0; }
  read -r w g d <<<"$r"; s=$(pace_since)
  if [ -n "$s" ]; then echo "**Pace:** ahead by $d points since $(iso "$s") (PACE=$m); weekly $w%, $g% of the week gone"
  else echo "**Pace:** on pace; weekly $w%, $g% of the week gone"; fi
}
