# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the slots a start may take, under the
# project's CAP and its fair share of TOTAL_CAP. docs/canccu-dispatch.md, "Fair share of TOTAL_CAP".
#
# Each pass writes the project's wait to its file `want`: how many runs it could not start for
# want of a shared slot, its CAP, and until when that holds (two passes and a margin, so the wait
# of a dispatcher that stopped ends by itself). A project alone fills TOTAL_CAP; a free slot goes
# to the waiting project with the fewest runs, so a busy project yields at its next start while
# another one waits. Nothing running is ever stopped. Only the projects' lock and want files
# decide: there is no daemon.

# SLOT_REFUSED: the engine's exit when no shared slot is free for the start (TOTAL_CAP, the usage
# cap or the fair share): the caller counts the unit as waiting. 75 is EX_TEMPFAIL, which neither
# the engine's other refusals (1) nor the worker's (2) use.
SLOT_REFUSED=75

declare -gA WANT_KEYS=()   # the units this pass could not start for want of a shared slot
# want_slot <key>: note the unit as waiting, unless the project's own CAP is what holds it
want_slot() { [ -n "${1:-}" ] && (( $(running_count) < CAP )) && WANT_KEYS[$1]=1; return 0; }
# want_write: the pass's wait, for the other projects' dispatchers and canccu-status. Written by
# every pass, also one that ends early with no wait, so an old wait never outlives its cause.
want_write() {
  (( CANCCU_DRY )) && return 0
  printf 'n=%s\ncap=%s\nuntil=%s\n' "${#WANT_KEYS[@]}" "$CAP" "$(( $(now) + 2 * INTERVAL + 300 ))" \
    > "$CANCCU_HOME/want.tmp" && mv -f "$CANCCU_HOME/want.tmp" "$CANCCU_HOME/want"
}
# want_of <project dir>: "<waiting runs> <CAP>" while its wait holds, else "0 0"
want_of() {
  local f=$1/want n c u
  n=$(lock_get "$f" n) c=$(lock_get "$f" cap) u=$(lock_get "$f" until)
  if [[ $n =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $u =~ ^[0-9]+$ ]] && (( u > $(now) )); then echo "$n $c"; else echo "0 0"; fi
}

# last_start <project dir>: when the project's engine last started a run (ns; 0: never)
last_start() { local v; v=$(cat "$1/last_start" 2>/dev/null); [[ $v =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
# tie_first <project dir>: on a tie in runs that waiting project goes first: it started a run
# before this one did (by name when both started at the same moment). Exactly one of two tied
# projects yields, so no slot stays idle, and a waiter gets the next freed slot even when the
# busy project's ending run leaves the two level.
tie_first() {
  local o m; o=$(last_start "$1") m=$(last_start "$CANCCU_HOME")
  (( o < m )) || { (( o == m )) && [[ ${1##*/} < $CANCCU_PROJECT ]]; }
}
# owed: "<slots> <project>": the free slots owed to the other projects that wait with fewer runs
# than this one, or as many and first on the tie (each up to this one's count, its wait and its
# CAP), and the first of them
owed() {
  local d mine r n c o sum=0 first=""
  mine=$(running_count)
  for d in "$CANCCU_ROOT"/projects/*/; do
    d=${d%/}; [ "${d##*/}" = "$CANCCU_PROJECT" ] && continue
    read -r n c <<<"$(want_of "$d")"; (( n > 0 )) || continue
    r=$(count_live "$d"/workers/*.lock)
    o=$(( mine - r )); (( o == 0 )) && tie_first "$d" && o=1
    (( n < o )) && o=$n; (( c - r < o )) && o=$(( c - r ))
    (( o > 0 )) || continue
    sum=$(( sum + o )); [ -n "$first" ] || first=${d##*/}
  done
  echo "$sum $first"
}
# share_free: the shared slots this project may take now: the free ones less those owed
share_free() { local o _; read -r o _ <<<"$(owed)"; echo $(( $(total_cap) - $(total_running) - o )); }

# room [key]: one run may start now (own CAP, fair share); a key held by the share waits
room() {
  (( $(running_count) < CAP )) || return 1
  (( $(share_free) > 0 )) && return 0
  want_slot "${1:-}"; return 1
}
# free_slots: how many runs may start now under CAP and the fair share (may be 0 or less)
free_slots() {
  local a b; a=$(( CAP - $(running_count) )) b=$(share_free)
  echo $(( a < b ? a : b ))
}

# waiting_for: the projects holding the slots this one waits for (busiest first), or nothing
# when it does not wait (canccu-status)
waiting_for() {
  local n _ d
  read -r n _ <<<"$(want_of "$CANCCU_HOME")"; (( n > 0 )) || return 0
  for d in "$CANCCU_ROOT"/projects/*/; do
    d=${d%/}; [ "${d##*/}" = "$CANCCU_PROJECT" ] && continue
    printf '%s %s\n' "$(count_live "$d"/workers/*.lock)" "${d##*/}"
  done | awk '$1 > 0' | sort -k1,1nr -k2 | awk '{ print $2 }' | paste -sd, | sed 's/,/, /g'
}

# ---------------------------------------------------------------- the pass's slots

START_FREE=0   # the slots this pass may still start (set by the pass, taken by every start)
# OWN_FREE: the starts CAP still allows this pass after the project's own reservations. A unit
# held back while it is above 0 is held by the shared slots, so it waits for one; held back by
# the reservations (a review or an answerer of its own about to start), it is no wait.
OWN_FREE=0
want_held() { (( OWN_FREE > 0 )) && want_slot "$1"; return 0; }
# take_slot <key>: a slot for the unit; held back by the shared slots, it waits (want_held)
take_slot() { if (( START_FREE > 0 )); then room "${1:-}"; else want_held "${1:-}"; return 1; fi; }
took_slot() { START_FREE=$(( START_FREE - 1 )) OWN_FREE=$(( OWN_FREE - 1 )); }
