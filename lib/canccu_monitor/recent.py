# SPDX-License-Identifier: AGPL-3.0-or-later
"""RECENT: each project's latest events, the monitor's own project first, newest last.

Consecutive events that differ only in a counter or a try number are one row with a time range and
×N, marked ⚠ when a failure (parts.fold_events; the snapshot folds with the same rule). The current
steps' Follow-up: and Roadmap note: items are among them. A line's trailing " · <url>" is left out:
the NEEDS YOU box has the link. Rows wrap, never cut."""
from rich.text import Text

from .data import lst, num, txt
from .parts import FAILURE, LINK_AT_END, STUCK, fold_events, glyph, hm, wrap

NOTES = {"follow-up": ("Follow-up:", "bold cyan"), "roadmap": ("Roadmap note:", "bold magenta")}


def rows_of(snap, keep):
    """[(at, first_at, count, text, issue, note kind or None)], newest last, at most keep."""
    events = fold_events(lst(snap, "events"))[-keep:]
    since = min([e["first_at"] for e in events if e["first_at"] is not None] or [0])
    notes = [n for s in lst(snap, "steps") for n in lst(s, "notes")
             if txt(n, "kind") in NOTES and (num(n, "at") or 0) >= since]
    rows = [(e["at"] or 0, e["first_at"], e["count"], e["text"], e["issue"], None) for e in events]
    for n in notes:
        pr = " (PR #%d)" % num(n, "pr") if num(n, "pr") is not None else ""
        rows.append((num(n, "at") or 0, num(n, "at"), 1, txt(n, "text") + pr, None, txt(n, "kind")))
    rows.sort(key=lambda r: r[0])
    return rows


def when(at, first, short):
    if not at:
        return "--:--"
    if first and hm(first) != hm(at):
        a, b = hm(first), hm(at)
        return "%s–%s" % (a, b[3:] if short and a[:2] == b[:2] else b)
    return hm(at)


def colours(snap):
    out = {}
    for it in lst(snap, "running") + lst(snap, "needs_you"):
        if num(it, "issue") is not None and num(it, "color") is not None:
            c = num(it, "color")
            out[num(it, "issue")] = "bold color(%d)" % c if 0 <= c <= 255 else "bold"
    return out


def row(name, at, first, count, text, issue, note, width, phone, cols):
    t = Text(" " if phone else "  ")
    if name:
        t.append(name + " ", style="bold")
    stamp = when(at, first, phone)
    t.append(stamp.ljust(0 if phone or name else 11) + " ", style="dim")
    if note:
        word, style = NOTES[note]
        t.append(word + " ", style=style)
        t.append(text)
        return wrap(t, width, 4 if phone else 15)
    text = LINK_AT_END.sub("", text)
    if FAILURE.search(text):
        glyph(STUCK, t).append(" ")
    if count > 1:
        t.append("×%d " % count, style="bold")
    if issue is not None and text.startswith("#%d" % issue):
        t.append("#%d" % issue, style=cols.get(issue, "bold"))
        text = text[len("#%d" % issue):]
    t.append(text, style="yellow" if FAILURE.search(text) else "")
    return wrap(t, width, 4 if phone else 15)


def recent(projects, width, own_only=False, phone=False):
    names = [n for n, s in projects if isinstance(s, dict)]
    if own_only:
        names = names[:1]
    title = Text("RECENT", style="bold")
    if not phone:
        title.append("  repeats folded · " + " then ".join(names), style="dim")
    rows = [title]
    for k, (name, snap) in enumerate(projects):
        if not isinstance(snap, dict) or (own_only and k):
            continue
        keep = (3 if k == 0 else 2) if phone else (8 if k == 0 else 5)
        cols = colours(snap)
        for r in rows_of(snap, keep):
            rows += row(name if k else "", *r, width, phone, cols)
    if len(rows) == 1:
        rows.append(Text("  nothing yet", style="dim"))
    return rows
