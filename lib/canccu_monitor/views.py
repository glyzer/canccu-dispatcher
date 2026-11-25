# SPDX-License-Identifier: AGPL-3.0-or-later
"""The views (#37): Summary (the default), Projects, Roadmap, Activity and Queue; the state the keys
change (view, scroll, focus, rotation, help); the strip at the top and the view bar at the
bottom of every view; the loop that draws and reads keys.

Every view is built as lines that already fit the width. The Summary fits the height by its own
drop order (summary.py) and never scrolls; the others scroll, their scroll clamped at each frame,
so a resize or a shorter snapshot never leaves the view past its end. The state lives across
frames: a new snapshot or a resize keeps the view, scroll and focus."""
import time

from rich.console import Group
from rich.text import Text

from .data import lst
from .inbox import banners, items, project_mark, slots, spend, usage_of
from .parts import LEGEND, PHONE_UPTO, YOU, glyph, wrap
from .roadmap import MARK_STYLE, VOCAB, fast_rows, has_steps, later_line, legend, roadmap, step_sections, title_line

NAMES = ["Summary", "Projects", "Roadmap", "Activity", "Queue"]
SHORT = ["Sum", "Proj", "Road", "Act", "Que"]
HINTS = ["", "p focus  ↑↓ scroll", "↑↓ scroll", "↑↓ scroll", "↑↓ scroll"]
ROTATE = 30  # --rotate's default seconds; the Summary stays twice as long
HELP = [("1–5", "a view"), ("Tab →  Shift-Tab ←", "the next, the previous view"),
        ("↑ ↓  j k", "scroll a line"), ("PgUp PgDn", "scroll a page"), ("Home End", "the top, the end"),
        ("p", "Projects: all projects → one at full detail → …"), ("a", "rotate the views on or off"),
        ("r", "redraw the whole screen now"), ("?", "this help"), ("q  Ctrl-C", "quit")]


class State:
    """What the keys change; kept across frames, snapshots and resizes."""

    def __init__(self, view=0, rotate=None):
        self.view, self.scroll, self.focus, self.help, self.full = view, [0] * len(NAMES), None, False, False
        self.rotate, self.rotate_secs, self.switch_at = rotate, rotate or ROTATE, None
        self.projects, self.page, self.shows = 1, 10, [True] * len(NAMES)

    def dwell(self):
        return self.rotate * (2 if self.view == 0 else 1)

    def tick(self, now):
        """Rotation: the next view with something to show once the current one's time is up."""
        if self.rotate is None:
            return
        if self.switch_at is None:
            self.switch_at = now + self.dwell()
        elif now >= self.switch_at:
            for k in range(1, len(NAMES) + 1):
                if self.shows[(self.view + k) % len(NAMES)]:
                    self.view = (self.view + k) % len(NAMES)
                    break
            self.switch_at = now + self.dwell()

    def key(self, k, projects=None, page=None):
        """Applies a key; "quit" for q. Any key but a stops the rotation; with help shown, any key
        only closes it."""
        projects = self.projects if projects is None else projects
        page = self.page if page is None else page
        if k == "a":
            self.rotate = None if self.rotate is not None else self.rotate_secs
            self.switch_at = None
            self.help = False
            return None
        self.rotate = None
        if self.help:
            self.help = False
            return None
        n, v = len(NAMES), self.view
        if k == "q":
            return "quit"
        if k in ("1", "2", "3", "4", "5"):
            self.view = int(k) - 1
        elif k in ("next", "prev"):
            self.view = (v + (1 if k == "next" else -1)) % n
        elif k == "?":
            self.help = True
        elif k == "r":
            self.full = True
        elif k == "p" and v == 1:
            self.focus = 0 if self.focus is None else self.focus + 1 if self.focus + 1 < projects else None
        elif k in ("up", "down", "pgup", "pgdn", "home", "end") and v != 0:
            step = {"up": -1, "down": 1, "pgup": -max(1, page - 1), "pgdn": max(1, page - 1)}
            self.scroll[v] = 0 if k == "home" else 10 ** 9 if k == "end" else max(0, self.scroll[v] + step[k])
        return None


# ------------------------------------------------------------------ the strip and the bar

