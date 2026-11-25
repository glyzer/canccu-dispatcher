#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-notify3.sh — the Telegram notify's failure paths (#295). Harness: tests/lib/harness.sh.
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
track_left

TG_TOKEN=123456:fake-telegram-token-for-tests
ND() { echo "$CANCCU_HOME/notify"; }
tg() {
  local n=$1; shift
  env_new "$n" NOTIFY=telegram TELEGRAM_CHAT_ID=-1009876 TELEGRAM_USER_ID=777 "TELEGRAM_TOKEN_FILE=$T/$n/telegram-token" \
    NOTIFY_BATCH_MIN=0 "NOTIFY_KINDS='accept plan question needs-you checkpoint step-done idle hold polish'" "$@"
  printf '%s\n' "$TG_TOKEN" > "$E/telegram-token"; chmod 600 "$E/telegram-token"
  : > "$FAKE/tg.log"
}
calls() { grep -c "^$1 " "$FAKE/tg.log"; }
notifycmd() { PATH="$fb:$PATH" "$root/bin/canccu-notify" "$@"; }

tg notify3-permanent
echo "Bad Request: message thread not found" > "$FAKE/tg-refuse-sendMessage"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
ok "a permanent refusal is given up, not kept for a retry" eq "$(cat "$(ND)/retry" 2>/dev/null)" ""
rm "$FAKE/tg-refuse-sendMessage"
lib feed po ask idle 9 - - "#9 idle" >/dev/null
ok "… and the line behind it is sent" eq "$(calls sendMessage) $(cut -f1 "$(ND)/sent" | tr '\n' ' ')" "2 1 2 "

tg notify3-noforum
echo "Bad Request: the chat is not a forum" > "$FAKE/tg-refuse-createForumTopic"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
lib feed po ask idle 9 - - "#9 idle" >/dev/null
ok "a group without topics: createForumTopic is asked once, not for every message" eq "$(calls createForumTopic) $(calls sendMessage)" "1 2"

tg notify3-settle-retry
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 "$HA" green | prs
lib feed po ask accept 5 50 https://example.invalid/50 "#5 accept" >/dev/null
echo "Bad Request: refused" > "$FAKE/tg-refuse-editMessageText"
lib feed - info closed 5 - - "closes 1: done" >/dev/null
ok "a failed Closed: edit is kept to try again" eq "$(cut -f1 "$(ND)/unsettled" 2>/dev/null)" 1
rm "$FAKE/tg-refuse-editMessageText"
dispatch --once
ok "… the next pass edits the message and forgets it" eq "$(calls editMessageText) $(cat "$(ND)/unsettled" 2>/dev/null)" "2 "

# a refusal that says there is nothing left to edit or close counts as done: no retry for good
tg notify3-settle-done
lib feed po ask accept 5 50 https://example.invalid/50 "#5 accept" >/dev/null
echo "Bad Request: message is not modified" > "$FAKE/tg-refuse-editMessageText"
echo "Bad Request: TOPIC_NOT_MODIFIED" > "$FAKE/tg-refuse-closeForumTopic"
lib feed - info closed 5 - - "closes 1: done" >/dev/null
ok "an edit 'not modified' and a topic the user closed: done, nothing kept to retry" eq "[$(cat "$(ND)/unsettled" 2>/dev/null)] $(cut -f5 "$(ND)/topics")" "[] closed"
dispatch --once; dispatch --once
ok "… and not tried again on later passes" eq "$(calls editMessageText) $(calls closeForumTopic)" "1 1"

# Telegram down: the loop over what is left to settle stops at the first failure
tg notify3-settle-down
lib feed po ask accept 5 50 https://example.invalid/50 "#5 accept" >/dev/null
lib feed po ask accept 6 60 https://example.invalid/60 "#6 accept" >/dev/null
echo "Bad Request: refused" > "$FAKE/tg-refuse-editMessageText"
lib feed - info closed 5 - - "closes 1: done" >/dev/null
lib feed - info closed 6 - - "closes 2: done" >/dev/null
: > "$FAKE/tg.log"; touch "$FAKE/tg-down"
dispatch --once
ok "two ids unsettled, Telegram down: one edit tried in the pass, not one per id" eq "$(calls editMessageText) $(cut -f1 "$(ND)/unsettled" | tr '\n' ' ')" "1 1 2 "

# a refusal at the head of what is left to settle does not hold up the lines behind it (#317)
settle_two() {
  tg "$1"
  lib feed po ask accept 5 50 https://example.invalid/50 "#5 accept" >/dev/null
  lib feed po ask accept 6 60 https://example.invalid/60 "#6 accept" >/dev/null
  echo "Bad Request: refused" > "$FAKE/tg-refuse-editMessageText"; cp "$FAKE/tg-refuse-editMessageText" "$FAKE/tg-refuse-closeForumTopic"
  lib feed - info closed 5 - - "closes 1: done" >/dev/null
  lib feed - info closed 6 - - "closes 2: done" >/dev/null
  rm "$FAKE/tg-refuse-editMessageText" "$FAKE/tg-refuse-closeForumTopic"; : > "$FAKE/tg.log"
}
settle_two notify3-settle-cant-edit
echo "Bad Request: message can't be edited" > "$FAKE/tg-refuse-editMessageText"
dispatch --once
ok "an edit refused for good at the head: given up, and the line behind it is tried" eq "$(calls editMessageText) [$(cat "$(ND)/unsettled" 2>/dev/null)]" "2 []"
settle_two notify3-settle-no-rights
echo "Bad Request: not enough rights to manage forum topics" > "$FAKE/tg-refuse-closeForumTopic"
dispatch --once
ok "a close refused at the head: kept, and the line behind it is tried" eq "$(calls closeForumTopic) $(cut -f1 "$(ND)/unsettled" | tr '\n' ' ')" "2 1 2 "
ok "… Telegram's refusal still keeps the edits done" eq "$(calls editMessageText)" 2

