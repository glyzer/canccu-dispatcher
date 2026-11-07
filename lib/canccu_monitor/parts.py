# SPDX-License-Identifier: AGPL-3.0-or-later
"""The small pieces every section draws with (rich): the glyphs, ages and clock times, lines that
wrap or are cut to a width, links, the pipeline in text, folded events.

Every section builds plain rich Text lines that already fit the width (draw.render counts them
to fit the terminal's height), so nothing here relies on rich's own wrapping."""
import re
import time

from rich.style import Style
from rich.text import Text

from .data import num, txt

SCHEMA = 2
PHONE_UPTO = 80          # the phone form up to this width
STEPS = [("work", "work"), ("ci", "CI"), ("review", "review"), ("fix", "fix"),
         ("fix-check", "fix-check"), ("merge", "merge")]
NO_CHECKS = "no-checks"  # a PR with no CI check reported
# the glyphs; colours reinforce them and never carry meaning alone (NO_COLOR reads the same)
DONE, CUR, TODO, STUCK, NONE, YOU, SKIP = "✓", "◉", "○", "⚠", "∅", "✖", "–"
GLYPH_STYLE = {DONE: "green", CUR: "bold cyan", TODO: "dim", STUCK: "yellow", NONE: "yellow", YOU: "bold red",
               SKIP: "dim"}
LEGEND = [(DONE, "done"), (CUR, "now"), (TODO, "to come"), (STUCK, "stuck"), (NONE, "no checks"), (YOU, "you")]
# the counters in an event's text: a try number, the minutes of a wait, ×N, a number that ends the
# line (a step's or an issue's number elsewhere is no counter); the snapshot folds with the same
# rule (lib/canccu-snapshot.sh, snap_events)
FOLD_COUNTERS = [(re.compile(r"try \d+"), "try N"), (re.compile(r"after \d+ min"), "after N min"),
                 (re.compile(r"×\d+"), "×N"), (re.compile(r"(?<![#\w-])\d+$"), "N")]
# the " · <url>" the dispatcher's needs-you, accept and step lines end with
LINK_AT_END = re.compile(r" · https?://\S+$")
FAILURE = re.compile(r"\bfail|\berror|could not|cannot|\bred\b|\brefused\b", re.I)


