<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The monitor

Part of the reference; the index is [`README.md`](README.md).

## canccu-monitor

`canccu-monitor [--project <name>]` draws the project's `status.json` every 2 s, with the other
projects' snapshots in the same view. It never calls GitHub, git or tmux, never changes anything,
and reads no keys (Ctrl-C ends it). It is `lib/canccu-monitor.py` with its parts in
`lib/canccu_monitor/` (`data` reads the snapshots, `inbox` the header and the NEEDS YOU box,
`now`, `roadmap`, `recent`, `draw` lays them out, `screen` the terminal, `selftest`), run with
the venv's Python and `rich` (`CANCCU_VENV`, default `~/.local/share/canccu/venv`).

It is made for the right half of a PC screen (120×55, scaling to about 140×65) and still works on
a phone over ssh (80×30). Top to bottom:

- **Header**: each project with its last pass's age and `✓` (or `⚠`: a failed or stale pass), the
  slots in use against `TOTAL_CAP`, the clock, today's spend (`≥` while a run had no reported
  cost), the freeze date, and the 5-hour and weekly usage with their reset times. Banners below:
  "dispatcher not running?", a failed pass, a newer schema, sections from an earlier pass.
- **NEEDS YOU**, a red box that is never dropped: one card per item of every project whose owner is the product owner
  ([`lead.md`](lead.md#the-owner-of-a-waiting-item); an item with no `owner` counts as theirs), oldest
  first; with none, `nothing needs you`. Under the box, `LEADER: <n> items · oldest <age>` counts
  the leader's items, listed as `#<i> <kind> <age>` on a wide screen, only the count on a phone. Line 1: the verb (`ACCEPT`, `STUCK`, `QUESTION`, `PLAN OK?`, `CHECKPOINT`, `PLAN BAD`,
  `BUDGET`), the project, the issue and PR, the reason, since when, and the stage it parked at.
  Line 2: `how:` the action that clears it (for an accept: "label PR #n accepted, or canccu-ship
  <n>"). Line 3: the title. Line 4: the URLs, as text a phone can copy and as terminal links.
  Nothing of a reason, a number or a URL is cut: long lines wrap.
- **NOW**: per running unit, the project, issue, PR and title; then the whole pipeline in text
  (`work ✓ › CI ✓ › review ✓ changes › fix ✓ › fix-check ◉ 0/20 min · 0/30 turns › merge ○`)
  and the run's last log line. Then the runs the dispatcher did not start, the units parked on
  you, and `up next`.
- **ROADMAP**: a table per project. With steps: one row per package (name, issues, risk class,
  status with its PR), the issues outside a package grouped by status, the health pass and the
  checkpoint, then the next step and the later ones. Without steps, the fast lane: one row per
  managed or queued issue. One status vocabulary, one mark each: `●` running, `○` can go next, `–`
  blocked or later, `✖` needs you, `✓` done; **Waiting on** names the blocker in words. A blocked
  group's cell takes at most two lines: when its reasons do not fit, the blockers most issues wait
  on, then `+N more` (`behind #306×8, #109×4 · +11 more`). A table too tall for the pane first
  drops the later steps and the blocked groups, then the idle parallel-track steps, then folds the
  done packages into one row (`20 merged`), then drops the next step and the fast lane; only then
  is each step one line.
- **RECENT**: each project's latest events, newest last, with repeats folded into one row `×N`.

When the terminal is short, the parts drop in a fixed order (the last log lines first, NEEDS YOU
never). Colours reinforce the glyphs and never carry meaning alone: `NO_COLOR` gives the same
text. A snapshot older than 3 passes shows a red "dispatcher not running?"; a missing or partly
written snapshot shows one red line and is read again 2 s later; a section with odd data shows
"(unreadable)". It never crashes on a snapshot.

`canccu-monitor --self-test` renders every fixture in `tests/fixtures/monitor/` at several sizes
and checks the words, links, order, colours and the drop order; the local check runs it.
`canccu-monitor --file <snapshot> --once [--width N] [--height N]` prints one frame.

### Moving to the command-center layout

`canccu-up` never changes a session that exists. To bring an older session to the layout it
creates (`<p>` is the project, `<session>` its session):

1. In the dispatcher's pane, stop `canccu-dispatch` with Ctrl-C between passes (a run it started
   keeps running in its own window).
2. `tmux new-window -d -t <session>: -n dispatch -e CANCCU_PROJECT=<p> 'canccu-dispatch --project <p>; exec bash'`
3. `tmux new-window -d -t <session>: -n shell -e CANCCU_PROJECT=<p>`
4. In the pane beside the lead: `canccu-monitor --project <p>`.

Ending the session instead would end the runs too: their windows live in it.
