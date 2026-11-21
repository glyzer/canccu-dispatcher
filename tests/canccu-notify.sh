#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-notify.sh — Telegram notifications, their topics and the replies' inbox (#39).
# Harness: tests/lib/harness.sh (its fake curl is the fake Telegram Bot API).
#   bash tests/canccu-notify.sh    one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
track_left

TG_TOKEN=123456:fake-telegram-token-for-tests
EV() { echo "$CANCCU_HOME/events"; }
ND() { echo "$CANCCU_HOME/notify"; }
# tg <name> [config...]: a project that notifies on Telegram, in a forum supergroup; each item at
# once and every kind (the batching and the kinds' defaults: tests/canccu-notify2.sh)
tg() {
  local n=$1; shift
  env_new "$n" NOTIFY=telegram TELEGRAM_CHAT_ID=-1009876 TELEGRAM_USER_ID=777 "TELEGRAM_TOKEN_FILE=$T/$n/telegram-token" \
    NOTIFY_BATCH_MIN=0 "NOTIFY_KINDS='accept plan question needs-you checkpoint step-done idle hold polish'" "$@"
  printf '%s\n' "$TG_TOKEN" > "$E/telegram-token"; chmod 600 "$E/telegram-token"
  : > "$FAKE/tg.log"
}
calls() { grep -c "^$1 " "$FAKE/tg.log"; }
call() { grep "^$1 " "$FAKE/tg.log" | sed -n "${2:-1}p"; }
inbox() { cat "$CANCCU_HOME/inbox" 2>/dev/null; }
notifycmd() { PATH="$fb:$PATH" "$root/bin/canccu-notify" "$@"; }
# accept5: unit 5 enters accept on PR 50 (one feed line, owner po: LEADER=off)
accept5() {
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 "$HA" green | prs
  state 5 phase=check pr=50 "check_at=$NOW"
  lib st_set 5 phase=accept pr=50 accept_sha="$HA" "accept_at=$NOW" "reason=manual: changes .github/ (.github/workflows/ci.yml)"
}
# upd <id> <chat> <from> <thread or -> <reply to or -> <message id> <text>: one update
upd() {
  jq -n --argjson u "$1" --argjson c "$2" --argjson f "$3" --arg th "$4" --arg r "$5" --argjson m "$6" --arg t "$7" '
    {update_id: $u, message: ({message_id: $m, chat: {id: $c}, from: {id: $f}, text: $t}
      + (if $th == "-" then {} else {is_topic_message: true, message_thread_id: ($th | tonumber)} end)
      + (if $r == "-" then {} else {reply_to_message: {message_id: ($r | tonumber)}} end))}'
}

# ---------------------------------------------------------------- settings and the setup check

env_new notify-default
ok "NOTIFY defaults to github" grep -qE '^NOTIFY=github( |$)' "$root/lib/canccu-config.default"
for k in NOTIFY TELEGRAM_CHAT_ID TELEGRAM_USER_ID TELEGRAM_TOKEN_FILE; do
  ok "$k: a line in the defaults and a locked row in the settings table" \
    eq "$(grep -c "^$k=" "$root/lib/canccu-config.default") $(awk -F '\t' -v k="$k" '$1 == k { print $4 }' "$root/lib/canccu-settings.tsv")" "1 locked"
done
ok "… TELEGRAM_TOKEN_FILE is not settable through config set" eq "$(awk -F '\t' '$1 == "TELEGRAM_TOKEN_FILE" { print $3 }' "$root/lib/canccu-settings.tsv")" fixed

tg notify-token-problems
ok "a good token file: no problem" eq "$(lib tg_token_problem)" ""
chmod 644 "$E/telegram-token"
ok "a token file not mode 600: refused" grep -q "has mode 644, not 600" <<<"$(lib tg_token_problem)"
chmod 600 "$E/telegram-token"; rm "$E/telegram-token"
ok "no token file: said so" grep -q "no Telegram bot token file" <<<"$(lib tg_token_problem)"
mkdir -p "$E/code/web/.git" "$E/code/web/conf"; printf '%s\n' "$TG_TOKEN" > "$E/code/web/conf/t"; chmod 600 "$E/code/web/conf/t"
ok "a token file inside a repo: refused" grep -q "inside the repo" <<<"$(lib tg_token_problem "$E/code/web/conf/t")"
printf 'not a token\n' > "$E/telegram-token"; chmod 600 "$E/telegram-token"
ok "a file that holds no bot token: refused" grep -q "no bot token" <<<"$(lib tg_token_problem)"