def strip(projects, now, width):
    """One line: every project's pass age and ✓/⚠/PAUSED, the slots, today's spend, the usage;
    the less important parts go first when it does not fit."""
    own = projects[0][1]
    total, low, _ = spend(projects)
    usage = usage_of(projects)
    u5, uw = usage.get("five_hour"), usage.get("seven_day")
    use = ("5h %d%%" % u5 if isinstance(u5, (int, float)) else "") + \
        (" · " if isinstance(u5, (int, float)) and isinstance(uw, (int, float)) else "") + \
        ("week %d%%" % uw if isinstance(uw, (int, float)) else "")
    money = ("≥ $%.2f" if low else "$%.2f") % total
    marks = [project_mark(n, s, now, False, True) for n, s in projects]
    for parts in ([marks, "slots " + slots(own), "today " + money, use or "usage unknown"],
                  [marks, slots(own), money, use or "usage unknown"], [marks, slots(own), money],
                  [marks, slots(own)], [[Text(n, style="bold") for n, _ in projects]]):
        t = Text()
        for k, m in enumerate(parts[0]):
            t.append(" · " if k else "", style="dim").append_text(m)
        for p in parts[1:]:
            t.append(" │ " if width > PHONE_UPTO else " · ", style="dim").append(p)
        if len(t.plain) <= width:
            return t
    t.truncate(width)
    return t


def view_bar(st, needs, width):
    """ 1 Summary ✖2   2 Projects   3 Roadmap   4 Activity   5 Queue   ? help   q quit, the current view in
    [ ] (reverse); the view's hints and rotate off|Ns on the right when they fit."""
    names = SHORT if width <= PHONE_UPTO else NAMES
    # five names: the gap shrinks to keep the bar whole (81 and 82 columns fit the long names only with one space)
    gap = " " if width < 70 or 80 < width < 83 else "  " if width <= 110 else "   "
    left = Text()
    for k, name in enumerate(names):
        cur = k == st.view
        left.append(gap if k else " ")
        left.append(("[%d %s" if cur else " %d %s") % (k + 1, name), style="reverse bold" if cur else "")
        if k == 0 and needs:
            left.append(" ")
            glyph(YOU, left).append("%d" % needs, style="bold red")
        left.append("]" if cur else " ", style="reverse bold" if cur else "")
    left.append(gap + ("?" if width < 70 else "? help") + gap + "q quit", style="dim")
    rot = "rotate off" if st.rotate is None else "rotate %ds" % st.rotate
    for right in ("%s   %s" % (HINTS[st.view], rot) if HINTS[st.view] else rot, rot):
        if len(left.plain) + 2 + len(right) <= width:
            left.append(" " * (width - len(left.plain) - len(right) - 1)).append(right + " ", style="dim")
            return left
    if len(left.plain) > width:
        left.truncate(width)
    return left


def help_lines(width):
    out = [Text("HELP · any key closes it", style="bold"), Text("")]
    for keys, what in HELP:
        out += wrap(Text("  " + keys.ljust(20), style="bold").append(what, style=""), width, 22)
    out += [Text(""), Text("GLYPHS", style="bold")]
    t = Text("  ")
    for g, word in LEGEND:
        glyph(g, t).append(" " + word + "   ", style="dim")
    out += wrap(t, width, 2)
    t = Text("  ")
    for m, word in VOCAB:
        t.append(m, style=MARK_STYLE[m]).append(" " + word + "   ", style="dim")
    return out + wrap(t, width, 2)


# ------------------------------------------------------------------ the Roadmap view

def phone_roadmap(name, snap, width):
    """A project's roadmap without tables: a heading line per step, a line per row."""
    if snap is None:
        return [Text("ROADMAP  %s: no snapshot" % name, style="dim")]
    out = title_line(name, snap, width)
    for s in step_sections(snap):
        out += wrap(Text(" · ").join(s["head"]), width, 2)
        for r in s["rows"]:
            t = Text("  ").append_text(r[3]).append(" ").append_text(r[0])
            for c in r[1:3]:
                if c.plain:
                    t.append(" ").append_text(c)
            if r[4].plain:
                t.append(" · ", style="dim").append_text(r[4])
            out += wrap(t, width, 4)
    later = later_line(snap) if has_steps(snap) else ""
    if later:
        out += wrap(Text("  Later ", style="bold").append(later), width, 4)
    rows = fast_rows(snap)
    if rows:
        out.append(Text("  fast lane", style="bold"))
    for r in rows:
        t = Text("  ").append_text(r[3]).append(" ").append_text(r[0]).append(" ").append_text(r[1])
        if r[2].plain != "–":
            t.append(" PR ").append_text(r[2])
        if r[4].plain:
            t.append(" · ", style="dim").append_text(r[4])
        out += wrap(t, width, 4)
    return out


