# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Queue view (#293): every open issue of a project, one line each, in the order the
dispatcher takes them. Sections, top to bottom: Running, Needs you, Queue, Steps (the current,
next and later ones), Not scheduled. An issue shows once, in the first section that lists it;
an empty section is left out. Unlike the Roadmap nothing is summarised or hidden.

The marks and words are the Roadmap's (roadmap.py: STATE, ISSUE, PARKED, run_status, waiting):
one status vocabulary on every view. Lines wrap at spaces, never cut; up to the phone width the
line is two: mark, number and title, then the rest on a second line."""
import re

from rich.text import Text

from .data import lst, num, txt
from .parts import PHONE_UPTO, wrap
from .roadmap import ISSUE, MARK_STYLE, NEXT, PARKED, WAIT, YOU, ready_wait, run_status, waiting

PLACES = {"current": "NOW", "next": "NEXT", "later": "LATER"}


def where_of(item, names):
    """The package's name (from the plan by key, else the key without its pkg-<step>- prefix),
    else the fast lane."""
    pkg = txt(item, "package")
    if pkg:
        return names.get(pkg) or re.sub(r"^pkg-\d+-", "", pkg)
    return "fast lane" if txt(item, "lane") == "fast" else ""


def issue_line(row, width):
    n, title, where, (mark, word), wait = row
    head = Text("  ").append(mark, style=MARK_STYLE.get(mark, "")).append(" #%d" % n, style="bold")
    if title:
        head.append("  " + title)
    tail = Text()
    for part, style in ((where, ""), (word, "bold red" if mark == YOU else "dim" if mark == WAIT else ""), (wait, "")):
        if part:
            tail.append("  " if tail.plain else "").append(part, style=style)
    if width <= PHONE_UPTO:
        return wrap(head, width, 4) + (wrap(Text("    ").append_text(tail), width, 4) if tail.plain else [])
    return wrap(head.append("  ").append_text(tail) if tail.plain else head, width, 4)


def sections(snap):
    """[(heading, rows)] in take order; a row is (issue, title, where, (mark, word), waiting on)."""
    seen, out = set(), []
    running = {num(i, "issue"): i for i in lst(snap, "running") if num(i, "issue") is not None}

    names = {txt(p, "key"): txt(p, "name") for st in lst(snap, "steps") for p in lst(st.get("plan"), "packages")
             if txt(p, "key") and txt(p, "name")}

    def add(name, rows):
        kept = []
        for r in rows:
            if r[0] not in seen:
                seen.add(r[0])
                kept.append(r)
        if kept:
            out.append((name, kept))

    def row(it, mw, wait=""):
        return (num(it, "issue"), txt(it, "title"), where_of(it, names), mw, wait)

    add("Running", [row(i, run_status(i)) for i in lst(snap, "running") if num(i, "issue") is not None])
    parked = []
    for i in lst(snap, "needs_you"):
        if num(i, "issue") is not None:
            word, wait = PARKED.get(txt(i, "kind"), ("needs you", "your decision"))
            parked.append(row(i, (YOU, word), wait))
    add("Needs you", parked)
    add("Queue", [row(i, (WAIT, "blocked"), waiting(txt(i, "waits_on"))) if i.get("blocked")
                  else row(i, (NEXT, "ready"), ready_wait(snap))
                  for i in lst(snap, "queue") if num(i, "issue") is not None])
    for over in lst(snap, "step_overview"):
        place = txt(over, "place")
        if place not in PLACES:
            continue
        rows = []
        for i in sorted(lst(over, "issues"), key=lambda x: num(x, "issue") or 0):
            n, s = num(i, "issue"), txt(i, "status") or "blocked"
            if n is None:
                continue
            mw = run_status(running[n]) if s == "running" and n in running else ISSUE.get(s, (WAIT, s))
            wait = ready_wait(snap) if mw == (NEXT, "ready") else "your accept" if mw[1] == "accept" \
                else waiting(txt(i, "waits_on"))
            rows.append(row(i, mw, wait))
        ms = num(over, "milestone")
        add("%s · %s" % (txt(over, "title") or "step %s" % (int(ms) if ms is not None else "?"), PLACES[place]), rows)
    add("Not scheduled", [row(i, (WAIT, "not scheduled"), "your ready label") for i in lst(snap, "unscheduled")
                          if num(i, "issue") is not None])
    return out


def queue_lines(name, snap, width):
    """One project's Queue view; every line already fits the width."""
    if not isinstance(snap, dict):
        return [Text("QUEUE  %s: no snapshot" % name, style="dim")]
    title = Text("QUEUE  ", style="bold").append(name, style="bold").append(" · " + txt(snap, "repo", "?"), style="dim")
    out = wrap(title, width, 2)
    secs = sections(snap)
    if not secs:
        return out + [Text("  no open issues", style="dim")]
    for head, rows in secs:
        out += wrap(Text(head, style="bold"), width, 4)
        for r in rows:
            out += issue_line(r, width)
    return out


def queue_view(projects, width):
    """Every project's queue, stacked."""
    out = []
    for k, (n, s) in enumerate(projects):
        out += ([Text("")] if k else []) + queue_lines(n, s, width)
    return out