def ago(now, t):
    """An age to the minute (<1m, then minutes): the frame then changes at most once a minute
    while the snapshot does not, and an unchanged frame is not redrawn."""
    if t is None:
        return ""
    s = max(0, int(now - t))
    if s < 60:
        return "<1m"
    if s < 3600:
        return "%dm" % (s // 60)
    if s < 86400:
        return "%dh%02dm" % (s // 3600, s % 3600 // 60)
    return "%dd" % (s // 86400)


def hm(t):
    return time.strftime("%H:%M", time.localtime(t))


def clock(now, t):
    """A clock time, with the weekday when it is not within the last day."""
    return hm(t) if abs(now - t) < 86400 else time.strftime("%a %H:%M", time.localtime(t))


def colour(c):
    """The style of an ANSI 256 issue colour (bold), or plain bold."""
    return "bold color(%d)" % c if isinstance(c, int) and not isinstance(c, bool) and 0 <= c <= 255 else "bold"


def issue_style(item):
    return colour(num(item, "color"))


def tag(item):
    """#<issue>, else PR #<pr>, else the run's key."""
    n, pr = num(item, "issue"), num(item, "pr")
    return "#%d" % n if n is not None else "PR #%d" % pr if pr is not None else txt(item, "key", "?")


def glyph(g, t=None):
    """A Text with the glyph in its style (appended to t when given)."""
    t = t if t is not None else Text()
    t.append(g, style=GLYPH_STYLE.get(g, ""))
    return t


def line(*parts):
    """A Text of (text, style) pairs and plain strings."""
    t = Text()
    for p in parts:
        if isinstance(p, Text):
            t.append_text(p)
        elif isinstance(p, tuple):
            t.append(p[0], style=p[1])
        else:
            t.append(p)
    return t


def link(url, label=None):
    """A blue OSC 8 link (the plain URL where the terminal has no hyperlinks)."""
    ok = url.startswith(("https://", "http://"))
    return Text(label or url, style=Style(color="blue", link=url) if ok else Style())


def wrap(t, width, indent=0):
    """The line as lines of at most width cells: broken at spaces (inside a word only when it
    is longer than a line), the next lines indented. Nothing is cut."""
    if isinstance(t, str):
        t = Text(t)
    width = max(indent + 8, width)
    plain, out, pos, first = t.plain, [], 0, True
    while True:
        avail = width if first else width - indent
        rest = plain[pos:]
        if len(rest) <= avail:
            piece, nxt = t[pos:], len(plain)
        else:
            sp = plain.rfind(" ", pos, pos + avail + 1)
            end, nxt = (pos + avail, pos + avail) if sp <= pos else (sp, sp + 1)
            piece = t[pos:end]
        piece.rstrip()
        out.append(piece if first else Text(" " * indent) + piece)
        pos, first = nxt, False
        while pos < len(plain) and plain[pos] == " ":
            pos += 1
        if pos >= len(plain):
            return out


def cut(t, width):
    """The line cut to width with … (only for what may be cut: [tN] lines, roadmap titles)."""
    if isinstance(t, str):
        t = Text(t)
    if len(t.plain) <= width:
        return t
    t = t[:max(0, width - 1)]
    t.append("…", style="dim")
    return t


def url_lines(urls, width, indent):
    """The URLs as text (so a phone can copy them) and OSC 8 links: on one line when they fit,
    else one per line; a URL longer than the line is broken into pieces, never cut."""
    urls = [(label, u) for label, u in urls if u]
    one = Text(" " * indent)
    for i, (label, u) in enumerate(urls):
        if i:
            one.append("   ")
        if label:
            one.append(label + " ", style="dim")
        one.append_text(link(u))
    if len(one.plain) <= width:
        return [one] if urls else []
    out = []
    for label, u in urls:
        head = Text(" " * indent + (label + " " if label else ""), style="dim")
        room = max(8, width - len(head.plain))
        for k in range(0, len(u), room):
            t = head.copy() if k == 0 else Text(" " * len(head.plain))
            t.append_text(link(u, u[k:k + room]) if len(u) > room else link(u))
            out.append(t)
    return out


def bar(pct, cells=8):
    filled = max(0, min(cells, round(cells * pct / 100))) if pct is not None else 0
    return "▰" * filled + "▱" * (cells - filled)


# ------------------------------------------------------------------ the pipeline

def stage_at(it):
    """(index of the current stage in STEPS or None, its key)."""
    p = txt(it, "pipeline")
    key = "ci" if p == NO_CHECKS else p
    keys = [k for k, _ in STEPS]
    return (keys.index(key) if key in keys else None), p


def caps(it):
    """Minutes and turns against their caps: 29/150 min · 36/250 turns; minutes alone: 3m."""
    m, mc, tn, tc = num(it, "minutes"), num(it, "min_cap"), num(it, "turns"), num(it, "turn_cap")
    parts = []
    if m is not None:
        parts.append("%d/%d min" % (m, mc) if mc else "%dm" % m)
    if tn is not None and tc:
        parts.append("%d/%d turns" % (tn, tc))
    return " · ".join(parts)


def current_cell(it):
    """The current stage: its name, glyph and minutes and turns against their caps. CI in text:
    ◉ 12m (running), ⚠ 90m+ (pending past its cap), ∅ no checks (none reported)."""
    i, p = stage_at(it)
    name = dict(STEPS)[STEPS[i][0]] if i is not None else (p or "?")
    t = Text(name, style="bold")
    t.append(" ")
    m, mc = num(it, "minutes"), num(it, "min_cap")
    if p == NO_CHECKS:
        glyph(NONE, t).append(" no checks", style="yellow")
        if m is not None:
            t.append(" " + caps(it))
    elif p == "ci" and m is not None and mc and m >= mc:
        glyph(STUCK, t).append(" %dm+" % mc, style="yellow")
    elif p == "ci":
        glyph(CUR, t)
        if m is not None:
            t.append(" %dm" % m)
    else:
        glyph(CUR, t)
        if caps(it):
            t.append(" " + caps(it))
    return t


def changes(it):
    """The full review asked for changes: the unit is in or past its fix round."""
    i, _ = stage_at(it)
    return txt(it, "review_verdict") == "changes" or (i is not None and STEPS[i][0] in ("fix", "fix-check"))


def ci_cell(it, t):
    """The PR's CI state past the CI step: ✓ green, ∅ no checks, ✖ red, ◉ running, ? unknown."""
    ci = txt(it, "ci")
    if ci == "none":
        return glyph(NONE, t).append(" no checks", style="yellow")
    if ci == "red":
        return glyph(YOU, t).append(" red", style="red")
    if ci == "pending":
        return glyph(CUR, t).append(" running")
    return glyph(DONE, t) if ci == "green" else t.append("?", style="yellow")


def done_cell(key, name, it):
    t = Text(name + " ")
    if key == "ci":
        return ci_cell(it, t)
    if key == "review":
        return glyph(DONE, t).append(" changes" if changes(it) else " pass")
    if key in ("fix", "fix-check") and not changes(it):
        return glyph(SKIP, t)
    return glyph(DONE, t)


def pipeline(it):
    """The whole pipeline in text: work ✓ › CI ∅ no checks › review ✓ changes › fix ✓ ›
    fix-check ◉ 0/20 min · 0/30 turns › merge ○. A run outside it (the planner): its cell."""
    i, _ = stage_at(it)
    if i is None:
        return current_cell(it)
    # a fix round's push waits on CI: the review and the fix are done already
    fix_round = STEPS[i][0] == "ci" and txt(it, "review_verdict") == "changes"
    t = Text()
    for k, (key, name) in enumerate(STEPS):
        if k:
            t.append(" › ", style="dim")
        if k < i or fix_round and key in ("review", "fix"):
            t.append_text(done_cell(key, name, it))
        elif k == i:
            t.append_text(current_cell(it))
        else:
            glyph(TODO, t.append(name + " ", style="dim"))
    return t


# ------------------------------------------------------------------ events

def fold_key(text):
    for rx, word in FOLD_COUNTERS:
        text = rx.sub(word, text)
    return text


def fold_events(events):
    """Consecutive events that differ only in a counter, one row: the newest's time and text,
    first_at (the oldest's time), count (the lines folded; the snapshot may have folded some)."""
    rows = []
    for e in events:
        text = txt(e, "text")
        key = fold_key(text)
        at = num(e, "at")
        count = num(e, "count") or 1
        first = num(e, "first_at") if num(e, "first_at") is not None else at
        if rows and rows[-1]["key"] == key:
            r = rows[-1]
            r.update(at=at, text=text, issue=num(e, "issue"), count=r["count"] + count)
            if first is not None and (r["first_at"] is None or first < r["first_at"]):
                r["first_at"] = first
        else:
            rows.append({"key": key, "at": at, "first_at": first, "count": count, "text": text, "issue": num(e, "issue")})
    return rows