def roadmap_view(projects, width):
    """Every project's roadmap at full detail, stacked, nothing cut; the phone form without tables."""
    out = []
    for k, (n, s) in enumerate(projects):
        out += ([Text("")] if k else []) + (roadmap(n, s, width) if width > PHONE_UPTO else phone_roadmap(n, s, width))
    return out + legend(width)


def shows(projects):
    """Which views have something to show (rotation skips the others)."""
    snaps = [s for _, s in projects if isinstance(s, dict)]
    road = any(has_steps(s) or lst(s, "milestones") for s in snaps)
    act = any(lst(s, "events") or lst(s, "finished") for s in snaps)
    return [True, bool(snaps), road, act, bool(snaps)]


# ------------------------------------------------------------------ a frame

def body_of(st, projects, now, width):
    from .activity import activity
    from .projects import projects_view
    from .queue import queue_view
    if st.view == 1:
        if st.focus is not None and st.focus >= len(projects):
            st.focus = None
        return projects_view(projects, now, width, st.focus)
    if st.view == 2:
        return roadmap_view(projects, width)
    if st.view == 4:
        return queue_view(projects, width)
    return activity(projects, now, width)


def safe_lines(fn, *args):
    try:
        return fn(*args)
    except Exception:  # odd data takes one line, never the screen
        return [Text("(unreadable)", style="red")]


def render_view(st, projects, now, width, height=None, err=None):
    """The frame of the state's view as one renderable: height lines exactly (None: no limit),
    the view bar on the last. err: why the own snapshot cannot be shown."""
    from .summary import summary
    projects = list(projects)
    st.projects, st.shows = len(projects), shows(projects)
    marked = len(projects) > 1
    bar = view_bar(st, len(items(projects)), width)
    if st.view == 0 and not st.help and not err:
        lines = safe_lines(summary, projects, now, width, None if height is None else height - 1, marked)
    else:
        top = [strip(projects, now, width)]
        top += safe_lines(banners, projects[0][1], now, width) if isinstance(projects[0][1], dict) else []
        if err:
            body = [Text("canccu-monitor: " + err, style="bold red")]
        elif st.help:
            body = help_lines(width)
        else:
            body = safe_lines(body_of, st, projects, now, width)
        room = None if height is None else max(0, height - 1 - len(top))
        st.page = room or len(body)
        if st.view != 0 and not st.help and room is not None:
            st.scroll[st.view] = max(0, min(st.scroll[st.view], len(body) - room))
            body = body[st.scroll[st.view]:]
        lines = top + body
    if height is not None:
        lines = lines[:max(0, height - 1)]
        lines += [Text("")] * (height - 1 - len(lines))
    lines.append(bar)
    for ln in lines:
        ln.no_wrap, ln.overflow = True, "crop"
        if len(ln.plain) > width:
            ln.truncate(width)
    return Group(*lines)


def run(display, keyboard, st, frame, clock=time.time, tick=2):
    """Draws frame(st) every tick seconds and at once after a key, until q (or Ctrl-C, an error,
    SIGTERM). The keyboard is entered inside the display: its tty attributes are restored
    before the alternate screen is left."""
    with display, keyboard:
        while True:
            if st.full:
                display.prev, st.full = [], False
            display.draw(frame(st))
            now = clock()
            st.tick(now)
            wait = tick if st.switch_at is None else max(0.0, min(tick, st.switch_at - now))
            for k in keyboard.wait(wait):
                if st.key(k) == "quit":
                    return
            st.tick(clock())


def view_index(name):
    """The view of --view <name> (a name or its number, any case); None when unknown."""
    name = name.strip().lower()
    for k, n in enumerate(NAMES):
        if name in (n.lower(), str(k + 1), SHORT[k].lower()):
            return k
    return None

