<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Notifications on Telegram

Part of the reference; the index is [`README.md`](README.md).

## Notifications

`NOTIFY` picks where an item that needs you is announced:

| `NOTIFY` | What happens |
|---|---|
| `github` (default) | The GitHub ping of [`pings.md`](pings.md), as before (it also needs `PING=on`) |
| `telegram` | One Telegram message per item, no GitHub ping |
| `both` | The ping and the Telegram message |
| `off` | Neither: the items stay in `needs-you`, `canccu-status` and the monitor |

The message goes at the change of state itself: each line the feed writes
([`leader.md`](leader.md#the-feed)) is looked at right after it is written. No model run builds it.
What goes to Telegram:

- every `interrupt` line whose owner is the product owner (`po`), whatever its kind;
- an `ask` line of the product owner, and an `info` line (a step done, a hold, the polish issue a
  deep review filed), when its kind is in `NOTIFY_KINDS`. The default is
  `accept plan question needs-you checkpoint step-done`. `needs-you` covers a failed run
  (`run-ended`) and a PR that needs you (`pr-needs-you`); `hold` covers `hold-usage` and
  `hold-pace`. `idle`, `hold`, `polish` and `handover` are off unless listed.

An `idle` line is never sent while the same unit has an open item: an earlier ask of the feed that
has not settled. A line of owner `leader` is not sent: the leader reads it from the feed.

The text of a unit's ask is [the ask form](pings.md#the-ask-form), with `NOTIFY_CONTENT` applied;
any other line is its own text, then `Recommended: answer needed`, `No answer: this waits.` and
the link (an `info` line: `For your information:`, its text and the link). It is sent as plain
text: no markup and no link preview. When the item settles, its message is edited to start with
`Closed:`.

Each item is sent once. A send that timed out may have landed: it is recorded and never sent again
(as the ping). A send Telegram refused, or one that could not go (no token, no chat id), is logged
once and tried again on each pass until it works; an item that settles before that is never sent.
A send never holds the pass up for more than 10 seconds.

## When it is sent

An `interrupt` goes at once, always: quiet hours, the cap and batching never hold it. Everything
else waits in the queue (`notify/queue`) for these rules, checked on each pass:

| Key | Default | What it does |
|---|---|---|
| `NOTIFY_KINDS` | `accept plan question needs-you checkpoint step-done` | The kinds of `ask` and `info` line sent ([above](#notifications)) |
| `NOTIFY_BATCH_MIN` | `10` | Items that arrive within this many minutes of the first queued one go together. `0`: each at once |
| `QUIET_HOURS` | empty | `<from>-<to>` in hours, for example `22-07`: nothing but an `interrupt` is sent in them; what waited goes out as one batch when they end |
| `QUIET_TZ` | empty | The clock of `QUIET_HOURS` and `NOTIFY_DIGEST_HOUR`, for example `Europe/Rome`; empty: the host's |
| `NOTIFY_MAX_PER_DAY` | `12` | Messages that ring a day (a batch counts once, an interrupt never). Over it, items wait for the digest, and one line a day says so |
| `NOTIFY_DIGEST_HOUR` | empty | The hour of the daily digest; empty: none |
| `NOTIFY_REMIND_H` | `0` | An item open longer than this many hours is listed again in the next digest, never as a message of its own; `0`: never |

One queued item goes as its own message. Several go as one batch: each still gets its own topic
(or reply chain) with its own message, sent without a sound, and then one message that rings
lists them, one numbered line per item with its link, ending in the reply that settles them all:

```
For the product owner: 3 items wait for you
1. #5 accept: plan tier https://github.com/example-org/web/pull/50
2. #6 accept: plan tier https://github.com/example-org/web/pull/60
3. #7 question: which port? https://github.com/example-org/web/issues/7
Reply: accept 50 60
```

That message is a topic of its own (its units and PRs joined by commas), so a reply to it reaches
the inbox; it closes once all its items settled. With no accept among the items, the last line is
`Reply in an item's topic to answer it.` An item that settles while it waits is never sent.

The digest goes once a day, at the first pass from `NOTIFY_DIGEST_HOUR` on (not in quiet hours: an hour inside them waits for their end, and the doctor says so),
in a topic of its own (`Digest <day>`; in a private chat, a message of its own): the PRs merged in
the last 24 hours and who accepted them, the runs running, the spend of the last 24 hours, and
what waits for you. The items the cap held are in it, and the digest counts as sent for them. With
the digest off, they go the next day, when the cap starts again.

## Topics and replies

In a group with topics on (its id starts with `-100`, the bot an admin that may manage topics),
each item opens a forum topic named `#<unit> <kind>`, and its message goes there. In a private
chat, or a group without topics, the message is the root of a reply chain instead: a reply to it,
or to a reply in the chain, belongs to that item.

The listener reads the bot's new messages as they come: `canccu-notify --project <name> listen`,
a long poll (`getUpdates` with `timeout=50`) that `canccu-up` starts in the window `listen` of the
project's session, and starts again when it is down. It stops once its parent (the window's
shell) is gone, so it never outlives its window. It holds the lock `notify/.listen.lock` and
touches `notify/listen.beat` on each read. While it lives, the pass does not read; without one,
the pass reads once. When the beat file exists and no listener holds the lock,
`canccu-dispatcher doctor` and `canccu-status` say the listener is down. A message is kept only when it is in `TELEGRAM_CHAT_ID`, from `TELEGRAM_USER_ID`, and in an open
topic. Each kept one is a line of `$CANCCU_HOME/inbox`:

```
<time>	<topic>	<unit>	<pr>	<text>
```

(tabs and newlines in the text folded to spaces, cut at 2000 characters). Every other message is
dropped and only counted in the log. The inbox is never trimmed. A reply is text for the leader,
never a command: nothing the dispatcher does reads it.

The leader watches the inbox with `canccu-dispatcher watch --file <inbox>` and answers with
`canccu-notify`:

| Command | What it does |
|---|---|
| `canccu-notify reply <topic> <text>` | A message in the topic (`t<thread>` for a forum topic, `m<message>` for a reply chain) |
| `canccu-notify note <topic> <text>` | `Leader's note: <text>`, as a reply to the dispatcher's message |
| `canccu-notify close <topic>` | Posts `Closed.` and closes the topic: later replies there are dropped |
| `canccu-notify topics` | The open topics: topic, unit, PR, feed line |
| `canccu-notify photos <unit> <png…>` | Images into the unit's topic, ten to an album at most, captioned with the PR's link |
| `canccu-notify listen` | The listener: reads the replies as they come, until stopped or its parent is gone |
| `canccu-notify ids` | The chats and senders the bot saw lately: where `TELEGRAM_CHAT_ID` and `TELEGRAM_USER_ID` come from |
| `canccu-notify test` | One test message |

Each takes `--project <name>` first and writes an actions-log line; a run (`CANCCU_ACTOR=run`) is
refused. With no leader (`LEADER=off`), a topic closes by itself when its item settles.

## Images

When a review passes a PR's head, the SVG files the PR changes are read from GitHub at that head,
rendered with `rsvg-convert` (when it is installed; else one log line) and sent into the unit's
topic, once per head. Images linked from a PR body are never fetched: that is worker text, and
fetching it would send the host to any URL. Other captures go through `canccu-notify photos`.

## Setting it up

1. In Telegram, ask @BotFather for `/newbot`. Put the token it gives in
   `~/.config/canccu/telegram-token` (one line, `chmod 600`; `TELEGRAM_TOKEN_FILE` moves it). It is
   refused inside a repo, or with another mode.
2. Write to the bot, or add it to a group with topics on as an admin that manages topics, and
   write there.
3. `canccu-notify --project <name> ids` lists the chats and senders the bot saw. Set them, and
   `NOTIFY`:
   `canccu-dispatcher config set --project <name> TELEGRAM_CHAT_ID=<chat>`, the same for
   `TELEGRAM_USER_ID=<your id>` and `NOTIFY=telegram` (all three are locked: the leader and a run
   cannot change them).
4. `canccu-init --check <name>` checks the token file, the chat id and the bot (`getMe`), and sends
   one test message. `canccu-dispatcher doctor` names a missing token, an open one or a missing chat id.

The token reaches only `curl`, on its standard input (`--config -`): it is in no argument, log,
record or process title, and the leader kit denies the leader any read of its file.

## The records

In `$CANCCU_HOME/notify/`: `topics` (key, feed line, unit, PR, open or closed, root message),
`msgs` (each message's topic), `sent` (feed line, message, topic), `text/<feed line>` (the text
sent, for the `Closed:` edit), `retry`, `offset` (the next update to read), `images` (PR, head), `queue` (the items waiting:
feed line, time queued, flag), `pushed` (a line per message that rang: day, item or batch), `capped`
(the day the cap line went), `digest` (the day of the last digest), `listen.beat` and
`.listen.lock` (the listener).
