# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the leader's toolkit (docs/reference/lead-tools.md).
# `canccu-dispatcher watch` waits for the log lines and files the leader acts on, `canccu-dispatcher
# stall` names what is stuck without a log line saying so, `canccu-status --pace` shows the pace.
# Both commands only read: they never write the log, the feed or GitHub.

# the stall thresholds are fixed (#216): the values the lead tested
STALL_CI_MIN=60 STALL_LOG_S=10800 STALL_EVERY_S=10800

# ---------------------------------------------------------------- stall

# stall_seen_ok <key>: the key was not printed in the last 3 hours; records it now
stall_seen_ok() {
  local f="$CANCCU_HOME/stall.seen" t
  t=$(awk -F '\t' -v k="$1" '$1 == k { t = $2 } END { print t + 0 }' "$f" 2>/dev/null)
  (( t > 0 && $(now) - t < STALL_EVERY_S )) && return 1
  { grep -v -P "^\Q$1\E\t" "$f" 2>/dev/null; printf '%s\t%s\n' "$1" "$(now)"; } > "$f.tmp" && mv -f "$f.tmp" "$f"
}
# stall_line <key> <text>: prints the text unless its key was printed in the last 3 hours
stall_line() { stall_seen_ok "$1" && echo "stall: $2"; return 0; }

# lead_stall: one line per stuck item. A gh error skips that kind: the others still print.
lead_stall() {
  local p n id wf st min m age
  if p=$(ghj pr list -R "$REPO" -s open -L 300 --author "$USER_LOGIN" --json number,author,mergeable); then
    # gh fills --author; the login is checked again so a mixed answer never names someone else's PR
    for n in $(jqr --arg u "$USER_LOGIN" '.[] | select(.author.login == $u and .mergeable == "CONFLICTING") | .number' <<<"$p"); do
      stall_line "pr-$n" "PR #$n conflicts with main (no CI runs until it merges main)"
    done
  fi
  if p=$(ghj run list -R "$REPO" --status in_progress -L 50 --json databaseId,workflowName,startedAt); then
    while IFS=$'\t' read -r id wf st; do
      st=$(iso_epoch "$st"); [ -n "$st" ] || continue
      min=$(( ($(now) - st) / 60 ))
      (( min > STALL_CI_MIN )) && stall_line "ci-$id" "CI run $id ($wf) in progress for $min min"
    done < <(jqr '.[] | [.databaseId, .workflowName, .startedAt] | @tsv' <<<"$p")
  fi
  # a missing log is no silence: the dispatcher never ran here
  age=$(stat -c %Y "$CANCCU_HOME/dispatch.log" 2>/dev/null) || return 0
  age=$(( $(now) - age ))
  (( age > STALL_LOG_S )) || return 0
  for m in "$CANCCU_HOME"/steps/*; do
    m=${m##*/}; [[ $m =~ ^[0-9]+$ ]] || continue
    [ "$(step_get "$m" phase)" = running ] || continue
    stall_line "log-$m" "dispatch.log silent for $(( age / 3600 )) h while step $(safe_title "$(step_get "$m" title)") is running"
  done
  return 0
}

# ---------------------------------------------------------------- watch

# watch_offsets: "<path>\t<bytes>" per file read so far
watch_offsets() { echo "$CANCCU_HOME/watch.offsets"; }
# watch_new <path> <offset> → the whole new lines from offset (a shorter file: from 0), then a last
# line with the new offset. A line without its newline is left for the next read: a writer may be
# halfway through it.
watch_new() {
  local LC_ALL=C f=$1 o=$2 s chunk   # C: ${#chunk} counts bytes, as the offset does
  s=$(stat -c %s "$f" 2>/dev/null) || s=0
  (( s < o )) && o=0
  chunk=$(tail -c +"$((o + 1))" "$f" 2>/dev/null | head -c "$((s - o))"; echo x); chunk=${chunk%x}
  chunk=${chunk%"${chunk##*$'\n'}"}
  printf '%s' "$chunk"
  echo "$((o + ${#chunk}))"
}