tg notify-doctor
ok "doctor: a working setup says nothing about Telegram" not grep -qi telegram <<<"$(lib notify_problem)"
rm "$E/telegram-token"
ok "doctor: a missing token is a line" grep -q "Telegram bot token" <<<"$(lib notify_problem)"
tg notify-doctor-chat TELEGRAM_CHAT_ID=
ok "doctor: no chat id is a line" grep -q "TELEGRAM_CHAT_ID is not set" <<<"$(lib notify_problem)"
tg notify-doctor-word NOTIFY=email
ok "doctor: a NOTIFY that is no channel is a line" grep -q "NOTIFY=email" <<<"$(lib notify_problem)"
env_new notify-doctor-github
ok "doctor: NOTIFY=github needs no Telegram setup" eq "$(lib notify_problem)" ""

tg notify-init-check
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --check web 2>&1); rc=$?
ok "init --check: a working setup passes" eq "$rc" 0
ok "… after a getMe and one test message in the chat" eq "$(calls getMe) $(calls sendMessage)" "1 1"
ok "… and says so" grep -q "Telegram: the bot @web_bot reaches chat -1009876" <<<"$out"
rm "$E/telegram-token"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --check web 2>&1); rc=$?
ok "init --check: no token fails" eq "$rc" 1
ok "… and tells how to create a bot" grep -q "BotFather" <<<"$out"
ok "… and how to find the chat id" grep -q "canccu-notify --project web ids" <<<"$out"
tg notify-init-check-github NOTIFY=github
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --check web 2>&1); rc=$?
ok "init --check with NOTIFY=github: nothing to check for Telegram" eq "$rc $(calls getMe)" "0 0"

# ---------------------------------------------------------------- one message per item

tg notify-accept
accept5
ok "an accept: one forum topic and one message in it" eq "$(calls createForumTopic) $(calls sendMessage)" "1 1"
ok "… the topic is named after the unit and the kind" grep -qF "name=#5 accept" <<<"$(call createForumTopic)"
ok "… in the configured chat" grep -qF "chat_id=-1009876" <<<"$(call sendMessage)"
ok "… in the topic" grep -qF "message_thread_id=101" <<<"$(call sendMessage)"
ok "… the ask form: what, why, a recommendation and the link" \
  grep -qF 'text=For the product owner: PR #50 waits for your accept' <<<"$(call sendMessage)"
ok "… with its why and recommended lines" eq "$(call sendMessage | grep -c 'Why you: .*Recommended: .*https://github.com/example-org/web/pull/50')" 1
ok "… sent as plain text (no parse mode)" not grep -q parse_mode <<<"$(call sendMessage)"
ok "… the token reached the call" grep -qx sendMessage "$FAKE/tg-token-ok"
ok "… but no log and no record" not grep -rqF "$TG_TOKEN" "$FAKE/tg.log" "$CANCCU_HOME"
ok "… recorded as sent" eq "$(cut -f1,2,3 "$(ND)/sent")" "1	102	t101"
ok "… its topic open" eq "$(cut -f1-5 "$(ND)/topics")" "t101	1	5	50	open"
ok "… and logged" grep -q 'telegram: sent feed line 1 (accept #5)' "$CANCCU_HOME/dispatch.log"
dispatch --once
ok "the next pass, still waiting: nothing sent" eq "$(calls sendMessage)" 1
lib notify_event 1
ok "the same item again: never sent twice" eq "$(calls sendMessage)" 1
lib st_set 5 phase=merging
ok "the item settles: its message is edited to say closed" eq "$(calls editMessageText)" 1
ok "… that message" grep -qF "message_id=102" <<<"$(call editMessageText)"
ok "… starting Closed:" grep -qF "text=Closed: For the product owner: PR #50" <<<"$(call editMessageText)"
ok "… no new message" eq "$(calls sendMessage)" 1
ok "… with LEADER=off the dispatcher closes the topic" eq "$(calls closeForumTopic) $(cut -f5 "$(ND)/topics")" "1 closed"

