# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Activity view: a today line (merged, runs ended, spend per project, needs-you count); RUNS
ENDED TODAY (Ended · Project · Run · Kind · Min · Turns · Cost · Outcome) from the snapshot's
finished[] when a dispatcher writes it, else one dim line saying so; EVENTS: every project's
events merged by time, newest first, repeats folded ×N, ⚠ on failures, merges green, needs-you
red, the current steps' Follow-up: and Roadmap note: items among them, a URL as an OSC 8 link on
the line's number. Nothing is cut: lines wrap."""
import re
import time

from rich.text import Text

from .data import lst, num, txt
from .inbox import items, spend
from .parts import FAILURE, LINK_AT_END, STUCK, clock, fold_events, glyph, link, tag, wrap
from .projects import columns
from .recent import NOTES, colours

MERGED = re.compile(r"\bmerged\b", re.I)
NEEDS = re.compile(r"needs-you|needs you", re.I)
NUMBER = re.compile(r"(PR )?#\d+")


def day_start(now):
    t = time.localtime(now)
    return time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))


def finished(projects, since):
    """[(project, run)] of the runs that ended today, newest first; None when no snapshot has the
    field (a dispatcher that does not write it yet)."""
    have = [(n, s) for n, s in projects if isinstance(s, dict) and isinstance(s.get("finished"), list)]
    if not have:
        return None
    runs = [(n, r) for n, s in have for r in lst(s, "finished") if (ended(r) or 0) >= since]
    return sorted(runs, key=lambda x: -(ended(x[1]) or 0))


def ended(r):
    return num(r, "ended") if num(r, "ended") is not None else num(r, "at")


def events(projects, now, since=None):
    """[(at, first_at, count, text, issue, note kind, project, colours)], newest first."""
    rows = []
    for name, snap in projects:
        if not isinstance(snap, dict):
            continue
        cols = colours(snap)
        for e in fold_events(lst(snap, "events")):
            rows.append((e["at"] or 0, e["first_at"], e["count"], e["text"], e["issue"], None, name, cols))
        for s in lst(snap, "steps"):
            for n in lst(s, "notes"):
                if txt(n, "kind") in NOTES:
                    pr = " (PR #%d)" % num(n, "pr") if num(n, "pr") is not None else ""
                    rows.append((num(n, "at") or 0, None, 1, txt(n, "text") + pr, None, txt(n, "kind"), name, cols))
    rows.sort(key=lambda r: -r[0])
    return [r for r in rows if since is None or r[0] >= since]


def today_line(projects, now, width, runs):
    since = day_start(now)
    merged = sum(r[2] for r in events(projects, now, since) if r[5] is None and MERGED.search(r[3]))
    t = Text("today", style="bold")
    t.append(" · merged %d" % merged)
    if runs is not None:
        t.append(" · runs ended %d" % len(runs))
    total, low, per = spend(projects)
    t.append(" · " + ("≥ $%.2f" if low else "$%.2f") % total)
    if len(per) > 1:
        t.append(" (" + " · ".join("%s $%.2f" % (n, v) for n, v in per) + ")")
    n = len(items(projects))
    t.append(" · ", style="dim").append("needs you %d" % n, style="bold red" if n else "")
    return wrap(t, width, 2)


def runs_section(projects, runs, width):
    out = [Text("RUNS ENDED TODAY", style="bold")]
    if runs is None:
        return out + wrap(Text("  the snapshot has no finished[] yet: a dispatcher release that writes it fills "
                               "this table", style="dim"), width, 2)
    if not runs:
        return out + [Text("  none yet", style="dim")]
    rows = []
    for name, r in runs:
        cost = num(r, "cost_usd")
        out_ = txt(r, "outcome", "?")
        rows.append([Text(time.strftime("%H:%M", time.localtime(ended(r))) if ended(r) else "--:--", style="dim"),
                     Text(name, style="bold"), Text(tag(r)), Text(txt(r, "kind", "?")),
                     Text("" if num(r, "minutes") is None else "%d" % num(r, "minutes")),
                     Text("" if num(r, "turns") is None else "%d" % num(r, "turns")),
                     Text("–" if cost is None else "$%.2f" % cost, style="dim" if cost is None else ""),
                     Text(out_, style="green" if out_ == "done" else "yellow")])
    return out + columns(["Ended", "Project", "Run", "Kind", "Min", "Turns", "Cost", "Outcome"], rows, width,
                         phone=width <= 80)


def event_line(row, now, width, marked):
    at, first, count, text, issue, note, name, cols = row
    t = Text("  ")
    stamp = clock(now, at) if at else "--:--"
    if first and first != at and clock(now, first) != stamp:
        stamp = "%s–%s" % (clock(now, first), stamp)
    t.append(stamp + " ", style="dim")
    if marked:
        t.append(name + " ", style="bold")
    if note:
        word, style = NOTES[note]
        return wrap(t.append(word + " ", style=style).append(text), width, 8)
    m = LINK_AT_END.search(text)
    url = m.group(0)[3:] if m else ""
    text = LINK_AT_END.sub("", text)
    fail = FAILURE.search(text)
    if fail:
        glyph(STUCK, t).append(" ")
    if count > 1:
        t.append("×%d " % count, style="bold")
    style = "yellow" if fail else "green" if MERGED.search(text) else "red" if NEEDS.search(text) else ""
    n = NUMBER.search(text)
    if url and n:
        t.append(text[:n.start()], style=style).append_text(link(url, n.group(0)))
        t.append(text[n.end():], style=style)
    else:
        if issue is not None and text.startswith("#%d" % issue):
            t.append("#%d" % issue, style=cols.get(issue, "bold"))
            text = text[len("#%d" % issue):]
        t.append(text, style=style)
        if url:
            t.append(" ").append_text(link(url, "link"))
    return wrap(t, width, 8)


def activity(projects, now, width):
    runs = finished(projects, day_start(now))
    marked = len(projects) > 1
    out = today_line(projects, now, width, runs) + [Text("")]
    out += runs_section(projects, runs, width) + [Text("")]
    out.append(Text("EVENTS", style="bold").append("  newest first · repeats folded", style="dim"))
    rows = events(projects, now)
    for r in rows:
        out += event_line(r, now, width, marked)
    if not rows:
        out.append(Text("  nothing yet", style="dim"))
    return out
