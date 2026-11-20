# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the Telegram Bot API calls of the
# notifications (lib/canccu-notify.sh, docs/reference/notify.md). Only these functions read the
# bot token, and only into curl's stdin: it is in no argument, log, record or process title.

TG_API=https://api.telegram.org

# tg_token_problem [file]: why the bot token file (TELEGRAM_TOKEN_FILE) cannot be used, else
# nothing. Inside a repo it could be committed or read by a run working there: refused.
tg_token_problem() {
  local f=${1:-${TELEGRAM_TOKEN_FILE:-}} t m d
  [ -n "$f" ] || { echo "TELEGRAM_TOKEN_FILE is not set"; return 0; }
  t=$(canccu_tilde "$f")
  [ -s "$f" ] || { echo "no Telegram bot token file ($t)"; return 0; }
  m=$(stat -c %a "$f"); [ "$m" = 600 ] || { echo "the Telegram bot token file $t has mode $m, not 600 (chmod 600 $t)"; return 0; }
  d=$(dirname "$(realpath -m "$f")")
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -e "$d/.git" ] && { echo "the Telegram bot token file $t is inside the repo $(canccu_tilde "$d"): move it out"; return 0; }
    d=${d%/*}
  done
  # the token goes into curl's config text between quotes: anything but a bot token's shape is refused
  [[ $(head -n 1 "$f") =~ ^[[:space:]]*[0-9]+:[A-Za-z0-9_-]+[[:space:]]*$ ]] ||
    echo "the Telegram bot token file $t holds no bot token (one line, <digits>:<letters>, from BotFather)"
  return 0
}

# tg_call <method> [curl form arguments...]: one Bot API call. Prints the answer's result (JSON)
# and returns 0; on a refusal prints why (one line) and returns 1; on a timeout returns 2: the
# call may have landed. curl's own messages never carry the url, and the token is cut from them anyway.
tg_call() {
  local m=$1 tok out rc; shift
  tok=$(head -n 1 "$TELEGRAM_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
  [ -n "$tok" ] || { echo "no Telegram bot token"; return 1; }
  out=$(printf 'url = "%s/bot%s/%s"\n' "$TG_API" "$tok" "$m" |
    curl -sS --max-time "${TG_MAX_TIME:-10}" --config - "$@" 2>&1); rc=$?
  out=${out//"$tok"/<token>}
  (( rc == 28 )) && { echo "timed out"; return 2; }
  (( rc == 0 )) || { oneline 200 "curl: $out"; echo; return 1; }
  if jq -e '.ok == true' >/dev/null 2>&1 <<<"$out"; then jq -c '.result' <<<"$out"; return 0; fi
  oneline 200 "$(jq -r '.description // empty' 2>/dev/null <<<"$out" || true)"; echo
  return 1
}

# tg_send <text> <thread or -> <reply-to message or ->: one plain-text message (no parse mode: no
# reason or reply text can turn into markup or a link preview); prints its message id
tg_send() {
  local r rc a=(--form-string "chat_id=$TELEGRAM_CHAT_ID")
  [ "$2" = - ] || a+=(--form-string "message_thread_id=$2")
  [ "$3" = - ] || a+=(--form-string "reply_parameters={\"message_id\":$3}")
  a+=(--form-string "text=${1:0:4000}" --form-string 'link_preview_options={"is_disabled":true}')
  r=$(tg_call sendMessage "${a[@]}"); rc=$?
  if (( rc == 0 )); then jq -r '.message_id' <<<"$r"; else echo "$r"; fi
  return "$rc"
}
# tg_edit <message> <text>
tg_edit() {
  tg_call editMessageText --form-string "chat_id=$TELEGRAM_CHAT_ID" --form-string "message_id=$1" \
    --form-string "text=${2:0:4000}" >/dev/null
}
# tg_topic <name>: a new forum topic; prints its thread id, or why not
tg_topic() {
  local r rc
  r=$(tg_call createForumTopic --form-string "chat_id=$TELEGRAM_CHAT_ID" --form-string "name=${1:0:128}"); rc=$?
  if (( rc == 0 )); then jq -r '.message_thread_id' <<<"$r"; else echo "$r"; fi
  return "$rc"
}
tg_topic_close() { tg_call closeForumTopic --form-string "chat_id=$TELEGRAM_CHAT_ID" --form-string "message_thread_id=$1" >/dev/null; }

# tg_photos <thread or -> <reply-to or -> <caption> <png...>: one photo, or albums of ten at most
# (the API's limit), the caption on the first; prints the first message id. The files are copied
# to plain names first: curl's -F reads `;type=` and commas in a file name as options.
tg_photos() {
  local th=$1 re=$2 cap=$3 d i=0 r rc first="" media a
  shift 3
  d=$(mktemp -d) || return 1
  while (( $# )); do
    a=(--form-string "chat_id=$TELEGRAM_CHAT_ID")
    [ "$th" = - ] || a+=(--form-string "message_thread_id=$th")
    [ "$re" = - ] || a+=(--form-string "reply_parameters={\"message_id\":$re}")
    if (( $# == 1 )); then
      cp "$1" "$d/p.png" || { rm -rf "$d"; return 1; }
      [ -z "$cap" ] || a+=(--form-string "caption=${cap:0:1000}")
      r=$(TG_MAX_TIME=${TG_UPLOAD_MAX_TIME:-60} tg_call sendPhoto "${a[@]}" -F "photo=@$d/p.png"); rc=$?
      shift
    else
      media="[]" i=0
      while (( $# && i < 10 )); do
        cp "$1" "$d/p$i.png" || { rm -rf "$d"; return 1; }
        media=$(jq -c --arg n "p$i" --arg c "$( (( i == 0 )) && echo "${cap:0:1000}")" \
          '. + [{type: "photo", media: ("attach://" + $n)} + (if $c == "" then {} else {caption: $c} end)]' <<<"$media")
        a+=(-F "p$i=@$d/p$i.png"); i=$((i + 1)); shift
      done
      r=$(TG_MAX_TIME=${TG_UPLOAD_MAX_TIME:-60} tg_call sendMediaGroup "${a[@]}" --form-string "media=$media"); rc=$?
    fi
    (( rc == 0 )) || { rm -rf "$d"; echo "$r"; return "$rc"; }
    [ -n "$first" ] || first=$(jq -r 'if type == "array" then .[0].message_id else .message_id end' <<<"$r")
    cap=""
  done
  rm -rf "$d"; echo "$first"
}

# tg_updates <offset>: the updates from offset on, without waiting (one call per pass), messages only
tg_updates() {
  tg_call getUpdates --form-string "offset=$1" --form-string timeout=0 --form-string 'allowed_updates=["message"]'
}