# lead_watch <settle s> <match ERE> <file>...: waits for the next event, prints it, exits 0. The
# project's dispatch.log counts its lines that match; every line of a file counts and exits at
# once; a stall line counts like a log line. Any other hit waits the settle, collects again and
# prints all. The first run starts at each file's end. 3: the heartbeat is stale.
lead_watch() {
  local settle=$1 match=$2 log="$CANCCU_HOME/dispatch.log" f l o hb out="" now_hit="" got
  shift 2
  declare -A off=()
  local -a files=("$log" "$@")
  for f in "${files[@]}"; do
    o=$(awk -F '\t' -v p="$f" '$1 == p { o = $2 } END { print o }' "$(watch_offsets)" 2>/dev/null)
    [[ $o =~ ^[0-9]+$ ]] || o=$(stat -c %s "$f" 2>/dev/null || echo 0)
    off[$f]=$o
  done
  # _watch_collect: appends the new hits to out; sets now_hit for a line of a --file
  _watch_collect() {
    local f i=0 r n
    for f in "${files[@]}"; do
      r=$(watch_new "$f" "${off[$f]}"); n=${r##*$'\n'}; r=${r%"$n"}; off[$f]=$n
      [ -n "$r" ] || { i=$((i + 1)); continue; }
      if (( i == 0 )); then r=$(grep -E -- "$match" <<<"$r")
      else now_hit=1; r=${r%$'\n'}; fi
      [ -n "$r" ] && out+="$r"$'\n'
      i=$((i + 1))
    done
  }
  # _watch_save: the offsets of this run's files; the lines of the files another run reads stay
  _watch_save() {
    local f w; w=$(watch_offsets)
    { awk -F '\t' 'NR == FNR { mine[$0] = 1; next } !($1 in mine)' <(printf '%s\n' "${!off[@]}") "$w" 2>/dev/null
      for f in "${!off[@]}"; do printf '%s\t%s\n' "$f" "${off[$f]}"; done; } > "$w.tmp" && mv -f "$w.tmp" "$w"
  }
  local last_stall=-600
  while :; do
    _watch_collect
    # the stall check: at the start, then every 10 minutes
    if (( SECONDS - last_stall >= 600 )); then last_stall=$SECONDS; got=$(lead_stall); [ -n "$got" ] && out+="$got"$'\n'; fi
    if [ -n "$out" ]; then
      if [ -z "$now_hit" ]; then sleep "$settle"; _watch_collect; fi
      _watch_save; printf '%s' "$out"; return 0
    fi
    _watch_save
    hb=$(heartbeat_stale); [ -n "$hb" ] && { echo "$hb"; return 3; }
    sleep "${CANCCU_WAIT_EVERY:-20}"
  done
}

# ---------------------------------------------------------------- pace

# pace_report: canccu-status --pace. The weekly reading against the week, what PACE does, and this
# project's spend per day of the last 7 days (UTC), from spend.log.
pace_report() {
  local r w g d rs s d0 i a sl="$WORKERS_DIR/spend.log"
  [ -f "$sl" ] || sl=/dev/null
  r=$(pace_read)
  if [ -n "$r" ]; then
    read -r w g d <<<"$r"; read -r _ _ _ rs _ <<<"${USAGE_NOW:-$(usage_read)}"
    if (( d >= 0 )); then a="$d points ahead"; else a="$(( -d )) points behind"; fi
    echo "weekly $w% · $g% of the week gone · $a · resets $(iso "$rs")"
  else echo "weekly usage unknown (no fresh reading)"; fi
  s=$(pace_since)
  echo "PACE=${PACE:-off} · margin $(pace_margin) · $( [ -n "$s" ] && echo "ahead since $(iso "$s"): $(pace_effect)" || echo "on pace")"
  echo "spend of this project's runs, last 7 days (UTC), newest first:"
  d0=$(date -u -d "$(date -u -d "@$(now)" +%F)" +%s)
  for i in 0 1 2 3 4 5 6; do
    a=$(( d0 - i * 86400 ))
    awk -F '\t' -v a="$a" -v b="$((a + 86400))" -v r="$REPO_NAME" -v day="$(date -u -d "@$a" +%F)" \
      '$1 >= a && $1 < b && $2 == r { n++; if ($4 ~ /^[0-9]+(\.[0-9]+)?$/) s += $4 }
       END { printf "  %s $%.2f (%d runs)\n", day, s, n }' "$sl"
  done
}
