#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-notify2.sh — Telegram stays quiet (#252): the kinds, the batching, quiet hours, the
# daily cap, the digest, its reminders and the listener. The one-item behaviour: tests/canccu-notify.sh.
# Harness: tests/lib/harness.sh (its fake curl is the fake Telegram Bot API).
#   bash tests/canccu-notify2.sh    one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

TG_TOKEN=123456:fake-telegram-token-for-tests
EV() { echo "$CANCCU_HOME/events"; }
ND() { echo "$CANCCU_HOME/notify"; }
# at <hh:mm> [day offset]: the epoch of that UTC time on the test day (2030-11-05), days later
at() { echo $(( $(date -u -d "2030-11-05T$1:00Z" +%s) + ${2:-0} * 86400 )); }
# tg <name> [config...]: a project that notifies on Telegram, in a forum supergroup, with the
# defaults of the quiet settings; the clock of QUIET_HOURS is UTC
tg() {
  local n=$1; shift
  env_new "$n" NOTIFY=telegram TELEGRAM_CHAT_ID=-1009876 TELEGRAM_USER_ID=777 "TELEGRAM_TOKEN_FILE=$T/$n/telegram-token" QUIET_TZ=UTC "$@"
  printf '%s\n' "$TG_TOKEN" > "$E/telegram-token"; chmod 600 "$E/telegram-token"
  : > "$FAKE/tg.log"
}
calls() { grep -c "^$1 " "$FAKE/tg.log"; }
call() { grep "^$1 " "$FAKE/tg.log" | sed -n "${2:-1}p"; }
# loud: the messages that ring the phone (a batch's items go silently into their topics)
loud() { grep '^sendMessage ' "$FAKE/tg.log" | grep -v 'disable_notification=true'; }
inbox() { cat "$CANCCU_HOME/inbox" 2>/dev/null; }
notifycmd() { PATH="$fb:$PATH" "$root/bin/canccu-notify" "$@"; }
tick() { CANCCU_NOW=$1 lib notify_tick; }
# units <k...>: issues k and PRs k*10, each in check, ready to enter accept
units() {
  local k
  for k in "$@"; do issue "$k" in-progress,awaiting-accept; done | issues
  for k in "$@"; do pr "$((k * 10))" "$k" "$HA" green; done | prs
  for k in "$@"; do state "$k" phase=check pr="$((k * 10))" "check_at=$NOW"; done
}
# acc <k>: unit k enters accept on PR k*10 (one feed line, owner po)
acc() { lib st_set "$1" phase=accept pr="$(( $1 * 10 ))" accept_sha="$HA" "accept_at=$CANCCU_NOW" "reason=manual: plan tier"; }
upd() {
  jq -n --argjson u "$1" --argjson c "$2" --argjson f "$3" --arg th "$4" --arg r "$5" --argjson m "$6" --arg t "$7" '
    {update_id: $u, message: ({message_id: $m, chat: {id: $c}, from: {id: $f}, text: $t}
      + (if $th == "-" then {} else {is_topic_message: true, message_thread_id: ($th | tonumber)} end)
      + (if $r == "-" then {} else {reply_to_message: {message_id: ($r | tonumber)}} end))}'
}

# ---------------------------------------------------------------- the settings

env_new notify2-settings
for kv in "NOTIFY_KINDS='accept plan question needs-you checkpoint step-done'" NOTIFY_BATCH_MIN=10 "QUIET_HOURS=''" \
          "QUIET_TZ=''" NOTIFY_MAX_PER_DAY=12 "NOTIFY_DIGEST_HOUR=''" NOTIFY_REMIND_H=0; do
  k=${kv%%=*}
  ok "$k: its default, and an open project row in the settings table" \
    eq "$(grep -c "^$kv\( \|$\)" "$root/lib/canccu-config.default") $(awk -F '\t' -v k="$k" '$1 == k { print $3, $4 }' "$root/lib/canccu-settings.tsv")" "1 project open"
done
tg notify2-doctor QUIET_HOURS=late
ok "doctor: a QUIET_HOURS that is no <hour>-<hour> is a line" grep -q 'QUIET_HOURS=late' <<<"$(lib notify_problem)"

# ---------------------------------------------------------------- kinds

tg notify2-day
units 5
cp "$root/tests/fixtures/notify/feed-day.events" "$(EV)"
while IFS=$'\t' read -r t id _; do
  e=$(date -u -d "$t" +%s)
  CANCCU_NOW=$e lib notify_event "$id"; tick "$e"
done < "$(EV)"
tick "$(at 23:59)"
ok "the defaults, a day of the feed: no idle message" not grep -q 'sits in' "$FAKE/tg.log"
ok "… and no hold message" not grep -qE 'nothing new starts' "$FAKE/tg.log"
ok "… the accept, the question and the step done went" \
  eq "$(grep -c '^sendMessage .*PR #50 waits for your accept' "$FAKE/tg.log") $(grep -c '^sendMessage .*question here needs the product owner' "$FAKE/tg.log") $(grep -c '^sendMessage .*step 3 Events is done' "$FAKE/tg.log")" "1 1 1"