tg notify-leader-closes LEADER=on
accept5
lib st_set 5 phase=merging
ok "LEADER=on: a settled item's topic stays for the leader to close" eq "$(calls editMessageText) $(calls closeForumTopic) $(cut -f5 "$(ND)/topics")" "1 0 open"

tg notify-owner LEADER=on LEADER_ACCEPTS=technical
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 "$HA" green | prs
state 5 phase=check pr=50 "check_at=$NOW"
lib st_set 5 phase=accept pr=50 accept_sha="$HA" "accept_at=$NOW" "reason=manual: plan tier"
ok "an item of owner leader: not sent (the leader reads the feed)" eq "$(cut -f3 "$(EV)") $(calls sendMessage)" "leader 0"

tg notify-kinds
lib feed - info step-done - - - "step 3 Events is done: all closed" >/dev/null
lib feed - info hold - - - "usage back-off: nothing new starts until 2030-11-05T13:00:00Z" >/dev/null
lib feed - info polish - - https://github.com/example-org/web/issues/77 "step 3 Events: the deep review found 2 blocking finding(s); polish issue #77 filed" >/dev/null
lib feed leader ask idle 6 - - "#6 sits in check for 70 min with nothing running" >/dev/null
lib feed - info merged 7 70 - "#7 merged" >/dev/null
ok "step-done, a hold and polish (class info) are sent; the leader's line and other info are not" eq "$(calls sendMessage)" 3
ok "… an info line says it is for your information" grep -qF "text=For your information: step 3 Events is done: all closed" <<<"$(call sendMessage 1)"
ok "… with its link" grep -qF 'issues/77' <<<"$(call sendMessage 3)"
lib feed po ask idle 8 - https://github.com/example-org/web/issues/8 "#8 sits in check for 70 min with nothing running" >/dev/null
ok "an ask with no form: its text, answer needed and the link" \
  grep -qF 'text=For the product owner: #8 sits in check for 70 min with nothing running\nRecommended: answer needed\nNo answer: this waits.\nhttps://github.com/example-org/web/issues/8' <<<"$(call sendMessage 4)"

tg notify-link NOTIFY_CONTENT=link
accept5
ok "NOTIFY_CONTENT=link: only the first line and the link" eq "$(call sendMessage | grep -c 'Why you')$(call sendMessage | grep -c 'pull/50')" 01

tg notify-dry
CANCCU_DRY=1 lib notify_event 1
lib feed po ask idle 8 - - x >/dev/null
CANCCU_DRY=1 lib notify_tick
ok "CANCCU_DRY: nothing is sent" eq "$(calls sendMessage)" 1

# ---------------------------------------------------------------- NOTIFY picks the channels

for v in github both telegram off; do
  tg "notify-channel-$v" "NOTIFY=$v" PING_KINDS=all
  { issue 8 needs-you; } | issues
  lib feed po ask needs-you 8 - https://github.com/example-org/web/issues/8 "#8 needs-you: x" >/dev/null
  dispatch --once
  pinged=$(grep -c '^issue comment 8 -R example-org/web --body @octo' "$FAKE/gh.log")
  case $v in
    github) ok "NOTIFY=github: the GitHub ping, no Telegram" eq "$pinged $(calls sendMessage)" "1 0" ;;
    both) ok "NOTIFY=both: the ping and Telegram" eq "$pinged $(calls sendMessage)" "1 1" ;;
    telegram) ok "NOTIFY=telegram: Telegram only" eq "$pinged $(calls sendMessage)" "0 1" ;;
    off) ok "NOTIFY=off: neither" eq "$pinged $(calls sendMessage)" "0 0" ;;
  esac
done

# ---------------------------------------------------------------- failures

