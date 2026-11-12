# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the usage throttle. Every claude run's
# stream carries a rate_limit_event with the account's 5-hour and weekly usage shares
# (unifiedWindows.five_hour / seven_day: utilization, resetsAt); lib/canccu-stream.py writes the
# newest one to workers/usage.json. One Claude account serves every project, so the newest file of
# all projects counts. No reading at all: nothing is throttled, and the limit messages (the
# usage-limit back-off) stay the fallback. docs/canccu-dispatch.md, "Usage throttle".

# usage_read → "<5-hour %|-> <weekly %|-> <5-hour reset|-> <weekly reset|-> <reading time|->"; a
# window whose reset has passed counts as 0 %. A stale reading keeps only its time: older than
# USAGE_MAX_AGE_MIN, or than this dispatcher's start (dispatch.pid): nothing new starts in drain,
# so no run would ever replace a reading of another account or of long ago.
usage_read() {
  local f best="" bt=0 t p max=${USAGE_MAX_AGE_MIN:-360}
  for f in "$CANCCU_ROOT"/projects/*/workers/usage.json; do
    [ -f "$f" ] || continue
    t=$(jq -r '.at // 0' "$f" 2>/dev/null) || continue
    [[ $t =~ ^[0-9]+$ ]] && (( t > bt )) && { bt=$t best=$f; }
  done
  [ -n "$best" ] || { echo "- - - - -"; return 0; }
  [[ $max =~ ^[0-9]+$ ]] || max=360
  p=$(stat -c %Y "$CANCCU_HOME/dispatch.pid" 2>/dev/null) || p=0
  if { (( max > 0 )) && (( $(now) - bt > max * 60 )); } || (( bt < p )); then echo "- - - - $bt"; return 0; fi
  jq -r --argjson now "$(now)" '.at as $at | (.info.unifiedWindows // {}) as $w
    | def pct($x): if $x == null or $x.utilization == null then "-"
                   elif ($x.resetsAt // 0) > 0 and ($x.resetsAt // 0) <= $now then "0"
                   else ($x.utilization * 100 | round | tostring) end;
      def rs($x): ($x.resetsAt // null) | if . == null then "-" else tostring end;
      [pct($w.five_hour), pct($w.seven_day), rs($w.five_hour), rs($w.seven_day), ($at | tostring)] | join(" ")' "$best" 2>/dev/null ||
    echo "- - - - -"
}
# usage_state → normal, slow (5-hour ≥ USAGE_SLOW), stop (≥ USAGE_STOP) or drain (weekly ≥
# USAGE_WEEKLY_DRAIN, below the stop); cached for the pass in USAGE_NOW
usage_state() {
  local f w
  [ -n "${USAGE_NOW:-}" ] || USAGE_NOW=$(usage_read)
  read -r f w _ <<<"$USAGE_NOW"
  if [[ $f =~ ^[0-9]+$ ]] && (( f >= USAGE_STOP )); then echo stop
  elif [[ $w =~ ^[0-9]+$ ]] && (( w >= USAGE_WEEKLY_DRAIN )); then echo drain
  elif [[ $f =~ ^[0-9]+$ ]] && (( f >= USAGE_SLOW )); then echo slow
  else echo normal; fi
}
# usage_cap: how many runs may run over all projects: 0 at the stop, 1 when slow, else TOTAL_CAP
# from the 5-hour share alone: drain mode (weekly) keeps the slow cap too
usage_cap() {
  local f; read -r f _ <<<"${USAGE_NOW:-$(usage_read)}"
  if [[ $f =~ ^[0-9]+$ ]] && (( f >= USAGE_STOP )); then echo 0
  elif [[ $f =~ ^[0-9]+$ ]] && (( f >= USAGE_SLOW )); then echo $(( TOTAL_CAP < 1 ? TOTAL_CAP : 1 ))
  else echo "$TOTAL_CAP"; fi
}
# draining: weekly drain mode: nothing new starts (packages, planner waves, health, the fast
# lane); started work finishes its whole pipeline
draining() { [ "$(usage_state)" = drain ]; }
# usage_text: "5-hour 42% · weekly 50% (12 min old)" and the throttle, e.g. "draining (weekly 92%)
# (12 min old)"; "usage unknown (last reading 7 h old)" for a stale reading
usage_text() {
  local f w at age; read -r f w _ _ at <<<"${USAGE_NOW:-$(usage_read)}"
  [[ $at =~ ^[0-9]+$ ]] || { echo "usage unknown"; return 0; }
  age=$(( ($(now) - at) / 60 )); (( age < 0 )) && age=0
  if (( age < 60 )); then age="$age min old"; else age="$(( age / 60 )) h old"; fi
  case $(usage_state) in
    stop) echo "stopping (5-hour $f%) ($age)" ;; drain) echo "draining (weekly $w%) ($age)" ;;
    slow) echo "one run at a time (5-hour $f%) ($age)" ;;
    *) [ "$f" = - ] && echo "usage unknown (last reading $age)" || echo "5-hour $f% · weekly $w% ($age)" ;;
  esac
}
# usage_tick: at the stop, each running worker gets the nudge (its .nudge file), once per run
usage_tick() {
  local k s
  [ "$(usage_state)" = stop ] || return 0
  while read -r k s; do
    case $k in ''|review-*|answer-*|plan-*) continue ;; esac
    is_managed "$k" && [ -z "$(st_get "$k" nudged)" ] || continue
    (( CANCCU_DRY )) || touch "$WORKERS_DIR/$REPO_NAME-$k.nudge"
    st_set "$k" nudged=1 nudge_reset="$(usage_reset_at)"
    log "#$k: usage at $(usage_text): asked to stop at a safe point; it resumes after the reset"
  done < <(live_runs)
}
# usage_reset_at: when the 5-hour window resets (plus USAGE_MARGIN), else in 30 min
usage_reset_at() {
  local r; read -r _ _ r _ <<<"${USAGE_NOW:-$(usage_read)}"
  if [[ $r =~ ^[0-9]+$ ]] && (( r > $(now) )); then echo $(( r + ${USAGE_MARGIN:-120} )); else echo $(( $(now) + 1800 )); fi
}
