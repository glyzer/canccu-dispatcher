# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Summary view: the most important things, one line each, top to bottom: the 2-line header
(one line on a phone) and its banners; NEEDS YOU (verb, project, numbers, age, reason, stage; a
how: line under it), NOW (a line per run: numbers, the current stage with minutes and turns
against their caps, the title; then parked and up next), STEPS (a line per current step of every
project, a simple project's PRs and queue), RECENT (every project's events, newest first, what
fits), the glyph legend.

It never scrolls: when the height is short it drops, in this order, the how: lines, RECENT, the
legend, the blank lines, the steps to the main track's; the needs-you lines never drop (what
still does not fit is cut at the bottom, below them). It is the only view that cuts text with …,
and only titles and reasons: a number, an age or a how: line wraps instead."""
from rich.text import Text

from .data import lst, num, obj, txt
from .fit import blockers, top
from .inbox import VERBS, banners, header, how, items, leader_line, numbers, pr_url, stage_text
from .now import joined, others, parked, units, up_next
from .parts import DONE, LEGEND, YOU, ago, current_cell, cut, glyph, issue_style, link, tag, wrap
from .recent import colours, row, rows_of
from .roadmap import done_of, has_steps, waiting

MIN_RECENT = 3  # RECENT shows at least this many rows, or drops (it takes what fits above that)


def fixed_and_cut(fixed, cuttable, tail, width, indent):
    """fixed · cuttable · tail on one line, cuttable cut with … to what is left; when even fixed
    and tail do not fit, they wrap and cuttable goes."""
    t = fixed.copy()
    room = width - len(t.plain) - len(tail.plain) - (3 if tail.plain else 0) - 3
    if cuttable.plain and room >= 8:
        t.append(" · ", style="dim").append_text(cut(cuttable, room))
    if tail.plain:
        t.append(" · ", style="dim").append_text(tail)
    return [t] if len(t.plain) <= width else wrap(t, width, indent)


def needs_lines(projects, now, width, marked, with_how):
    its = items(projects)
    if not its:
        return [Text("").append_text(glyph(DONE)).append(" nothing needs you", style="green")] + \
            leader_line(projects, now, width, width <= 80)
    out = [glyph(YOU).append(" NEEDS YOU · %d" % len(its), style="bold red")]
    for name, snap, it in its:
        kind = txt(it, "kind")
        t = glyph(YOU, Text(" "))
        t.append(" " + VERBS.get(kind, kind.upper() or "?").ljust(8), style="bold red")
        if marked:
            t.append(" " + name, style="bold")
        nums = numbers(it, width <= 80)
        url = txt(it, "url") or pr_url(snap, it)
        if nums:
            t.append(" ").append_text(link(url, nums) if url else Text(nums))
            t.stylize(issue_style(it), len(t.plain) - len(nums))
        if num(it, "since") is not None:
            t.append(" · ", style="dim").append(ago(now, num(it, "since")), style="dim")
        stage = stage_text(it) if kind != "accept" else None
        out += fixed_and_cut(t, Text(txt(it, "reason")), stage or Text(""), width, 12)
        if with_how:
            out += wrap(Text("     how: ", style="bold").append(how(it), style=""), width, 10)
    return out + leader_line(projects, now, width, width <= 80)


def now_lines(projects, now, width, marked):
    own = projects[0][1]
    caps = obj(own, "caps")
    run, cap = num(caps, "total_running"), num(caps, "total_cap")
    out = [Text("NOW", style="bold").append(" · running %s of %s" % ("?" if run is None else run, "?" if cap is None else cap))]
    us = units(projects)
    for name, _, it in us:
        t = Text("  " + (name + " " if marked else ""), style="bold")
        t.append(tag(it), style=issue_style(it))
        if num(it, "pr") is not None:
            t.append(" PR #%d" % num(it, "pr"))
        t.append("  ").append_text(current_cell(it))
        out += fixed_and_cut(t, Text(txt(it, "title")), Text(""), width, 6)
    out += [cut(x, width) for x in others(projects, marked, now)]
    if not us and not any(lst(s, "other_runs") for _, s in projects):
        out.append(Text("  nothing running", style="dim"))
    p = parked(projects, marked, short=width <= 80)
    if p:
        out += joined(Text("  parked: ", style="bold"), p, width, 4)
    return out + joined(Text("  up next: ", style="bold"), up_next(projects), width, 4)


def step_waits(snap, milestone):
    reasons = [waiting(txt(i, "waits_on")) for o in lst(snap, "step_overview") if num(o, "milestone") == milestone
               for i in lst(o, "issues") if txt(i, "status") == "blocked" and txt(i, "waits_on")]
    tops = blockers(reasons)
    return top(tops[:3], len(tops) - 3 if len(tops) > 3 else 0) if tops else ""


def step_line(name, snap, st, width, marked):
    over = next((o for o in lst(snap, "step_overview") if num(o, "milestone") == num(st, "milestone")), {})
    t = Text("  " + (name + " " if marked else ""), style="bold")
    t.append(txt(st, "title", "?"), style="bold")
    if txt(st, "track") == "parallel":
        t.append(" (parallel)", style="dim")
    d = done_of(over).replace(" done", "")
    if d:
        t.append(" · %s done" % d)
    b = obj(st, "budget")
    if num(b, "usd") is not None:
        t.append(" · ", style="dim").append("$%.2f of $%s" % (num(b, "usd"), num(b, "limit") if num(b, "limit") is not None
                                                             else "?"), style="bold red" if b.get("over") is True else "")
    if txt(st, "phase"):
        t.append(" · ", style="dim").append("phase " + txt(st, "phase"),
                                            style="yellow" if txt(st, "phase") in ("needs-you", "checkpoint") else "")
    waits = step_waits(snap, num(st, "milestone"))
    return fixed_and_cut(t, Text("waits on " + waits, style="dim") if waits else Text(""), Text(""), width, 4)


def simple_line(name, snap, width, marked):
    """A project without steps: its open PRs and its queue, where a stepped project has its step line."""
    t = Text("  " + (name + " " if marked else ""), style="bold")
    t.append("no steps (simple workflow)" if not has_steps(snap) else "fast lane", style="dim")
    prs = sorted({num(it, "pr") for it in lst(snap, "running") + lst(snap, "needs_you") if num(it, "pr") is not None})
    q = lst(snap, "queue")
    blocked = sum(1 for it in q if it.get("blocked") is True)
    t.append(" · PRs " + " ".join("#%d" % p for p in prs) if prs else " · no open PR")
    t.append(" · queue %d%s" % (len(q), " (%d blocked)" % blocked if blocked else ""))
    return wrap(t, width, 4)


def steps_lines(projects, width, marked, main_only):
    out = [Text("STEPS", style="bold")]
    for name, snap in projects:
        if not isinstance(snap, dict):
            out.append(Text("  %s: no snapshot" % name, style="dim"))
            continue
        current = sorted([s for s in lst(snap, "steps") if s.get("current") is True], key=lambda s: txt(s, "track") != "main")
        if main_only:
            current = [s for s in current if txt(s, "track") != "parallel"][:1]
        for st in current:
            out += step_line(name, snap, st, width, marked)
        lane = [it for it in lst(snap, "running") + lst(snap, "queue") if not txt(it, "package")]
        if not current or (lane and not main_only):
            out += simple_line(name, snap, width, marked)
    return out


def recent_rows(projects, width, marked):
    """[lines of one event], every project's merged, newest first."""
    rows = []
    for name, snap in projects:
        if isinstance(snap, dict):
            cols = colours(snap)
            rows += [(r[0], name if marked else "", r, cols) for r in rows_of(snap, 20)]
    rows.sort(key=lambda x: -x[0])
    return [row(name, *r, width, width <= 80, cols) for _, name, r, cols in rows]