tg notify-refused
touch "$FAKE/tg-refuse-sendMessage"
accept5
ok "a refused send: not recorded, kept for a retry" eq "$(test -s "$(ND)/sent"; echo $?) $(cat "$(ND)/retry")" "1 1"
ok "… logged once" eq "$(grep -c 'telegram: sending failed (Bad Request: refused); tried again next pass' "$CANCCU_HOME/dispatch.log")" 1
dispatch --once
ok "… still refused next pass: logged no second time" eq "$(grep -c 'telegram: sending failed' "$CANCCU_HOME/dispatch.log")" 1
rm "$FAKE/tg-refuse-sendMessage"
dispatch --once
ok "… a pass after it works: sent, in the topic made the first time" eq "$(calls createForumTopic) $(cut -f1 "$(ND)/sent") $(cat "$(ND)/retry")" "1 1 "
dispatch --once
ok "… and not again" eq "$(grep -c '^sendMessage .*waits for your accept' "$FAKE/tg.log")" 3

tg notify-timeout
touch "$FAKE/tg-slow"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
ok "a send that timed out may have landed: recorded, never sent again" eq "$(cut -f1,2 "$(ND)/sent")" "1	?"
rm "$FAKE/tg-slow"; dispatch --once
ok "… the next pass sends nothing" eq "$(calls sendMessage)" 1

tg notify-photo-timeout
accept5
printf 'PNG' > "$E/a.png"
touch "$FAKE/tg-slow-sendPhoto"
out=$(notifycmd --project web photos 5 "$E/a.png" 2>&1)
lib notify_photos 5 cap "$E/a.png" >/dev/null; rc=$?
ok "a photo send that timed out may have landed: counted as sent" eq "$rc" 0
ok "… logged" grep -q 'sending the images for #5 timed out' "$CANCCU_HOME/dispatch.log"
ok "… uploads get a longer limit than text calls" grep -q 'TG_MAX_TIME=${TG_UPLOAD_MAX_TIME:-60}' "$root/lib/canccu-telegram.sh"
rm "$FAKE/tg-slow-sendPhoto"

tg notify-reset
accept5
ok "before the reset: the ask is sent" eq "$(cut -f1 "$(ND)/sent")" 1
: > "$(EV)"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
ok "events reset, a new ask with a used id: sent" eq "$(cut -f1 "$(ND)/sent" | tr '\n' ' ') $(calls sendMessage)" "1  2"
ok "… in a topic of its own" eq "$(calls createForumTopic)" 2
ok "… a closed line edits the new message, not the old one" eq "$(lib feed - info closed 8 - - "closes 1: check" >/dev/null; calls editMessageText) $(call editMessageText | grep -c 'message_id=101')" "1 0"

tg notify-down
touch "$FAKE/tg-down"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
ok "Telegram down: the feed line is written, the send waits for a retry" eq "$(wc -l < "$(EV)") $(cat "$(ND)/retry")" "1 1"
lib feed - info closed 8 - - "closes 1: check" >/dev/null
ok "… an item that settled before it was sent is never sent" eq "$(cat "$(ND)/retry")" ""

tg notify-no-token
rm "$E/telegram-token"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
ok "no token: nothing called, kept for a retry, logged once" \
  eq "$(calls sendMessage) $(cat "$(ND)/retry") $(grep -c 'telegram: no Telegram bot token file' "$CANCCU_HOME/dispatch.log")" "0 1 1"

# ---------------------------------------------------------------- topics without a forum

tg notify-private TELEGRAM_CHAT_ID=4242
lib feed po ask idle 8 - - "#8 idle" >/dev/null
ok "a private chat: no forum topic, the message opens a reply chain" eq "$(calls createForumTopic) $(cut -f1,6 "$(ND)/topics")" "0 m101	101"
ok "… not in a thread" not grep -q message_thread_id <<<"$(call sendMessage)"

tg notify-noforum
touch "$FAKE/tg-refuse-createForumTopic"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
ok "a group without topics: falls back to a reply chain" eq "$(calls createForumTopic) $(calls sendMessage) $(cut -f1 "$(ND)/topics")" "1 1 m101"
ok "… and says so once" eq "$(grep -c 'telegram: no forum topic' "$CANCCU_HOME/dispatch.log")" 1

