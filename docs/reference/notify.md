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

- every `ask` and `interrupt` line whose owner is the product owner (`po`): an accept, a plan, a
  question, a needs-you, a failed run, a PR that needs you, an idle unit, a handover;
- and, as class `info`: a step done (`step-done`), a hold (`hold`, `hold-usage`, `hold-pace`) and
  the polish issue a deep review filed (`polish`).

A line of owner `leader` is not sent: the leader reads it from the feed.

The text of a unit's ask is [the ask form](pings.md#the-ask-form), with `NOTIFY_CONTENT` applied;
any other line is its own text, then `Recommended: answer needed`, `No answer: this waits.` and
the link (an `info` line: `For your information:`, its text and the link). It is sent as plain
text: no markup and no link preview. When the item settles, its message is edited to start with
`Closed:`.

Each item is sent once. A send that timed out may have landed: it is recorded and never sent again
(as the ping). A send Telegram refused, or one that could not go (no token, no chat id), is logged
once and tried again on each pass until it works; an item that settles before that is never sent.
A send never holds the pass up for more than 10 seconds.

## Topics and replies

In a group with topics on (its id starts with `-100`, the bot an admin that may manage topics),
each item opens a forum topic named `#<unit> <kind>`, and its message goes there. In a private
chat, or a group without topics, the message is the root of a reply chain instead: a reply to it,
or to a reply in the chain, belongs to that item.

Once per pass the dispatcher reads the bot's new messages (no listener runs between passes). A
message is kept only when it is in `TELEGRAM_CHAT_ID`, from `TELEGRAM_USER_ID`, and in an open
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
sent, for the `Closed:` edit), `retry`, `offset` (the next update to read) and `images` (PR, head).
