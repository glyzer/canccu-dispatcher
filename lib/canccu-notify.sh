# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the notifications on Telegram
# (docs/reference/notify.md). feed() calls notify_event for each line it writes, so a message goes
# at the state change itself; the pass's notify_tick retries what failed, sends the SVGs a passed
# PR changes and reads the replies into the inbox. A reply is text for the leader, never a command.
#
# The records, in $CANCCU_HOME/notify/ (tab-separated, under one lock: the pass and canccu-notify
# both write them):
#   topics   <key> <feed id or -> <unit> <pr or -> <open|closed> <root message or ->; key t<thread>
#            for a forum topic, m<root message> for a reply chain
#   msgs     <message id> <key>: the messages of a topic, for telling which chain a reply is in
#   sent     <feed id> <message id, ? when the send timed out> <key or ->
#   text/<feed id>   the text sent, for the edit that marks it closed
#   retry    the feed ids whose send failed; offset: the next update to read; images: <pr> <sha>
# The queue, the cap, the digest and the listener: lib/canccu-notifyq.sh.

notify_dir() { echo "$CANCCU_HOME/notify"; }
_nt_locked() { mkdir -p "$(notify_dir)" && ( flock -w 30 9 || exit 1; "$@" ) 9>>"$(notify_dir)/.lock"; }
_nt_append() { printf '%s\n' "$2" >> "$(notify_dir)/$1"; }
_nt_put() {
  local f; f="$(notify_dir)/$1"
  [ -f "$f" ] || return 0
  awk -F '\t' -v OFS='\t' -v k="$2" -v c="$3" -v v="$4" '$1 == k { $c = v } { print }' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
_nt_del() {
  local f; f="$(notify_dir)/$1"
  [ -f "$f" ] || return 0
  awk -F '\t' -v k="$2" '$1 != k' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
nt_add() { _nt_locked _nt_append "$@"; }
nt_put() { _nt_locked _nt_put "$@"; }
nt_del() { _nt_locked _nt_del "$@"; }
# nt_get <file> <key> <column>: that column of the last line whose first field is key
nt_get() { awk -F '\t' -v k="$2" -v c="$3" '$1 == k { v = $c } END { if (v != "") print v }' "$(notify_dir)/$1" 2>/dev/null; }
notify_retry_add() { grep -qx "$1" "$(notify_dir)/retry" 2>/dev/null || nt_add retry "$1"; }
notify_retry_del() { nt_del retry "$1"; }

# notify_on <github|telegram>: NOTIFY sends to that channel. A word that is no channel keeps
# today's GitHub ping (the doctor names it): a typo never silences every ask.
notify_on() {
  case ${NOTIFY:-github} in
    both) return 0 ;;
    off) return 1 ;;
    telegram) [ "$1" = telegram ] ;;
    *) [ "$1" = github ] ;;
  esac
}

# notify_ready: why nothing can go to Telegram now, else nothing
notify_ready() {
  command -v curl >/dev/null || { echo "curl is not installed"; return 0; }
  [ -n "${TELEGRAM_CHAT_ID:-}" ] || { echo "TELEGRAM_CHAT_ID is not set"; return 0; }
  tg_token_problem
}
# notify_problem: the doctor's and canccu-init --check's lines for the notify settings
notify_problem() {
  case ${NOTIFY:-github} in
    github|off) return 0 ;;
    telegram|both) ;;
    *) echo "NOTIFY=$NOTIFY is none of github, telegram, both, off: asks go to GitHub only"; return 0 ;;
  esac
  local p; p=$(notify_ready)
  case $p in
    "TELEGRAM_CHAT_ID is not set") echo "TELEGRAM_CHAT_ID is not set: nothing goes to Telegram (canccu-notify --project $CANCCU_PROJECT ids lists the chats the bot saw)" ;;
    "") ;;
    *) echo "$p: nothing goes to Telegram" ;;
  esac
  [ -n "${TELEGRAM_USER_ID:-}" ] || echo "TELEGRAM_USER_ID is not set: no reply on Telegram reaches the inbox (canccu-notify --project $CANCCU_PROJECT ids shows your id)"
  [ -z "${QUIET_HOURS:-}" ] || notify_quiet_range >/dev/null ||
    echo "QUIET_HOURS=$QUIET_HOURS is no <hour>-<hour> (for example 22-07): quiet hours are off"
  notify_digest_problem
  notify_listen_problem
  return 0
}