# ---------------------------------------------------------------- replies: the inbox

tg notify-poll
accept5                                   # topic t101, message 102
{ upd 1 -1009876 777 101 - 201 'yes, but rename it'
  upd 2 -1009876 888 101 - 202 'someone else'
  upd 3 -5555 777 101 - 203 'another chat'
  upd 4 -1009876 777 999 - 204 'another topic'
  upd 5 -1009876 777 - - 205 'outside every topic'
  upd 6 -1009876 777 101 - 206 $'two\tlines\nhere'
} | jq -s . > "$FAKE/tg-updates.json"
dispatch --once
ok "replies: only the product owner's, in an open topic, are kept" eq "$(inbox | wc -l)" 2
ok "… as time, topic, unit, PR and text" eq "$(inbox | sed -n 1p)" "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)	t101	5	50	yes, but rename it"
ok "… a tab or newline folded to a space" eq "$(inbox | sed -n 2p | cut -f5)" "two lines here"
ok "… the dropped ones counted in the log" grep -q 'telegram: 2 replies kept, 4 other messages dropped' "$CANCCU_HOME/dispatch.log"
ok "… the offset moves past every update" eq "$(cat "$(ND)/offset")" 7
dispatch --once
ok "… the next pass asks from there and keeps nothing twice" eq "$(grep '^getUpdates' "$FAKE/tg.log" | tail -1 | grep -c 'offset=7') $(inbox | wc -l)" "1 2"
notifycmd --project web close t101 >/dev/null 2>&1
upd 7 -1009876 777 101 - 207 'after the close' | jq -s . > "$FAKE/tg-updates.json"
dispatch --once
ok "… a reply in a closed topic is dropped" eq "$(inbox | wc -l)" 2
ok "… no reply is ever acted on: no reply's text reaches a gh call" not grep -qE 'rename it|two lines|after the close' "$FAKE/gh.log"

tg notify-poll-private TELEGRAM_CHAT_ID=4242
lib feed po ask idle 8 - - "#8 idle" >/dev/null      # root message 101, topic m101
notifycmd --project web reply m101 'looking into it' >/dev/null 2>&1   # message 102
{ upd 1 4242 777 - 101 301 'reply to the root'
  upd 2 4242 777 - 102 302 'reply to the leader'
  upd 3 4242 777 - 55 303 'reply to something else'
  upd 4 4242 777 - 301 304 'reply to a kept reply'
} | jq -s . > "$FAKE/tg-updates.json"
dispatch --once
ok "reply chains: replies to the root, the leader or a kept reply belong to the topic" \
  eq "$(inbox | cut -f2,5 | tr '\n' '|')" "m101	reply to the root|m101	reply to the leader|m101	reply to a kept reply|"
ok "… with the leader's reply sent as a reply to the root" grep -qF 'reply_parameters={"message_id":101}' <<<"$(call sendMessage 2)"

tg notify-poll-error
touch "$FAKE/tg-refuse-getUpdates"
dispatch --once; dispatch --once
ok "reading replies fails: logged once, the offset unchanged" eq "$(grep -c 'telegram: reading replies failed' "$CANCCU_HOME/dispatch.log") $(cat "$(ND)/offset" 2>/dev/null || echo none)" "1 none"

tg notify-poll-nouser TELEGRAM_USER_ID=
dispatch --once
ok "no TELEGRAM_USER_ID: no reply is read" eq "$(calls getUpdates)" 0

# ---------------------------------------------------------------- canccu-notify

