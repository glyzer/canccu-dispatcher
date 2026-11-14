# SPDX-License-Identifier: AGPL-3.0-or-later
"""The screen ("Inbox First"), top to bottom: the header, banners, the NEEDS YOU box, NOW,
ROADMAP (a table per project, stacked), RECENT; and render(), which lays them out for a terminal.

Every section is built as lines that already fit the width, so render() can count them. When the
terminal is too short it drops, in this order, until the frame fits: the [tN] last lines → the
roadmap's later steps and blocked detail → the other projects' events → RECENT → NOW's pipeline
lines (to the current stage on line 1) → the roadmap's idle parallel-track steps → its done
packages, folded into one row → its next step and fast lane → the roadmap to its step headers →
the blank lines; then
the cards' title and how: lines. The NEEDS YOU box never drops; what still does not fit is cut at
the bottom. Up to PHONE_UPTO columns the phone form is used (one-line header, 2-line cards, one
line per unit, the roadmap tables with a heading line per step, a short recent list)."""
from rich.console import Group
from rich.text import Text

from .data import txt
from .inbox import banners, box, header, phone_cards
from .now import now_section, phone_now
from .parts import PHONE_UPTO
from .recent import recent
from .roadmap import legend, roadmap

LEVELS = 12  # 0: everything … 11: the box at its shortest
FOLD_AT = 6  # from this level the roadmap folds (roadmap's fold: 1 to 3); HEADS_AT: its step headers only
HEADS_AT = FOLD_AT + 3


def safe(fn, *args, **kw):
    """The section's lines; one red line instead when its data is odd (never takes the screen down)."""
    try:
        return fn(*args, **kw)
    except Exception:
        return [Text("(unreadable)", style="red")]


def roadmaps(projects, width, detail, headers_only, fold=0, sec=safe):
    """One roadmap per project, one under the other (never side by side), then the legend of
    their status marks."""
    out = []
    for k, (n, s) in enumerate(projects):
        out += ([Text("")] if k and not headers_only else []) + sec(roadmap, n, s, width, detail, headers_only,
                                                                       fold=fold)
    return out + ([] if headers_only else legend(width))


def frame_lines(projects, snap, now, width, level, marked, sec=safe):
    """The frame's lines at that level of the drop order; sec builds a section (once per frame, render)."""
    phone = width <= PHONE_UPTO
    blank = [] if level >= HEADS_AT + 1 else [Text("")]
    fold = min(3, max(0, level - FOLD_AT + 1))
    top = sec(header, projects, now, width, phone) + sec(banners, snap, now, width)
    if phone:
        body = list(sec(phone_cards, projects, now, width, marked))  # a copy: the cached list stays
        body += blank + sec(phone_now, projects, now, width, marked)
        if level < HEADS_AT:
            body += blank + [x for n, s in projects for x in sec(roadmap, n, s, width, level < 2, phone=True, fold=fold)]
            body += legend(width) if level < 2 else []
        elif level < HEADS_AT + 1:
            body += blank + [x for n, s in projects for x in sec(roadmap, n, s, width, False, True, phone=True)]
        if level < 4:
            body += blank + sec(recent, projects, width, level >= 3, True)
        return top + body
    body = list(sec(box, projects, now, width, marked, level >= HEADS_AT + 2))  # a copy: the cached list stays
    body += blank + sec(now_section, projects, now, width, marked, level < 1, level >= 5)
    body += blank + sec(roadmaps, projects, width, level < 2, level >= HEADS_AT, fold, sec)
    if level < 4:
        body += blank + sec(recent, projects, width, level >= 3)
    return top + body


def render(snap, err, now, width, other=(), name=None, height=None):
    """The whole screen as one renderable, for a terminal of that width and height (None: no limit).
    other: [(name, snapshot or None)] of the other projects; name: the monitor's project (else the
    snapshot's)."""
    if err:
        return Group(Text("canccu-monitor: " + err, style="bold red"))
    other = list(other)
    projects = [(name or txt(snap, "project", "?"), snap)] + other
    marked = len(projects) > 1
    cache = {}

    def sec(fn, *args, **kw):
        """A section's lines, built once per frame: most do not change from one level to the next."""
        key = (fn, tuple(a if isinstance(a, (int, float, str, bool, type(None))) else id(a) for a in args),
               tuple(sorted(kw.items())))
        if key not in cache:
            cache[key] = safe(fn, *args, **kw)
        return cache[key]
    lines = []
    for level in range(LEVELS):
        lines = frame_lines(projects, snap, now, width, level, marked, sec)
        if height is None or len(lines) <= height:
            break
    if height is not None:
        lines = lines[:height]
    for ln in lines:
        ln.no_wrap, ln.overflow = True, "crop"
    return Group(*lines)
