<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Plan for #39: maintainer notifications on Telegram, with reply topics for the leader

> For the session that builds it: run this plan task by task (executing-plans), test first in
> each task, once the issue carries `plan-ok`. Package `telegram-notify`, one branch, one PR.

**Goal:** when an item needs the product owner, the dispatcher sends one Telegram message at the
state change, built by its own shell code (no model run). Each message opens a topic; only the
product owner's replies in an open topic reach an inbox file the leader reads. Nothing types into
a terminal. `NOTIFY` picks GitHub, Telegram, both or off.

**Why a plan first:** risk high (a new channel that reaches the product owner and feeds text
the product owner writes to the leader), a bot token on the host, and seven open points where
the issue, its comments and `docs/plan/` disagree or leave the shape open (questions below).
`canccu-init --check` does not exist yet, and the `canccu-tg` prototype the issue moves "here"
is not in this repo, so the worker cannot copy it.

## What exists (origin/main f401e46)

- **The feed** (`lib/canccu-feed.sh`, contracts §3): `feed()` appends one line per change of
  state, under its own lock, with owner, class, kind, unit, PR and URL. Accept, needs-you, plan,
  question, run-ended, idle, handover, pr-needs-you and the holds (`hold-usage`, `hold-pace`)
  already write it. `feed_closed` settles an item.
- **The ask form** (`lib/canccu-ask.sh`, `ask_form`, contracts §4): one renderer for every ask,
  `NOTIFY_CONTENT=link` already applied. The Telegram text is this form, unchanged.
- **The GitHub ping** (`lib/canccu-ping.sh`, `ping_tick`): `PING=on|off`, `PING_KINDS`, one
  comment per issue edited in place (`pings/<n>`).
- **The leader's watch** (`canccu-dispatcher watch --file <path>`, #216, `lead_watch`): every
  new line of a `--file` wakes it at once. The inbox is such a file: no new watcher.

## Shape

1. **The sender hooks the feed.** `feed()` calls `notify_event <id>` after the line is written
   (outside its lock). `notify_event` sends only class `ask`/`interrupt` lines whose owner is
   `po`, and the kinds of question 3. A `closed` line edits the item's message to start with
   `Closed:` (contracts §4: "a settled item marks it closed"). This is "at the state change
   itself": no polling of the feed, no log tailing.
2. **One message per item, never twice.** `notify/sent` (kv, under `kv_lock`) maps the feed id to
   `<message id> <topic id>`. A send that timed out is recorded as sent (like the ping: a
   duplicate is worse than a miss); a refused send is logged once with `warn_once` and retried
   by the next pass's `notify_retry` from the feed lines with no record.
3. **The text** is `ask_form` for the unit's item (accept, plan, question, needs-you,
   checkpoint); for kinds with no form (idle, hold, handover, run-ended) the feed line's own
   text, then `Recommended: answer needed` and the link. Sent as plain text (no `parse_mode`), so
   no markup in a reason can change the message.
4. **Topics.** Each message opens a forum topic (`createForumTopic` in a supergroup with topics
   on, named `#<unit> <kind>`), the message goes into it; `notify/topics` holds
   `<topic id>	<unit>	<pr>	<feed id>	open|closed`. See question 1 for the fallback.
5. **Replies → inbox.** `notify_poll` runs once per dispatcher pass (`getUpdates`, timeout 0,
   the offset stored in `notify/offset`): an update is kept only when it is a message, in the
   configured chat, from `TELEGRAM_USER_ID`, in an open topic. Kept lines go to
   `$CANCCU_HOME/inbox`: `<time>	<topic>	<unit>	<pr>	<text>` (tabs and newlines in the text
   folded to spaces, cut at 2000 characters). Every other update is dropped and only counted.
   The leader runs `canccu-dispatcher watch --file "$CANCCU_HOME/inbox"`; the patrol reads the
   inbox as its backstop. No reply ever acts: the inbox is text for the leader, never a command
   (rule 7; the 0.3 `ok` reply is not in this issue).
6. **The leader answers.** `canccu-notify reply <topic> <text>` posts in the topic;
   `canccu-notify close <topic>` posts `Closed.`, closes the forum topic and marks it closed, so
   later replies there are dropped. With `LEADER=on` the leader also gets the same event from the
   feed (`wait --owner leader`), as today; `canccu-notify note <topic> <text>` lets it add its
   summary and recommendation under the dispatcher's message.
7. **Images** (comment 2): `canccu-notify photos <unit> <file>...` sends one `sendMediaGroup`
   (≤ 10, else batches of 10) with a short caption and the link into the unit's topic. The
   dispatcher calls it for a PR whose `PREVIEW_CMD` (N1) wrote captures; SVG mockups are rendered
   with `rsvg-convert` when it is installed, else skipped with one log line. Screenshots linked
   in a PR body are not fetched (they are worker text; see question 6).
8. **Settings** (contracts §5 and rule 5): `NOTIFY` (`github` default, `telegram`, `both`, `off`;
   locked), plus two new locked keys `TELEGRAM_CHAT_ID` and `TELEGRAM_USER_ID`, and
   `TELEGRAM_TOKEN_FILE` (not settable through `config set`, like `REVIEWER_TOKEN_FILE`; default
   `~/.config/canccu/telegram-token`, refused unless mode 600 and outside every repo). Each gets
   its line in `lib/canccu-config.default`, its row in `lib/canccu-settings.tsv` and
   `docs/reference/config.md`, and a doctor line (a missing or open token, a missing chat id).
   `NOTIFY=github` is today's ping; `PING` and `PING_KINDS` keep working inside it.