tg notify-cmd
accept5                                   # topic t101, message 102
out=$(notifycmd --project web reply t101 'I will check the rename' 2>&1); rc=$?
ok "reply: posted in the topic" eq "$rc $(call sendMessage 2 | grep -c 'message_thread_id=101.*text=I will check the rename')" "0 1"
out=$(notifycmd --project web note t101 'summary: safe to accept' 2>&1); rc=$?
ok "note: a reply to the item's message" eq "$rc $(call sendMessage 3 | grep -c 'reply_parameters={"message_id":102}')" "0 1"
ok "… marked as the leader's" grep -qF "text=Leader's note: summary: safe to accept" <<<"$(call sendMessage 3)"
ok "topics: lists the open ones" grep -qx "t101	#5	PR #50	feed line 1" <<<"$(notifycmd --project web topics)"
out=$(notifycmd --project web reply t999 x 2>&1); rc=$?
ok "reply to an unknown topic: refused" eq "$rc $(grep -c 'no open topic t999' <<<"$out")" "1 1"
out=$(notifycmd --project web close t101 2>&1); rc=$?
ok "close: says so, closes the forum topic, marks it closed" eq "$rc $(call sendMessage 4 | grep -c 'text=Closed.') $(calls closeForumTopic) $(cut -f5 "$(ND)/topics")" "0 1 1 closed"
out=$(notifycmd --project web reply t101 x 2>&1); rc=$?
ok "… a closed topic takes no reply" eq "$rc" 1
ok "every call writes its actions-log line" eq "$(cut -f3 "$CANCCU_HOME/actions.log" | sort | uniq -c | awk '{ print $2 $1 }' | tr '\n' ' ')" "canccu-notify6 "
out=$(CANCCU_ACTOR=run notifycmd --project web reply t101 x 2>&1); rc=$?
ok "a run never notifies" eq "$rc $(grep -c 'refused: a run never' <<<"$out")" "1 1"
ok "canccu-notify --help" grep -q 'canccu-notify' <<<"$(notifycmd --help)"

tg notify-photos
accept5
printf 'PNG' > "$E/a.png"; printf 'PNG' > "$E/b.png"
out=$(notifycmd --project web photos 5 "$E/a.png" 2>&1); rc=$?
ok "photos: one file is one photo in the unit's topic" eq "$rc $(call sendPhoto | grep -c 'message_thread_id=101')" "0 1"
ok "… captioned with the link" grep -qF 'pull/50' <<<"$(call sendPhoto)"
for i in $(seq 1 12); do cp "$E/a.png" "$E/p$i.png"; done
out=$(notifycmd --project web photos 5 "$E"/p*.png 2>&1); rc=$?
ok "… twelve files: two albums (ten at most each)" eq "$rc $(calls sendMediaGroup)" "0 2"
out=$(notifycmd --project web photos 5 "$E/none.png" 2>&1); rc=$?
ok "… a missing file: refused, nothing sent" eq "$rc $(calls sendMediaGroup) $(calls sendPhoto)" "1 2 1"
upd 1 -1009876 777 - - 201 'hello' | jq -s . > "$FAKE/tg-updates.json"
ok "… one line per chat and sender" grep -q 'chat -1009876 · from 777' <<<"$(notifycmd --project web ids)"

# ---------------------------------------------------------------- the SVGs a passed PR changes

tg notify-svg
mkdir -p "$E/bin"; printf '#!/bin/sh\nwhile [ $# -gt 1 ]; do [ "$1" = -o ] && printf PNG > "$2"; shift; done\necho "$@" >> "%s/rsvg.log"\n' "$FAKE" > "$E/bin/rsvg-convert"; chmod +x "$E/bin/rsvg-convert"
accept5
lib st_set 5 pass_sha="$HA"
json files50 '[{"filename": "web/mock/home.svg"}, {"filename": "web/app.ts"}]'
route 'api --paginate repos/example-org/web/pulls/50/files*' files50
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' > "$FAKE/home.svg"
route "api repos/example-org/web/contents/web/mock/home.svg?ref=$HA*" home.svg
PATH="$E/bin:$PATH" dispatch --once
ok "a passed PR that changes an SVG: it is rendered and sent into the unit's topic" eq "$(call sendPhoto | grep -c 'message_thread_id=101.*PR #50')" 1
PATH="$E/bin:$PATH" dispatch --once
ok "… once per head" eq "$(calls sendPhoto)" 1
ok "… the PR body's image links are never fetched" not grep -qi 'user-images\|user-attachments' "$FAKE/gh.log"
ok "no process of these tests is left running" eq "$(left)" ""
left | cut -d' ' -f1 | xargs -r kill 2>/dev/null

echo "canccu-notify tests: $npass passed, $nfail failed"
(( nfail == 0 ))
