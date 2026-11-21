# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by lib/canccu-notify.sh, never run): what keeps Telegram quiet
# (docs/reference/notify.md): the queue an item waits in (the batch window, quiet hours, the daily
# cap), the batch that sends it, the day's digest and the listener that reads replies as they come.
# Class interrupt never waits: notify_event sends it at once. The records, next to those of
# lib/canccu-notify.sh and under the same lock:
#   queue    <feed id> <epoch queued> <q: held by quiet hours, else ->
#   pushed   <day> <what>: one line per message that rang the phone (an item, or a batch)
#   capped   the day the cap line was sent; digest: the day the digest went
#   listen.beat   touched by the listener on each read; .listen.lock its lock, held while it lives

# notify_clock <date args...>: date at now, on QUIET_TZ's clock (empty: the host's)
notify_clock() {
  if [ -n "${QUIET_TZ:-}" ]; then TZ=$QUIET_TZ date -d "@$(now)" "$@"; else date -d "@$(now)" "$@"; fi
}
# notify_quiet_range: QUIET_HOURS as "<from> <to>" (hours); 1 when it is empty or no range
notify_quiet_range() {
  [[ ${QUIET_HOURS:-} =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]] || return 1
  local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
  (( a < 24 && b < 24 && a != b )) || return 1
  echo "$a $b"
}
# notify_quiet: now is in the quiet hours (22-07 runs over midnight)
notify_quiet() {
  local r a b h
  r=$(notify_quiet_range) || return 1
  read -r a b <<<"$r"; h=$(notify_clock +%-H)
  if (( a < b )); then (( h >= a && h < b )); else (( h >= a || h < b )); fi
}