9. **The fake API.** `tests/lib/fake-telegram` (a shell stub `curl` reaches through
   `TELEGRAM_API`, default `https://api.telegram.org`) records each call and answers from a
   fixture queue, like the harness's fake `gh`. No test reaches the network.
10. **Code layout.** `lib/canccu-notify.sh` (send, record, retry, edit on close),
    `lib/canccu-telegram.sh` (the API calls, the poll, the inbox), `bin/canccu-notify` (reply,
    note, close, photos, test), each under 400 lines; `lib/canccu-feed.sh` and
    `lib/canccu-ping.sh` get call sites only.

## Tasks (each: failing test, code, `tests/run <file>`, commit, push)

1. Settings and doctor lines (`tests/canccu-config.sh`, `tests/canccu-doctor.sh`).
2. The fake Telegram API and `lib/canccu-telegram.sh`'s send and edit (`tests/canccu-notify.sh`).
3. `notify_event` from `feed()`: one message per item, never twice, `Closed:` on settle, a refused
   send retried, a timed-out one not; `NOTIFY=off`/`github` send nothing to Telegram;
   `NOTIFY=github`/`both` still ping; `NOTIFY_CONTENT=link`.
4. Topics and the poll: replies from the product owner in an open topic land in the inbox; from
   another user, another chat, a closed topic or outside a topic, nothing; the offset never
   replays an update.
5. `bin/canccu-notify reply|note|close|photos` and the watch wake on an inbox line
   (`tests/canccu-waits.sh`).
6. The setup check (question 4), `docs/reference/notify.md` (the guide page), the index line,
   `CHANGELOG.md`.

## Open questions (for the product owner, before `plan-ok`)

1. **Topics.** Forum topics need a supergroup with topics on and the bot as an admin with
   "manage topics". The plan uses them, and with a plain private chat falls back to reply
   chains (a reply to the item's message, or to a reply of it, belongs to its topic). Is the
   fallback wanted, or is a topics group required?
2. **Polling.** Replies need `getUpdates` (or a webhook, which needs a public host). The plan
   polls once per dispatcher pass (latency up to `INTERVAL`, no extra service), instead of the
   prototype's always-on listener. Is a pass's delay acceptable, or should `canccu-notify listen`
   run as its own long-poll process (and who restarts it before 0.3's systemd units)?
3. **Which events.** Contracts §2 says class `info` is never pushed (the digest carries it), but
   comment 1 asks for "a step done, a usage stop or drain" and comment 3 for "a pace hold and a
   step polish issue", which are `info` today (`step-done`, `hold-usage`, `hold-pace`; the polish
   issue writes only a log line). The plan sends class `ask` and `interrupt` to their owner `po`,
   plus `step-done`, `hold` (all three) and a new feed kind `polish` (class `info`) to Telegram
   only. This needs a `Roadmap note:` for contracts §2 and §3 (the new kind). Agreed?
4. **`canccu-init --check` does not exist.** The plan adds a `--check` to `canccu-init` that, for
   now, checks only the notify setup (token file, mode, chat id, a `getMe` and a test message)
   and prints the BotFather and chat-id steps when one fails. The 1.0 "init check" grows from it.
   Or should these lines go into `canccu-doctor` instead?
5. **0.3's notifier service.** Contracts §5 lists `NOTIFY_BATCH_MIN`, `NOTIFY_MAX_PER_DAY`,
   `NOTIFY_REMIND_H`, `QUIET_HOURS` and a heartbeat for the notifier as 0.3. This issue sends
   each item at once with no cap, no reminder, no quiet hours and no heartbeat: those keys are
   left out and stay for the 0.3 notifier package. Agreed, or are any of them part of #39?
6. **Images from a PR body.** Comment 2 names "screenshots in a PR body". Those links are worker
   text (contracts §4: nothing from the PR body), and fetching them sends arbitrary URLs from the
   host. The plan sends only `PREVIEW_CMD` captures and SVG files the PR changes, rendered on the
   host. Is that enough, or should PR body image links on github.com user-content be fetched?
7. **The prototype.** `canccu-tg` lives outside this repo. Is there behaviour of it (message
   layout, inbox format, commands) the worker must keep word for word? Without an answer the
   plan's formats above apply.

## Decisions to approve

1. `NOTIFY=github` keeps `PING` as it is (both must be on for a GitHub mention); `NOTIFY=off`
   silences the ping too.
2. A Telegram send never blocks the pass for more than 10 s (`curl --max-time 10`); the
   feed line is written first, so a dead Telegram never loses a state change.
3. The token reaches only the `curl` call (read from the file into the URL inside a subshell,
   never in a log, the state, the inbox or a process title: `curl --config -` reads it on
   stdin).
4. The inbox is never trimmed by the dispatcher; the leader's `watch` offset tracks it.

## Review focus

- A reply from anyone but `TELEGRAM_USER_ID`, or outside an open topic, never reaches the inbox.
- No reply text ever reaches a shell command, a label, a merge or a run's prompt directly.
- The token never appears in a log, a test's recorded call or a process list.
- With `NOTIFY` unset, every existing test passes unchanged (rule 4: works without Telegram).