ok "… and no digest: NOTIFY_DIGEST_HOUR is empty" not grep -q 'Daily digest' "$FAKE/tg.log"

tg notify2-idle-open NOTIFY_BATCH_MIN=0 "NOTIFY_KINDS='accept idle'"
units 5; acc 5
lib feed po ask idle 5 - - "#5 sits in accept for 61 min with nothing running" >/dev/null
lib feed po ask idle 8 - - "#8 sits in check for 61 min with nothing running" >/dev/null
ok "idle named in NOTIFY_KINDS: sent, but never for a unit whose item is open" \
  eq "$(grep -c '#5 sits in' "$FAKE/tg.log") $(grep -c '#8 sits in' "$FAKE/tg.log")" "0 1"

tg notify2-interrupt NOTIFY_BATCH_MIN=0 NOTIFY_KINDS=accept
lib feed po interrupt dispatcher - - - "the dispatcher of web is dead: no pass for 30 min" >/dev/null
ok "class interrupt goes whatever NOTIFY_KINDS says" grep -q 'the dispatcher of web is dead' <<<"$(loud)"

# ---------------------------------------------------------------- batching

tg notify2-batch
units 5 6 7; acc 5; acc 6; acc 7
ok "three accepts: nothing at once (the batch window is open)" eq "$(calls sendMessage)" 0
tick "$(at 12:05)"
ok "… nor before NOTIFY_BATCH_MIN is over" eq "$(calls sendMessage)" 0
tick "$(at 12:10)"
ok "… then one message rings the phone" eq "$(loud | wc -l)" 1
ok "… with three numbered lines, each with its link" \
  eq "$(loud | grep -o '\\n[123]\. #[567] accept: plan tier https://github.com/example-org/web/pull/[567]0' | wc -l)" 3
ok "… ending in the one reply that settles them all" grep -q '\\nReply: accept 50 60 70 link_preview_options=' <<<"$(loud)"
ok "… each item still has its topic, its message sent silently" \
  eq "$(calls createForumTopic) $(grep -c '^sendMessage .*disable_notification=true' "$FAKE/tg.log")" "3 3"
ok "… the batch's message is a topic too, for the reply that settles all" \
  eq "$(awk -F '\t' '$3 == "5,6,7" { print $1 ~ /^m/, $4, $5 }' "$(ND)/topics")" "1 50,60,70 open"
b=$(awk -F '\t' '$3 == "5,6,7" { print $6 }' "$(ND)/topics")
upd 1 -1009876 777 - "$b" 301 'accept 50 60 70' | jq -s . > "$FAKE/tg-updates.json"
tick "$(at 12:11)"
ok "… a reply to it reaches the inbox with its units and PRs" eq "$(inbox | cut -f3-5)" "5,6,7	50,60,70	accept 50 60 70"
tick "$(at 12:30)"
ok "… nothing is sent twice" eq "$(calls sendMessage)" 4

tg notify2-batch-one
units 5; acc 5
tick "$(at 12:10)"
ok "one item in the window: its own message in its topic, as before" \
  eq "$(loud | wc -l) $(loud | grep -c 'message_thread_id=101.*PR #50 waits for your accept')" "1 1"

tg notify2-batch-settled
units 5 6; acc 5; acc 6
lib st_set 5 phase=merging
tick "$(at 12:10)"
ok "an item that settles in the window is never sent" eq "$(grep -c 'PR #50 waits' "$FAKE/tg.log") $(grep -c 'PR #60 waits' "$FAKE/tg.log")" "0 1"

# ---------------------------------------------------------------- quiet hours

tg notify2-quiet QUIET_HOURS=22-07
units 5 6
export CANCCU_NOW; CANCCU_NOW=$(at 23:00)
acc 5; acc 6
lib feed po interrupt dispatcher - - - "the dispatcher of web is dead: no pass for 30 min" >/dev/null
ok "in QUIET_HOURS: only the interrupt goes" eq "$(loud | wc -l) $(loud | grep -c 'dispatcher of web is dead')" "1 1"
tick "$(at 23:30)"; tick "$(at 06:59 1)"
ok "… nothing else while they last, the batch window over or not" eq "$(calls sendMessage)" 1
tick "$(at 07:00 1)"
ok "… at their end the held items go as one batch" eq "$(loud | wc -l) $(loud | tail -1 | grep -c 'Reply: accept 50 60')" "2 1"
CANCCU_NOW=$NOW

# ---------------------------------------------------------------- the daily cap and the digest