# notify_kind <kind>: the word of NOTIFY_KINDS a feed kind goes by: a failed run and a PR that
# needs you are needs-you items (contracts §2), every hold is a hold
notify_kind() { case $1 in run-ended|pr-needs-you) echo needs-you ;; hold-*) echo hold ;; *) echo "$1" ;; esac; }
# notify_wanted <owner> <class> <kind>: the lines that go to Telegram: every interrupt, and the
# product owner's asks and the info lines of a kind NOTIFY_KINDS names. The leader's lines stay
# in the feed: the leader reads them there.
notify_wanted() {
  case $2 in
    interrupt) return 0 ;;
    ask) [ "$1" = po ] || return 1 ;;
    info) ;;
    *) return 1 ;;
  esac
  local k=${NOTIFY_KINDS-accept plan question needs-you checkpoint step-done}
  [[ " ${k//,/ } " == *" $(notify_kind "$3") "* ]]
}

# notify_text <class> <kind> <unit> <pr> <url> <text>: the message. A unit's ask is the ask form
# (contracts §4, NOTIFY_CONTENT applied); any other line its own text and the link.
notify_text() {
  local class=$1 kind=$2 unit=$3 pr=$4 url=$5 text=$6 k=$2 first
  [ "$k" = run-ended ] && k=needs-you
  if [ "$unit" != - ] && [[ " accept plan question needs-you pr-needs-you " == *" $k "* ]]; then
    home_tilde "$(ask_form "$unit" "$k" "$pr")"; return 0
  fi
  if [ "$class" = info ]; then first="For your information:"; else first="For the product owner:"; fi
  {
    # link: what leaves the host is fixed words and the link, never the line's text
    if [ "${NOTIFY_CONTENT:-full}" != full ]; then
      echo "$first $kind$([ "$unit" = - ] || echo " #$unit")"
    else
      echo "$first $text"
      [ "$class" = info ] || printf '%s\n' "Recommended: answer needed" "No answer: this waits."
    fi
    [ "$url" = - ] || echo "$url"
  } | home_tilde_stream
}

# notify_event <feed id>: the line's message, once; a closed line marks its item's message closed.
# An idle line is dropped while its unit has an open item: the item's own message says it waits.
# Every item but an interrupt goes through the queue whenever it may not go at once (the batch
# window, quiet hours, the cap). 1 when a send failed (it waits in retry).
notify_event() {
  (( ${CANCCU_DRY:-0} )) && return 0
  notify_on telegram || return 0
  local l t id owner class kind unit pr url text
  l=$(awk -F '\t' -v i="$1" '$2 == i { print; exit }' "$(feed_file)" 2>/dev/null)
  # a line gone (the events file was reset) is never sent
  [ -n "$l" ] || { notify_retry_del "$1"; return 0; }
  IFS=$'\t' read -r t id owner class kind unit pr url text <<<"$l"
  notify_reset_check
  if [ "$kind" = closed ]; then
    [[ $text =~ ^closes\ ([0-9]+) ]] && notify_settle "${BASH_REMATCH[1]}"
    return 0
  fi
  notify_wanted "$owner" "$class" "$kind" || return 0
  [ -z "$(nt_get sent "$id" 1)" ] || return 0
  [ "$kind" = idle ] && [ "$unit" != - ] && notify_unit_open "$unit" && return 0
  # a queued item is the flush's (a failed flush left it in retry too): never sent twice
  [ -n "$(nt_get queue "$id" 1)" ] && return 0
  if [ "$class" != interrupt ] && notify_holds; then notify_queue_add "$id"; return 0; fi
  notify_send "$id" "$kind" "$unit" "$pr" "$(notify_text "$class" "$kind" "$unit" "$pr" "$url" "$text")" || return 1
  [ "$class" = interrupt ] || notify_count
}