def legend_line(width):
    t = Text("  ")
    for k, (g, word) in enumerate(LEGEND):
        glyph(g, t.append("   " if k else "")).append(" " + word, style="dim")
    return wrap(t, width, 2)


def summary(projects, now, width, height, marked):
    """The view's lines (the bar not included), at most height (None: no limit)."""
    head = header(projects, now, width, width <= 80)
    own = projects[0][1]
    if isinstance(own, dict):
        head += banners(own, now, width)
    rec = recent_rows(projects, width, marked)
    lines = []
    for level in range(6):
        how_, recent_, legend_, blank, main_only = level < 1, level < 2, level < 3, level < 4, level >= 5
        gap = [Text("")] if blank else []
        lines = head + gap + needs_lines(projects, now, width, marked, how_)
        lines += gap + now_lines(projects, now, width, marked)
        lines += gap + steps_lines(projects, width, marked, main_only)
        tail = (gap + legend_line(width)) if legend_ else []
        if recent_ and rec:
            room = None if height is None else height - len(lines) - len(tail) - len(gap) - 1
            shown, used = [], 0
            for r in rec:
                if room is not None and used + len(r) > room:
                    break
                shown.append(r)
                used += len(r)
            if room is not None and len(shown) < min(MIN_RECENT, len(rec)):
                continue
            lines += gap + [Text("RECENT", style="bold").append("  newest first", style="dim")]
            lines += [x for r in shown for x in r]
        lines += tail
        if height is None or len(lines) <= height:
            break
    return lines if height is None else lines[:height]
