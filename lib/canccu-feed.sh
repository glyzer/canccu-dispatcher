# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# lib/canccu-feed.sh — the event feed of docs/plan/contracts.md §3: one line in $CANCCU_HOME/events
# per change of state a person must act on, and the heartbeat every pass touches. Sourced by
# lib/canccu-common.sh; `canccu-dispatcher wait` sources it alone (feed_wait needs only
# CANCCU_HOME). The log stays as it is: the feed is in addition to it.

declare -F now >/dev/null || now() { echo "${CANCCU_NOW:-$(date +%s)}"; }
feed_file() { echo "$CANCCU_HOME/events"; }
# feed.open: key=id of the open items that have no unit state of their own (holds, checkpoints, PRs)
feed_open_file() { echo "$CANCCU_HOME/feed.open"; }

# feed <owner> <class> <kind> <unit> <pr> <url> <text>: appends one line and prints its id. The
# id is read and the line written under the file's own lock: two writers never share an id.
feed() {
  local f a=() x; f=$(feed_file)
  (( ${CANCCU_DRY:-0} )) && return 0
  for x in "$@"; do x=${x//[$'\t\n\r']/ }; a+=("${x:--}"); done
  ( flock -w 30 9 || exit 1
    id=$(tail -n 1 "$f" 2>/dev/null | cut -f2)
    [[ $id =~ ^[0-9]+$ ]] || id=0
    id=$((id + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(iso "$(now)")" "$id" "${a[@]:0:6}" "${a[6]:0:200}" >> "$f" || exit 1
    echo "$id" ) 9>>"$(kv_lock "$f")"
}
# feed_closed <id> <new state> [unit]: the line that settles item <id>
feed_closed() { feed - info closed "${3:--}" - - "closes $1: $2" >/dev/null; }
# feed_kind_of <id>: the kind of the line <id>
feed_kind_of() { awk -F '\t' -v i="$1" '$2 == i { print $5 }' "$(feed_file)" 2>/dev/null; }

# feed_open <key> <owner> <class> <kind> <unit> <pr> <url> <text>: one line for an item with no unit
# state, written once while the item stays open
feed_open() {
  local key=$1 id; shift
  [ -n "$(kv_get "$(feed_open_file)" feed "$key")" ] && return 0
  id=$(feed "$@") && [ -n "$id" ] && kv_set "$(feed_open_file)" feed "$key=$id"
  return 0
}
# feed_settle <key> <new state>: the item no longer waits: its closed line, once
feed_settle() {
  local id; id=$(kv_get "$(feed_open_file)" feed "$1")
  [ -n "$id" ] || return 0
  feed_closed "$id" "$2"; kv_set "$(feed_open_file)" feed "$1="
}
feed_open_keys() { sed -n "s/^\($1[^=]*\)=[0-9].*/\1/p" "$(feed_open_file)" 2>/dev/null; }

# ---------------------------------------------------------------- a unit's waiting items

# feed_ny_kind <K>: the feed kind of a unit in needs-you: a run that ended with nothing to show is
# run-ended, told apart by needs_you's reason
feed_ny_kind() {
  case $(st_get "$1" ny_kind) in plan) echo plan; return 0 ;; question) echo question; return 0 ;; esac
  case $(st_get "$1" reason) in
    "the worker stopped:"*|"the worker finished without an open PR"*|"the worker's run was denied commands and opened no PR"*) echo run-ended ;;
    *) echo needs-you ;;
  esac
}
feed_url() { if [ -n "$2" ]; then pr_url "$2"; else issue_url "$1"; fi; }

# feed_unit_moved <K> <old phase> <new phase>: unit_moved's part: a waiting item settles (one
# closed line) when the unit leaves it, and entering accept or needs-you writes one line. The
# same phase written again with the same kind is "still waiting": no line.
feed_unit_moved() {
  local k=$1 new=$3 id kind pr r
  id=$(st_get "$k" idle_ev)
  if [ -n "$id" ] && [ "$2" != "$new" ]; then feed_closed "$id" "$new" "$k"; _st_put "$k" idle_ev=; fi
  case $new in accept) kind=accept ;; needs-you) kind=$(feed_ny_kind "$k") ;; *) kind="" ;; esac
  id=$(st_get "$k" ev_id)
  if [ -n "$id" ]; then
    [ -n "$kind" ] && [ "$kind" = "$(feed_kind_of "$id")" ] && return 0
    feed_closed "$id" "$new" "$k"; _st_put "$k" ev_id=
  fi
  [ -n "$kind" ] || return 0
  pr=$(st_get "$k" pr); r=$(st_get "$k" reason)
  id=$(feed "$(st_get "$k" owner)" ask "$kind" "$k" "$pr" "$(feed_url "$k" "$pr")" "#$k $kind: ${r#manual: }")
  [ -z "$id" ] || _st_put "$k" ev_id="$id"
}