# notify_reset_check: the events file was reset when its first line is no longer the one seen
# before (notify/epoch), or its last id is below the highest id in notify/sent (as feed_ack
# tells): ids start again at 1. The records keyed by a feed id are then old items': cleared, or a
# new item with a used id is never sent and its closed line edits an old message.
notify_reset_check() {
  local first last max seen
  first=$(head -n 1 "$(feed_file)" 2>/dev/null); [ -n "$first" ] || return 0
  seen=$(cat "$(notify_dir)/epoch" 2>/dev/null)
  last=$(tail -n 1 "$(feed_file)" 2>/dev/null | cut -f2); [[ $last =~ ^[0-9]+$ ]] || last=0
  max=$(awk -F '\t' '$1 + 0 > m { m = $1 + 0 } END { print m + 0 }' "$(notify_dir)/sent" 2>/dev/null)
  if [ "$seen" = "$first" ] && (( last >= max )); then return 0; fi
  mkdir -p "$(notify_dir)"
  # a first look at the file (no epoch yet) is no reset: only a file that differs from the seen one is
  if [ -n "$seen" ] || (( last < max )); then
    _nt_locked _nt_reset
    log "telegram: the events file was reset: the records of its old feed ids are cleared"
  fi
  printf '%s\n' "$first" > "$(notify_dir)/epoch"
}
_nt_reset() {
  local f; f=$(notify_dir)
  : > "$f/sent"; : > "$f/retry"; rm -rf "$f/text"
  [ ! -f "$f/topics" ] || { awk -F '\t' -v OFS='\t' '{ $2 = "-" } { print }' "$f/topics" > "$f/topics.tmp" && mv -f "$f/topics.tmp" "$f/topics"; }
}

# notify_send <feed id> <kind> <unit> <pr> <text> [silent]: opens the item's topic (a forum topic
# in a group; else the message is the root of a reply chain) and sends the message into it. A
# topic made by a try whose message failed is used again. A message that timed out is recorded as
# sent: twice is worse than once missed, as for the GitHub ping.
notify_send() {
  local id=$1 kind=$2 unit=$3 pr=$4 text=$5 silent=${6:-} p key th=- r rc u=""
  [ "$unit" = - ] || u=" #$unit"
  p=$(notify_ready)
  if [ -n "$p" ]; then notify_retry_add "$id"; warn_once notify "telegram: $p; the messages are sent once it works"; return 1; fi
  key=$(awk -F '\t' -v i="$id" '$2 == i { k = $1 } END { print k }' "$(notify_dir)/topics" 2>/dev/null)
  [[ $key == t* ]] && th=${key#t}
  if [ -z "$key" ] && [[ $TELEGRAM_CHAT_ID == -* ]]; then
    if [ "$unit" = - ] && [ "${NOTIFY_CONTENT:-full}" = full ]; then r="$kind: $text"; else r="#${unit#-} $kind"; [ "$unit" = - ] && r=$kind; fi
    r=$(tg_topic "$r"); rc=$?
    case $rc in
      0) th=$r key=t$r; nt_add topics "$key	$id	$unit	$pr	open	-" ;;
      # the topic may be there, but its id is lost: the message goes to the chat's main thread
      2) log "telegram: opening a topic for feed line $id timed out; the message goes without one" ;;
      *) warn_once notify-forum "telegram: no forum topic in chat $TELEGRAM_CHAT_ID ($r): each message opens a reply chain instead" ;;
    esac
  fi
  r=$(tg_send "$text" "$th" - "$silent"); rc=$?
  case $rc in
    0)
      if [ -z "$key" ]; then key=m$r; nt_add topics "$key	$id	$unit	$pr	open	$r"; else nt_put topics "$key" 6 "$r"; fi
      nt_add msgs "$r	$key"; nt_add sent "$id	$r	$key"
      mkdir -p "$(notify_dir)/text" && printf '%s\n' "$text" > "$(notify_dir)/text/$id"
      notify_retry_del "$id"; rm -f "$CANCCU_HOME/.warned-notify"
      log "telegram: sent feed line $id ($kind$u)" ;;
    2)
      nt_add sent "$id	?	${key:--}"; notify_retry_del "$id"
      log "telegram: sending feed line $id timed out; it may have landed, so it is not sent again" ;;
    *) notify_retry_add "$id"; warn_once notify "telegram: sending failed ($r); tried again next pass"; return 1 ;;
  esac
}

# notify_settle <feed id>: the item no longer waits: its message is edited to start with Closed:,
# and with no leader its topic closes (with one, the leader closes it once the thread is settled).
# An item that settled before its send worked, or while it waited in the queue, is never sent.
notify_settle() {
  local id=$1 m key
  notify_retry_del "$id"; nt_del queue "$id"
  [ "${LEADER:-off}" = on ] || notify_batch_settle "$id"
  m=$(nt_get sent "$id" 2); key=$(nt_get sent "$id" 3)
  [ -n "$m" ] || return 0
  # m -: the item reached the product owner only in a digest
  if [ "$m" != "?" ] && [ "$m" != - ] && [ -f "$(notify_dir)/text/$id" ]; then
    tg_edit "$m" "Closed: $(cat "$(notify_dir)/text/$id")" || log "telegram: marking the message of feed line $id closed failed"
  fi
  [ "${LEADER:-off}" = on ] || [ "$key" = - ] || notify_close "$key" || true
}