tg notify2-cap NOTIFY_BATCH_MIN=0 NOTIFY_KINDS=idle NOTIFY_MAX_PER_DAY=2 NOTIFY_DIGEST_HOUR=18
for u in 8 9 10 11; do lib feed po ask idle "$u" "-" "https://github.com/example-org/web/issues/$u" "#$u sits in check for 61 min with nothing running" >/dev/null; done
ok "over NOTIFY_MAX_PER_DAY: the first two go" eq "$(grep -c '^sendMessage .*#[89] sits in' "$FAKE/tg.log")" 2
ok "… one line says the rest waits for the digest" eq "$(loud | grep -c 'daily cap of 2 messages.*the rest waits for the digest at 18:00')" 1
ok "… the others are not sent" not grep -qE '#1[01] sits in' "$FAKE/tg.log"
lib feed po ask idle 12 - - "#12 sits in check" >/dev/null
ok "… a later item says it no second time" eq "$(calls sendMessage)" 3
lib feed po interrupt dispatcher - - - "the dispatcher of web is dead" >/dev/null
ok "… an interrupt is never capped" eq "$(calls sendMessage)" 4
tick "$(at 17:59)"
ok "the digest waits for NOTIFY_DIGEST_HOUR" eq "$(calls sendMessage)" 4
tick "$(at 18:00)"
ok "… then goes once, in a topic of its own" \
  eq "$(calls sendMessage) $(grep -c '^createForumTopic .*name=Digest 2030-11-05' "$FAKE/tg.log")" "5 1"
d=$(call sendMessage 5)
ok "… with the capped items, each with its link" \
  eq "$(grep -o '#1[012] sits in check' <<<"$d" | wc -l) $(grep -c 'issues/10' <<<"$d")" "3 1"
tick "$(at 18:30)"; tick "$(at 09:00 1)"
ok "… once a day: nothing more that day, and the capped items are not sent again" eq "$(calls sendMessage)" 5
tick "$(at 18:00 1)"
ok "… the next day's digest" eq "$(grep -c '^sendMessage .*Daily digest 2030-11-06' "$FAKE/tg.log")" 1

tg notify2-digest NOTIFY_DIGEST_HOUR=18
printf '%s\t7\t70\taccepted by octo (label)\tEvents page\n' "$(at 09:05)" > "$CANCCU_HOME/merged.log"
printf '%s\tweb\t7\t1.25\tbuild\n' "$(at 08:00)" > "$WORKERS_DIR/spend.log"
tick "$(at 18:00)"
d=$(call sendMessage)
ok "the digest: the day's merges, who accepted them" grep -q '#7 Events page · PR #70 · accepted by octo (label)' <<<"$d"
ok "… what runs" grep -q '\\nRunning: none' <<<"$d"
ok "… the budget" grep -q 'Spent in 24 h: \$1.25 over 1 run' <<<"$d"
ok "… and what waits for the product owner" grep -q '\\nWaiting for you: none' <<<"$d"
ok "… a reply in its topic reaches the inbox (the topic is open)" eq "$(awk -F '\t' '$1 == "t101" { print $5 }' "$(ND)/topics")" open

tg notify2-remind NOTIFY_BATCH_MIN=0 NOTIFY_REMIND_H=12 NOTIFY_DIGEST_HOUR=1
units 5; acc 5
tick "$(at 01:00 1)"
ok "NOTIFY_REMIND_H: an item open longer is listed again in the digest" \
  grep -q 'Open longer than 12 h:\\n- #5 accept: plan tier https://github.com/example-org/web/pull/50' <<<"$(call sendMessage 2)"
ok "… never as a message of its own" eq "$(calls sendMessage)" 2
tg notify2-remind-off NOTIFY_BATCH_MIN=0 NOTIFY_DIGEST_HOUR=1
units 5; acc 5
tick "$(at 01:00 1)"
ok "NOTIFY_REMIND_H=0: no reminder" not grep -q 'Open longer' <<<"$(call sendMessage 2)"

# ---------------------------------------------------------------- the listener

tg notify2-listen NOTIFY_BATCH_MIN=0
units 5; acc 5                                     # topic t101
upd 1 -1009876 777 101 - 201 'yes' | jq -s . > "$FAKE/tg-updates.json"
CANCCU_LISTEN_ROUNDS=1 notifycmd --project web listen > "$E/out" 2>&1; rc=$?
ok "listen: a reply lands in the inbox" eq "$rc $(inbox | cut -f2,5)" "0 t101	yes"
ok "… read by a long poll" grep -q 'timeout=50' <<<"$(call getUpdates)"
ok "… under the pass's offset" eq "$(cat "$(ND)/offset")" 2
ok "… with a heartbeat" test -f "$(ND)/listen.beat"
exec 8>>"$(ND)/.listen.lock"; flock -n 8
: > "$FAKE/tg.log"; dispatch --once
ok "a live listener holds the lock: the pass does not poll" eq "$(calls getUpdates)" 0
ok "… and the doctor says nothing about it" not grep -q 'listener' <<<"$(lib notify_problem)"
exec 8>&-
dispatch --once
ok "the listener stopped: the pass polls as before" eq "$(calls getUpdates)" 1
ok "… the doctor says it is down" grep -q 'the Telegram listener is down' <<<"$(lib notify_problem)"
ok "… and so does canccu-status" grep -q 'the Telegram listener is down' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"
tg notify2-listen-none NOTIFY_BATCH_MIN=0
ok "no listener ever ran: the doctor says nothing about one" not grep -q 'listener' <<<"$(lib notify_problem)"

echo "canccu-notify2 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