# ---------------------------------------------------------------- the pass's part

# feed_heartbeat: the pass is alive (wait reads its age)
feed_heartbeat() { (( ${CANCCU_DRY:-0} )) || touch "$CANCCU_HOME/heartbeat"; }

# feed_tick <open unit...>: the items no unit write announces: the usage back-off, our PRs labelled
# needs-you, and the idle alarm
feed_tick() {
  local pr n k
  if backing_off; then feed_open hold-usage - info hold - - - "usage back-off: nothing new starts until $(iso "$(backoff_until)")"
  else feed_settle hold-usage "the back-off is over"; fi
  local open=" "
  for pr in $(jqr '.[] | select(any(.labels[]?; .name == "needs-you")) | .number' <<<"${PRS:-[]}"); do
    n=$(ping_pr_issue "$pr"); [ -n "$n" ] || continue
    open+="pr-$pr "; k=$(unit_of_issue "$n")
    feed_open "pr-$pr" "$(need_owner "$k" pr-needs-you)" ask pr-needs-you "$k" "$pr" "$(pr_url "$pr")" "PR #$pr needs-you"
  done
  for k in $(feed_open_keys pr-); do [[ $open == *" $k "* ]] || feed_settle "$k" "no needs-you"; done
  feed_idle "$@"
}

# feed_idle <open unit...>: a unit no rule moved for IDLE_ALARM_MIN writes one idle line until its
# phase changes. Paused or backing off, the stillness is explained (a hold line, or your pause).
feed_idle() {
  local k ph at min pr id live
  paused && return 0; backing_off && return 0
  live=" $(live_runs | cut -d' ' -f1 | tr '\n' ' ') "
  for k; do
    [ -z "$(st_get "$k" idle_ev)" ] || continue
    # waiting: blocked by another issue; stopped: by you (canccu-stop)
    ph=$(st_get "$k" phase); case $ph in ""|accept|needs-you|waiting|stopped) continue ;; esac
    pr=$(st_get "$k" pr)
    [[ $live == *" $k "* || $live == *" review-$pr "* || $live == *" answer-$k "* ]] && continue
    at=$(st_get "$k" phase_at)
    # a unit from before phase_at: its clock starts now
    [[ $at =~ ^[0-9]+$ ]] || { _st_put "$k" phase_at="$(now)"; continue; }
    min=$(( ($(now) - at) / 60 ))
    (( min >= ${IDLE_ALARM_MIN:-60} )) || continue
    id=$(feed "$(owner_of "$k" idle)" ask idle "$k" "$pr" "$(feed_url "$k" "$pr")" "#$k sits in $ph for $min min with nothing running")
    [ -z "$id" ] || _st_put "$k" idle_ev="$id"
  done
}

# ---------------------------------------------------------------- wait

# feed_wait <owner or empty> <ack or empty>: blocks until a line with an id above ack (default: the
# last id now) for that owner (lines of owner - only without one), prints it, returns 0; returns
# 3 when the heartbeat is older than 10 minutes. It polls: no inotify dependency.
feed_wait() {
  local owner=$1 ack=$2 f hb age l
  f=$(feed_file); hb=$CANCCU_HOME/heartbeat
  [ -n "$ack" ] || { ack=$(tail -n 1 "$f" 2>/dev/null | cut -f2); [[ $ack =~ ^[0-9]+$ ]] || ack=0; }
  while :; do
    l=$(awk -F '\t' -v a="$ack" -v o="$owner" '$2 + 0 > a + 0 && (o == "" || $3 == o) { print; exit }' "$f" 2>/dev/null)
    [ -n "$l" ] && { printf '%s\n' "$l"; return 0; }
    if [ -e "$hb" ]; then age=$(( ($(now) - $(stat -c %Y "$hb")) / 60 )); else age=""; fi
    if [ -z "$age" ]; then echo "heartbeat stale: none written yet; the dispatcher may be down"; return 3; fi
    (( age < 10 )) || { echo "heartbeat stale: $age min; the dispatcher may be down"; return 3; }
    sleep "${CANCCU_WAIT_EVERY:-5}"
  done
}
