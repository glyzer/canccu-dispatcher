<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The monitor

Part of the reference; the index is [`README.md`](README.md).

## canccu-monitor

`canccu-monitor [--project <name>] [--view <name>] [--rotate [secs]]` draws the project's
`status.json` every 2 s and at once after a key, with the other projects' snapshots in the same
view. It never calls GitHub, git or tmux and never changes anything. It is `lib/canccu-monitor.py`
with its parts in `lib/canccu_monitor/` (`data` reads the snapshots, `views` the state, the
strip, the view bar and the loop, `summary`, `projects`, `roadmap`, `activity` and `queue` the five views,
`inbox`, `now` and `recent` the parts they share, `keys` the keyboard, `screen` the terminal,
`selftest`), run with the venv's Python and `rich` (`CANCCU_VENV`, default
`~/.local/share/canccu/venv`).

## The views

Five views, one screen each. Line 1 of every view is a one-line strip (each project's pass age
and `✓`/`⚠`, the slots, today's spend, the 5-hour and weekly usage, or `usage unknown`); the
Summary has the full 2-line header instead. The last line is the view bar:

```
 [1 Summary ✖2]    2 Projects     3 Roadmap     4 Activity    ? help   q quit     ↑↓ scroll   rotate off
```

The current view is in brackets (and reverse), the needs-you count is the red badge on the
Summary tab, the view's key hints and `rotate off` or `rotate 30s` sit on the right when they
fit. Up to 80 columns the names are short (`Sum`, `Proj`, `Road`, `Act`, `Que`).

- **1 Summary** (the default): the most important things, one line each. NEEDS YOU (one line per
  item with a `how:` line under it), NOW (a line per run with its stage, minutes and turns against
  their caps), STEPS (a line per current step of every project; a project without steps says
  `no steps (simple workflow)` with its open PRs and queue), RECENT (every project's events,
  newest first) and the glyph legend. It never scrolls: when the terminal is short it drops the
  `how:` lines, then RECENT, the legend, the blank lines, then the steps down to the main track's.
  The needs-you lines never drop. It is the only view that cuts text with `…`, and only titles and
  reasons.
- **2 Projects**: a block per project. The head line
  `━━ name · repo · pass · runs n of CAP · today $ · queue n ━━`; the runs table (Run · Kind ·
  Stage · Age · Turns · Min · Cost · Title; Cost is `–` while a run is live, a run started by
  hand has Kind `other`); the needs-you lines; the current step's line and its packages table
  (Package · Issues · Risk · Wave · Status · Waiting on; a package carried from an earlier wave
  reads `6→8`); the queue table; the parallel tracks on one line. Only the Title column is cut.
  `p` cycles the focus: all projects, then one at full detail with the others on their head line.
- **3 Roadmap**: every project's roadmap at full detail, stacked, with the legend; nothing is
  cut. A project without steps says `no steps (simple workflow)`.
- **4 Activity**: a today line (merged, runs ended, spend per project, needs you); RUNS ENDED
  TODAY from the snapshot's `finished[]` (a dim line says so while a dispatcher does not write
  it); EVENTS of every project, newest first, repeats folded `×N`, `⚠` on failures, merges green,
  needs-you red, the steps' `Follow-up:` and `Roadmap note:` items among them, a URL as a terminal
  link on the number.
- **5 Queue**: every open issue of a project, one line each, in the order the dispatcher takes
  them, under bold headings: Running, Needs you (items with an issue), Queue (the snapshot's
  `queue[]`, blocked ones in place), one heading `<step> · NOW|NEXT|LATER` per open step with its
  issues, and Not scheduled (`unscheduled[]`, the issues waiting for your `ready` label). An issue
  shows once, under the first heading that lists it; an empty heading is left out, and with no
  open issue one dim line says so. A line: mark, `#n`, title, the package (else `fast lane`), the
  status word and what it waits on, with the Roadmap's marks and words; up to 80 columns the
  mark, number and title are one line and the rest a second. Nothing is hidden, unlike the Roadmap.

Projects, Roadmap, Activity and Queue scroll. Up to 80 columns every view has its phone form: no boxes
and no tables, a line per row.

### Keys

| Key | What it does |
|---|---|
| `1` `2` `3` `4` `5` | that view |
| `Tab` `→` / `Shift-Tab` `←` | the next / the previous view (wrapping around) |
| `↑` `↓` `j` `k` | scroll a line |
| `PgUp` `PgDn` / `Home` `End` | scroll a page / to the top, to the end |
| `p` | Projects: cycle the focus |
| `a` | rotate the views on or off |
| `r` | redraw the whole screen now |
| `?` | the help overlay (any key closes it) |
| `q` `Ctrl-C` | quit |

The view, the scroll and the focus stay across redraws, new snapshots and resizes. Keys are read
only when stdin is a terminal, in cbreak mode (no echo, Ctrl-C still a signal); the terminal's
settings are restored on every way out (q, Ctrl-C, an error, SIGTERM) before the alternate screen
is left. They work with or without tmux; from outside the pane,
`tmux send-keys -t <session>:main.1 2` switches the monitor to Projects.

`--view <name>` (`summary`, `projects`, `roadmap`, `activity`, `queue`, or `1`–`5`) picks the start view,
also with `--once`. `--rotate [secs]` cycles the views (default 30 s, the Summary twice as long),
skipping a view with nothing to show; any key but `a` stops it.

## The parts

It is made for the right half of a PC screen (120×55, scaling to about 140×65) and still works on
a phone over ssh (80×30). The views are built from these parts (the Inbox First layout of
`draw.py`, which the self-test still renders, stacks them all in one screen):

- **Header**: each project with its last pass's age and `✓` (or `⚠`: a failed or stale pass), the
  slots in use against `TOTAL_CAP`, the clock, today's spend (`≥` while a run had no reported
  cost), the freeze date, and the 5-hour and weekly usage with their reset times. Banners below:
  "dispatcher not running?", a failed pass, a newer schema, sections from an earlier pass.
- **NEEDS YOU**, a red box that is never dropped: one card per item of every project whose owner is the product owner
  ([`leader.md`](leader.md#the-owner-of-a-waiting-item); an item with no `owner` counts as theirs), oldest
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

`canccu-monitor --self-test` renders every fixture in `tests/fixtures/monitor/` in every view at
160×60, 120×40, 100×40, 80×30 and 60×20, checks the words, links, order, colours and the drop
order, and drives the keys on a fake terminal; the local check runs it.
`canccu-monitor --file <snapshot> --once [--view <name>] [--width N] [--height N]` prints one
frame.

### Moving to the command-center layout

`canccu-up` never changes a session that exists. To bring an older session to the layout it
creates (`<p>` is the project, `<session>` its session):

1. In the dispatcher's pane, stop `canccu-dispatch` with Ctrl-C between passes (a run it started
   keeps running in its own window).
2. `tmux new-window -d -t <session>: -n dispatch -e CANCCU_PROJECT=<p> 'canccu-dispatch --project <p>; exec bash'`
3. `tmux new-window -d -t <session>: -n shell -e CANCCU_PROJECT=<p>`
4. In the pane beside the leader: `canccu-monitor --project <p>`.

Ending the session instead would end the runs too: their windows live in it.