# a reset of the feed ids clears what waits to be settled: a new item with the same id is not closed
tg notify3-reset-unsettled
mkdir -p "$(ND)"; printf '1\n' > "$(ND)/unsettled"
lib _nt_reset
ok "the events file reset: the unsettled ids go with the other id files" test ! -s "$(ND)/unsettled"

# a createForumTopic that failed for another reason than "not a forum" is asked again
tg notify3-forum-down
touch "$FAKE/tg-down"
lib feed po ask idle 8 - - "#8 idle" >/dev/null
rm "$FAKE/tg-down"
lib feed po ask idle 9 - - "#9 idle" >/dev/null
ok "a connection failure on createForumTopic does not turn topics off for a day" eq "$(test -e "$(ND)/noforum"; echo $?) $(calls createForumTopic)" "1 2"

# a read killed half-way leaves no half-appended inbox lines: the next read appends each reply once
tg notify3-read-killed
mkdir -p "$(ND)"; printf 't50\t1\t5\t50\topen\t-\n' > "$(ND)/topics"
jq -n '[11, 12] | map({update_id: ., message: {message_id: ., chat: {id: -1009876}, from: {id: 777}, is_topic_message: true, message_thread_id: 50, text: "reply \(.)"}})' > "$FAKE/tg-updates.json"
( lib eval 'nt_add() { [[ $2 == 12* ]] && kill -9 $BASHPID; _nt_locked _nt_append "$@"; }; notify_read 0' >/dev/null ) 2>/dev/null
lib notify_read 0 >/dev/null
ok "a read killed at the second reply: the inbox holds each reply once after the next read" eq "$(grep -c . "$CANCCU_HOME/inbox") $(sort -u "$CANCCU_HOME/inbox" | grep -c .)" "2 2"

tg notify3-photos
printf 'secret\n' > "$E/s.png"
out=$(notifycmd --project web photos 5 "$E/s.png" 2>&1); rc=$?
ok "photos: a file that is no PNG is refused, nothing sent" eq "$rc $(calls sendPhoto)" "1 0"
ok "… and says why" grep -q 'is not a PNG file' <<<"$out"

tg notify3-digest-hour NOTIFY_DIGEST_HOUR=30
ok "a digest hour beyond 23 is named, not reported as quiet hours" grep -q 'NOTIFY_DIGEST_HOUR=30 is no hour' <<<"$(lib notify_problem)"

tg notify3-listener2
mkdir -p "$(ND)"; exec 8>>"$(ND)/.listen.lock"; flock -n 8
out=$(CANCCU_LISTEN_ROUNDS=1 timeout 60 env PATH="$fb:$PATH" "$root/bin/canccu-notify" --project web listen 2>&1); rc=$?
exec 8>&-
ok "a second listener is refused when one holds the lock" eq "$rc $(grep -c 'another listener' <<<"$out")" "1 1"

tg notify3-svg-error
mkdir -p "$E/bin"; printf '#!/bin/sh\nwhile [ $# -gt 1 ]; do [ "$1" = -o ] && printf PNG > "$2"; shift; done\n' > "$E/bin/rsvg-convert"; chmod +x "$E/bin/rsvg-convert"
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 "$HA" green | prs
lib st_set 5 phase=accept pr=50 accept_sha="$HA" pass_sha="$HA" "accept_at=$NOW" reason=x
json files50 '[{"filename": "web/mock/home.svg"}]'
route 'api --paginate repos/example-org/web/pulls/50/files*' files50
PATH="$E/bin:$PATH" dispatch --once
ok "an SVG fetch that failed (not a 404): the head is not recorded as done" eq "$(cut -f1 "$(ND)/images" 2>/dev/null)" ""

# an SVG fetch: only gh's (HTTP 404) means the file is gone; a 404 in the path or another error's
# text is an error, tried again next pass (#317)
svg_env() {
  tg "$1"
  mkdir -p "$E/bin"; printf '#!/bin/sh\nwhile [ $# -gt 1 ]; do [ "$1" = -o ] && printf PNG > "$2"; shift; done\n' > "$E/bin/rsvg-convert"; chmod +x "$E/bin/rsvg-convert"
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 "$HA" green | prs
  lib st_set 5 phase=accept pr=50 accept_sha="$HA" pass_sha="$HA" "accept_at=$NOW" reason=x
  json files50 '[{"filename": "img/404.svg"}]'
  route 'api --paginate repos/example-org/web/pulls/50/files*' files50
}
svg_env notify3-svg-404-path
route "api repos/example-org/web/contents/img/404.svg?ref=$HA*" FAIL
PATH="$E/bin:$PATH" dispatch --once
ok "an SVG named 404 that failed to load: the head is not recorded as done" eq "$(cut -f1 "$(ND)/images" 2>/dev/null)" ""
svg_env notify3-svg-404-gone
route "api repos/example-org/web/contents/img/404.svg?ref=$HA*" NOTFOUND
PATH="$E/bin:$PATH" dispatch --once
ok "… a file the PR deleted (HTTP 404): skipped, the head is done" eq "$(cut -f1 "$(ND)/images" 2>/dev/null)" 50

echo "canccu-notify3 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