# notify_post <key> <text> [note]: a message in an open topic; in a reply chain, and for a note,
# a reply to the topic's root message. Prints its id, or why not.
notify_post() {
  local key=$1 th=- re=- root m rc
  [ "$(nt_get topics "$key" 5)" = open ] || { echo "no open topic $key"; return 1; }
  root=$(nt_get topics "$key" 6)
  if [[ $key == t* ]]; then th=${key#t}; [ -z "${3:-}" ] || re=${root:--}; else re=${root:--}; fi
  m=$(tg_send "$2" "$th" "$re"); rc=$?
  (( rc == 0 )) && nt_add msgs "$m	$key"
  echo "$m"; return "$rc"
}
# notify_close <key> [say]: closes an open topic (the forum topic too); with say, posts Closed. first
notify_close() {
  [ "$(nt_get topics "$1" 5)" = open ] || return 1
  [ -z "${2:-}" ] || notify_post "$1" "Closed." >/dev/null || true
  [[ $1 == t* ]] && { tg_topic_close "${1#t}" || log "telegram: closing the forum topic ${1#t} failed"; }
  nt_put topics "$1" 5 closed
}

# notify_photos <unit> <caption> <png...>: the images into the unit's newest open topic, else a
# new one; prints the first message id
notify_photos() {
  local k=$1 cap=$2 key th=- re=- m rc
  shift 2
  key=$(awk -F '\t' -v u="$k" '$3 == u && $5 == "open" { x = $1 } END { print x }' "$(notify_dir)/topics" 2>/dev/null)
  if [ -n "$key" ]; then
    if [[ $key == t* ]]; then th=${key#t}; else re=$(nt_get topics "$key" 6); re=${re:--}; fi
  elif [[ $TELEGRAM_CHAT_ID == -* ]] && m=$(tg_topic "#$k images"); then
    th=$m key=t$m; nt_add topics "$key	-	$k	-	open	-"
  fi
  m=$(tg_photos "$th" "$re" "$cap" "$@"); rc=$?
  # a timed-out upload may have landed: it counts as sent, as for a message
  if (( rc == 2 )); then log "telegram: sending the images for #$k timed out; they may have landed, so they are not sent again"; echo "?"; return 0; fi
  (( rc == 0 )) || { echo "$m"; return "$rc"; }
  [ -n "$key" ] || { key=m$m; nt_add topics "$key	-	$k	-	open	$m"; }
  nt_add msgs "$m	$key"
  log "telegram: sent $# image(s) for #$k"
  echo "$m"
}

# notify_svgs <unit> <pr> <sha>: the SVG files the PR changes, read from GitHub at that head and
# rendered here. Never a link from the PR body: that is worker text, and fetching it would send
# the host to any URL. 1 on a gh error (tried again next pass).
notify_svgs() {
  local files p d i=0 out=() svgs=()
  files=$(pr_files_raw "$2") || return 1
  mapfile -t svgs < <(cut -f1 <<<"$files" | grep -iE '^[A-Za-z0-9._/-]+\.svg$' | head -n 10)
  (( ${#svgs[@]} )) || return 0
  command -v rsvg-convert >/dev/null || { warn_once notify-svg "telegram: rsvg-convert is not installed: the SVGs a PR changes are not sent"; return 0; }
  d=$(mktemp -d) || return 1
  for p in "${svgs[@]}"; do
    i=$((i + 1))
    # a file the PR deletes is not there at the head: nothing to show
    ghj api "repos/$REPO/contents/$p?ref=$3" -H 'Accept: application/vnd.github.raw' > "$d/$i.svg" 2>/dev/null || continue
    timeout 30 rsvg-convert -o "$d/$i.png" "$d/$i.svg" >/dev/null 2>&1 && [ -s "$d/$i.png" ] && out+=("$d/$i.png")
  done
  local rc=0
  (( ${#out[@]} )) && { notify_photos "$1" "PR #$2 changes ${#out[@]} SVG file(s), rendered at ${3:0:7}"$'\n'"$(pr_url "$2")" "${out[@]}" >/dev/null || rc=1; }
  rm -rf "$d"; return "$rc"
}
# notify_images: once per passed head, the SVGs its PR changes
notify_images() {
  local k pr sha
  for k in $(managed); do
    pr=$(st_get "$k" pr); sha=$(st_get "$k" pass_sha)
    [ -n "$pr" ] && [ -n "$sha" ] || continue
    [ "$(nt_get images "$pr" 2)" = "$sha" ] && continue
    notify_svgs "$k" "$pr" "$sha" || continue
    if [ -n "$(nt_get images "$pr" 1)" ]; then nt_put images "$pr" 2 "$sha"; else nt_add images "$pr	$sha"; fi
  done
}

# notify_poll: the pass's read of the bot's updates, once per pass, under the listener's lock: a
# live listener (canccu-notify listen) holds it and reads them as they come, so the pass skips.
notify_poll() {
  [ -n "${TELEGRAM_USER_ID:-}" ] && [ -z "$(notify_ready)" ] || return 0
  mkdir -p "$(notify_dir)"
  ( flock -n 7 || exit 0; notify_read 0 ) 7>>"$(notify_dir)/.listen.lock"
  return 0
}
# notify_read <seconds>: one read of the updates (seconds > 0: a long poll). Only a message in
# the chat, from TELEGRAM_USER_ID, in an open topic (its thread, or a reply to a message of its
# chain) is kept, as one inbox line: <time> <topic> <unit> <pr> <text>. Every other is dropped.
# 1 when the read failed. The caller holds the listener's lock: two readers would share the offset.
notify_read() {
  local f off r u c fr th re mid tx key max=-1 kept=0 dropped=0
  f=$(notify_dir); mkdir -p "$f"
  off=$(cat "$f/offset" 2>/dev/null); [[ $off =~ ^[0-9]+$ ]] || off=0
  r=$(TG_MAX_TIME=$(( ${1:-0} + ${TG_MAX_TIME:-10} )) tg_updates "$off" "$1") ||
    { warn_once notify-poll "telegram: reading replies failed ($r); tried again next pass"; return 1; }
  rm -f "$CANCCU_HOME/.warned-notify-poll"
  while IFS=$'\t' read -r u c fr th re mid tx; do
    [[ $u =~ ^[0-9]+$ ]] || continue
    (( u > max )) && max=$u
    key=""
    if [ "$c" = "$TELEGRAM_CHAT_ID" ] && [ "$fr" = "$TELEGRAM_USER_ID" ]; then
      if [ "$th" != - ]; then key=t$th
      elif [ "$re" != - ]; then key=$(nt_get msgs "$re" 2); fi
    fi
    if [ -n "$key" ] && [ "$(nt_get topics "$key" 5)" = open ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$(iso "$(now)")" "$key" "$(nt_get topics "$key" 3)" "$(nt_get topics "$key" 4)" "${tx:0:2000}" >> "$CANCCU_HOME/inbox"
      [ "$mid" = - ] || nt_add msgs "$mid	$key"
      kept=$((kept + 1))
    else dropped=$((dropped + 1)); fi
  done < <(jq -r '.[] | [.update_id, (.message.chat.id // "-"), (.message.from.id // "-"),
      (if .message.is_topic_message == true then .message.message_thread_id else "-" end),
      (.message.reply_to_message.message_id // "-"), (.message.message_id // "-"),
      ((.message.text // .message.caption // "(a message with no text)") | gsub("[\t\n\r]+"; " "))]
    | map(tostring) | join("\t")' <<<"$r" 2>/dev/null)
  (( max < 0 )) || echo $((max + 1)) > "$f/offset"
  (( kept + dropped == 0 )) || log "telegram: $kept replies kept, $dropped other messages dropped"
}

# notify_tick: the pass's part: the retries (stopping at the first that fails again), the queue,
# the digest, the images, the replies
notify_tick() {
  (( ${CANCCU_DRY:-0} )) && return 0
  notify_on telegram || return 0
  local id
  for id in $(cat "$(notify_dir)/retry" 2>/dev/null); do notify_event "$id" || break; done
  notify_flush
  notify_digest_tick
  notify_images
  notify_poll
}

# its queue: batching, quiet hours, the cap, the digest and the listener
# shellcheck source=canccu-notifyq.sh
. "$_canccu_lib/canccu-notifyq.sh"