notify_day() { notify_clock +%F; }
notify_count() { nt_add pushed "$(notify_day)	${1:-item}"; }
# notify_capped: today's messages reached NOTIFY_MAX_PER_DAY (an interrupt is never counted)
notify_capped() {
  local n; n=$(awk -F '\t' -v d="$(notify_day)" '$1 == d { c++ } END { print c + 0 }' "$(notify_dir)/pushed" 2>/dev/null)
  (( ${n:-0} >= ${NOTIFY_MAX_PER_DAY:-12} ))
}
# notify_holds: an item may not go at once now
notify_holds() {
  (( ${NOTIFY_BATCH_MIN:-10} > 0 )) || notify_quiet || notify_capped
}
notify_queue_add() {
  [ -n "$(nt_get queue "$1" 1)" ] && return 0
  nt_add queue "$1	$(now)	$(notify_quiet && echo q || echo -)"
  notify_capped && notify_cap_line
  return 0
}
# notify_cap_line: once a day, the one message that says the cap is reached
notify_cap_line() {
  local d w; d=$(notify_day)
  [ "$(cat "$(notify_dir)/capped" 2>/dev/null)" = "$d" ] && return 0
  if [ -n "${NOTIFY_DIGEST_HOUR:-}" ]; then w="for the digest at $(printf '%02d' "$((10#$NOTIFY_DIGEST_HOUR))"):00"; else w="until tomorrow"; fi
  # a failed try is not tried again: the items wait either way, and the digest lists them
  tg_send "canccu: the daily cap of ${NOTIFY_MAX_PER_DAY:-12} messages (NOTIFY_MAX_PER_DAY) is reached for project $CANCCU_PROJECT: the rest waits $w." - - >/dev/null ||
    log "telegram: sending the cap line failed"
  echo "$d" > "$(notify_dir)/capped"
}

# notify_unit_open <unit>: the unit has an ask in the feed that no closed line settled yet
notify_unit_open() {
  awk -F '\t' -v u="$1" '
    $6 == u && $4 == "ask" && $5 != "idle" { o[$2] = 1 }
    $5 == "closed" && $9 ~ /^closes [0-9]+/ { split(substr($9, 8), x, ":"); delete o[x[1]] }
    END { for (i in o) f = 1; exit !f }' "$(feed_file)" 2>/dev/null
}
# notify_line <feed id>: the feed line's fields, tab-separated (time id owner class kind unit pr url text)
notify_line() { awk -F '\t' -v i="$1" '$2 == i { print; exit }' "$(feed_file)" 2>/dev/null; }
# notify_item <url> <pr> <kind> <unit> <text>: an item as one line of a batch or the digest: its
# text (with NOTIFY_CONTENT=link, its unit and kind only) and its link
notify_item() {
  local url=$1 t=$5
  [ "$url" = - ] && [ "$2" != - ] && url=$(pr_url "$2")
  if [ "${NOTIFY_CONTENT:-full}" != full ]; then t="$([ "$4" = - ] || echo "#$4 ")$3"; fi
  echo "$t$([ "$url" = - ] || echo " $url")"
}

# notify_flush: the queue goes once the oldest item's window is over, or at the end of the quiet
# hours that held it: one item as its own message, several as one batch. Nothing goes in quiet
# hours or over the cap (the digest takes those).
notify_flush() {
  local f id t fl oldest="" held=0 ids=() sent=()
  f=$(notify_dir)/queue
  [ -s "$f" ] || return 0
  notify_quiet && return 0
  if notify_capped; then notify_cap_line; return 0; fi
  while IFS=$'\t' read -r id t fl; do
    [ -n "$id" ] || continue
    ids+=("$id"); [ -n "$oldest" ] || oldest=$t; [ "$fl" = q ] && held=1
  done < "$f"
  (( ${#ids[@]} )) || return 0
  (( held )) || (( $(now) - oldest >= ${NOTIFY_BATCH_MIN:-10} * 60 )) || return 0
  if (( ${#ids[@]} == 1 )); then
    _nq_send_one "${ids[0]}" && sent=("${ids[0]}")
  else notify_batch "${ids[@]}"; sent=("${NQ_SENT[@]}"); fi
  (( ${#sent[@]} )) || return 0
  for id in "${sent[@]}"; do nt_del queue "$id"; done
  notify_count "$( (( ${#ids[@]} == 1 )) && echo item || echo batch)"
}
_nq_send_one() {
  local l t id owner class kind unit pr url text
  l=$(notify_line "$1"); [ -n "$l" ] || { nt_del queue "$1"; return 1; }
  IFS=$'\t' read -r t id owner class kind unit pr url text <<<"$l"
  notify_send "$id" "$kind" "$unit" "$pr" "$(notify_text "$class" "$kind" "$unit" "$pr" "$url" "$text")" "${2:-}"
}

# notify_batch <feed id...>: each item silently into its own topic (for its own replies), then
# one message that rings: a numbered line per item and the reply that settles them all. That
# message is a topic too (its feed ids, units and PRs joined by commas), so the reply reaches the
# inbox. NQ_SENT: the ids that went (log lines share the output); an item whose send failed
# stays queued.
notify_batch() {
  local id l t owner class kind unit pr url text n=0 lines="" acc="" us="" ps="" is="" m r rc
  NQ_SENT=()
  for id; do
    l=$(notify_line "$id"); [ -n "$l" ] || continue
    IFS=$'\t' read -r t _ owner class kind unit pr url text <<<"$l"
    _nq_send_one "$id" silent || continue
    NQ_SENT+=("$id")
    n=$((n + 1)); lines+="$n. $(notify_item "$url" "$pr" "$kind" "$unit" "$text")"$'\n'
    [ "$kind" = accept ] && [ "$pr" != - ] && acc+=" $pr"
    is+=",$id"; [ "$unit" = - ] || us+=",$unit"; [ "$pr" = - ] || ps+=",$pr"
  done
  (( n )) || return 0
  m="For the product owner: $n items wait for you"$'\n'"$lines"
  if [ -n "$acc" ]; then m+="Reply: accept$acc"; else m+="Reply in an item's topic to answer it."; fi
  us=${us#,} ps=${ps#,}
  r=$(tg_send "$(home_tilde_stream <<<"$m")" - -); rc=$?
  case $rc in
    0) nt_add topics "m$r	${is#,}	${us:--}	${ps:--}	open	$r"; nt_add msgs "$r	m$r"
       log "telegram: sent a batch of $n (feed lines ${is#,})" ;;
    2) log "telegram: sending the batch of feed lines ${is#,} timed out; it may have landed" ;;
    # the items went into their topics: they are not sent again
    *) log "telegram: sending the batch of feed lines ${is#,} failed ($r); its items are in their topics" ;;
  esac
  return 0
}
# notify_batch_settle <feed id>: a batch whose every item settled closes (its topic takes no reply)
notify_batch_settle() {
  local key
  for key in $(awk -F '\t' -v i="$1" 'FNR == NR { if ($5 == "closed" && $9 ~ /^closes [0-9]+/) { split(substr($9, 8), x, ":"); c[x[1]] = 1 }; next }
      $5 == "open" && $2 ~ /,/ && index("," $2 ",", "," i ",") {
        n = split($2, a, ","); for (j = 1; j <= n; j++) if (a[j] != i && !(a[j] in c)) next
        print $1 }' "$(feed_file)" "$(notify_dir)/topics" 2>/dev/null); do
    nt_put topics "$key" 5 closed
  done
}

# notify_digest_tick: once a day, the first pass at or after NOTIFY_DIGEST_HOUR (and out of the
# quiet hours), the digest in a topic of its own; it takes the items still queued
notify_digest_tick() {
  local h d
  [ -n "${NOTIFY_DIGEST_HOUR:-}" ] || return 0
  h=$(notify_clock +%-H); d=$(notify_day)
  (( h >= 10#$NOTIFY_DIGEST_HOUR )) || return 0
  [ "$(cat "$(notify_dir)/digest" 2>/dev/null)" = "$d" ] && return 0
  notify_quiet && return 0
  [ -z "$(notify_ready)" ] || return 0
  notify_digest "$d"
}
# notify_digest <day>: the merges of the last 24 h and who accepted them, what runs, the spend,
# what waits for the product owner (the queued items, which the digest delivers) and, with
# NOTIFY_REMIND_H, the items open longer than that
notify_digest() {
  local d=$1 since f m run spend wait="" nw=0 open=0 old="" ids=() id l t owner class kind unit pr url text th=- key r rc e
  since=$(( $(now) - 86400 )) f=$(notify_dir)
  m=$(awk -F '\t' -v s="$since" '$1 >= s { printf "- #%s %s · PR #%s · %s\n", $2, $5, $3, $4 }' "$CANCCU_HOME/merged.log" 2>/dev/null)
  run=$(while read -r k s; do [ -n "$k" ] && echo "- $(run_label "$k")"; done < <(live_runs 2>/dev/null))
  spend=$(awk -F '\t' -v s="$since" -v r="$REPO_NAME" '$1 >= s && $2 == r { n++; if ($4 ~ /^[0-9.]+$/) c += $4 }
    END { printf "$%.2f over %d run%s", c, n, (n == 1 ? "" : "s") }' "$WORKERS_DIR/spend.log" 2>/dev/null)
  mapfile -t ids < <(cut -f1 "$f/queue" 2>/dev/null)
  for id in "${ids[@]}"; do
    l=$(notify_line "$id"); [ -n "$l" ] || continue
    IFS=$'\t' read -r t _ owner class kind unit pr url text <<<"$l"
    wait+="- $(notify_item "$url" "$pr" "$kind" "$unit" "$text")"$'\n'; nw=$((nw + 1))
  done
  while IFS=$'\t' read -r t _ owner class kind unit pr url text; do
    open=$((open + 1))
    e=$(date -d "$t" +%s 2>/dev/null) || continue
    (( ${NOTIFY_REMIND_H:-0} > 0 && $(now) - e >= NOTIFY_REMIND_H * 3600 )) &&
      old+="- $(notify_item "$url" "$pr" "$kind" "$unit" "$text")"$'\n'
  done < <(_nq_open_sent)
  r="Daily digest $d · project $CANCCU_PROJECT"$'\n'"Merged in 24 h: $([ -n "$m" ] && printf '%s\n%s' "$(wc -l <<<"$m")" "$m" || echo none)"
  r+=$'\n'"Running: $([ -n "$run" ] && printf '%s\n%s' "$(wc -l <<<"$run")" "$run" || echo none)"
  r+=$'\n'"Spent in 24 h: ${spend:-\$0.00 over 0 runs} · usage: $(usage_text)"
  if (( nw + open == 0 )); then r+=$'\n'"Waiting for you: none"
  else
    r+=$'\n'"Waiting for you: $((nw + open))"$'\n'"${wait}"
    (( open )) && r+="- and $open sent before, still open (their topics)"
  fi
  [ -z "$old" ] || r+=$'\n'"Open longer than $NOTIFY_REMIND_H h:"$'\n'"${old%$'\n'}"
  r=$(home_tilde_stream <<<"$r")
  if [[ $TELEGRAM_CHAT_ID == -* ]] && th=$(tg_topic "Digest $d"); then key=t$th; else th=-; fi
  m=$(tg_send "$r" "$th" -); rc=$?
  case $rc in
    0) [ -n "${key:-}" ] || key=m$m
       nt_add topics "$key	-	-	-	open	$m"; nt_add msgs "$m	$key" ;;
    2) log "telegram: sending the digest timed out; it may have landed, so it is not sent again" ;;
    *) warn_once notify-digest "telegram: sending the digest failed ($m); tried again next pass"; return 1 ;;
  esac
  # the queued items reached the product owner in the digest: recorded as sent, with no message
  for id in "${ids[@]}"; do nt_add sent "$id	-	-"; nt_del queue "$id"; done
  echo "$d" > "$f/digest"
  log "telegram: sent the digest of $d ($nw queued item(s) in it)"
}
# _nq_open_sent: the feed lines of the asks that went to Telegram and no closed line settled yet
_nq_open_sent() {
  awk -F '\t' 'FNR == NR { if ($2 != "-") s[$1] = 1; next }
    $5 == "closed" && $9 ~ /^closes [0-9]+/ { split(substr($9, 8), x, ":"); delete o[x[1]]; next }
    $4 == "ask" && ($2 in s) { o[$2] = $0 }
    END { for (i in o) print o[i] }' "$(notify_dir)/sent" "$(feed_file)" 2>/dev/null | sort -t $'\t' -k2,2n
}

# ---------------------------------------------------------------- the listener

notify_beat() { echo "$(notify_dir)/listen.beat"; }
# notify_listening: a listener holds its lock now
notify_listening() { local l; l=$(notify_dir)/.listen.lock; [ -e "$l" ] && ! flock -n "$l" true 2>/dev/null; }
# notify_listen_problem: a line when a listener ran here once and none runs now
notify_listen_problem() {
  [ -f "$(notify_beat)" ] && ! notify_listening || return 0
  echo "the Telegram listener is down (its last read $(iso "$(stat -c %Y "$(notify_beat)")")): replies wait for the next pass; canccu-up starts it again"
}
# notify_listen: canccu-notify listen: a long poll (getUpdates timeout 50) that writes the inbox as
# the pass does, under the lock the pass's read takes, so only one reader runs. CANCCU_LISTEN_ROUNDS
# ends it after that many reads (the tests).
notify_listen() {
  local f n=0
  [ -n "${TELEGRAM_USER_ID:-}" ] || { echo "TELEGRAM_USER_ID is not set: no reply is read"; return 1; }
  f=$(notify_dir); mkdir -p "$f"
  exec 7>>"$f/.listen.lock"
  # a pass reads for 10 seconds at most: a lock held longer is another listener's
  flock -w 15 7 || { echo "another listener reads the replies of project $CANCCU_PROJECT"; return 1; }
  log "telegram: the listener runs (pid $$)"
  while :; do
    touch "$(notify_beat)"
    notify_read 50 || sleep 5
    n=$((n + 1))
    (( ${CANCCU_LISTEN_ROUNDS:-0} > 0 && n >= CANCCU_LISTEN_ROUNDS )) && break
  done
  return 0
}
