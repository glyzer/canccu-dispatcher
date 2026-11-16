<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The leader's toolkit

Part of the reference; the index is [`README.md`](README.md). Three commands for the leader's
session ([`leader.md`](leader.md)): one waits for what the leader acts on, one names what is stuck, one
shows the pace. They only read: none writes the log, the feed or GitHub.

## watch

`canccu-dispatcher watch [--project <name>] [--settle <sec>] [--match <regex>] [--file <path>]...`
waits for the next event and exits 0 once it prints it:

- the new lines of the project's `dispatch.log` that match `--match` (an extended regex). The
  default: `awaiting accept|needs-you:|checkpoint #[0-9]+ waits for checkpoint-ok|is done: |usage at stopping|waits \(no PR\)|stopped, needs-you|Z pace: `
  (a log line starts with its ISO time, so `Z pace: ` is a pacing line);
- every new line of each `--file` (a leader's own notes, a test's output);
- the [`stall`](#stall) lines, checked at the start and every 10 minutes.

A `--file` line exits at once. Any other hit waits `--settle` seconds (default 180), so a burst of
lines comes as one, collects again and prints them all. Only whole lines count: a line without its
newline yet is read once it has one. It polls every 20 seconds. Exit 3, saying
`heartbeat stale: <n> min; the dispatcher may be down`, when the heartbeat is 10 minutes old, as
[`wait`](commands.md) does.

Where it stopped reading each file is kept in `<project home>/watch.offsets` (`<path>`, a tab,
`<bytes>`), so the next run starts there and misses nothing between two runs. The first run
starts at each file's end: no old line. A file shorter than its offset (rotated or truncated) is
read from its start.

## stall

`canccu-dispatcher stall [--project <name>]` prints one line per stuck item and exits 0:

| Line | When |
|---|---|
| `stall: PR #<n> conflicts with main (no CI runs until it merges main)` | An open PR by `USER_LOGIN` that GitHub calls conflicting |
| `stall: CI run <id> (<workflow>) in progress for <min> min` | A CI run in progress for over 60 minutes |
| `stall: dispatch.log silent for <h> h while step <title> is running` | No log line for over 3 hours while a step's phase is `running` |

Each item prints at most once per 3 hours: `<project home>/stall.seen` holds its key (`pr-<n>`,
`ci-<id>`, `log-<step>`) and when it last printed. The thresholds are fixed. A `gh` error skips
that kind; the others still print.

## canccu-status --pace

`canccu-status [--project <name>] --pace` prints three blocks:

```
weekly <w>% · <g>% of the week gone · <d> points ahead|behind · resets <time>
PACE=<mode> · margin <m> · ahead since <time>: <effect>   (or: on pace)
spend of this project's runs, last 7 days (UTC), newest first:
  <YYYY-MM-DD> $<usd> (<n> runs)
```

The first line compares the newest usage reading with the share of the week gone; without a fresh
reading it is `weekly usage unknown (no fresh reading)`. The second says what `PACE` does while the
project is ahead ([`usage.md`](usage.md#pacing)). The spend comes from the spend log
([`state.md`](state.md#the-spend-log)): one line per day, the exact costs summed, every run
counted (a run with no reported cost adds nothing to the sum).
