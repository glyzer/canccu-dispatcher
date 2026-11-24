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

echo "canccu-notify3 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
