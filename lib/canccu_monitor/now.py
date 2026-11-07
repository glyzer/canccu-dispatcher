# SPDX-License-Identifier: AGPL-3.0-or-later
"""NOW: every project's running units, the runs by hand, what is parked on the product owner,
and what is up next.

Per unit, line 1: the project, #issue, PR #n or "no PR yet", the title. Line 2: the whole pipeline
in text with the current stage's minutes and turns against their caps (collapsed: the current
stage on line 1). Line 3: the dim [tN] last line, cut with … (dropped first when space is short).
The phone: one line per unit with its current stage, minutes and PR."""
from rich.text import Text

from .data import local_repo, lst, num, other_keys, txt
from .inbox import items, numbers, slots, stage_cell
from .parts import LEGEND, ago, ci_cell, current_cell, cut, glyph, issue_style, pipeline, stage_at, tag, wrap


def units(projects):
    """[(project, snapshot, running item)] the dispatcher runs or waits on."""
    out = []
    for name, snap in projects:
        skip = other_keys(snap)
        out += [(name, snap, it) for it in lst(snap, "running") if not (txt(it, "key") and txt(it, "key") in skip)]
    return out


def others(projects, marked, now):
    rows = []
    for name, snap in projects:
        repo = local_repo(snap)
        for r in lst(snap, "other_runs"):
            t = Text("  " + (name + " " if marked else ""))
            t.append("other ", style="bold magenta")
            key = txt(r, "key", "?") if txt(r, "repo") in (repo, "") else "%s#%s" % (txt(r, "repo"), txt(r, "key", "?"))
            t.append("%s · %s" % (key, txt(r, "kind", "?")))
            if num(r, "started") is not None:
                t.append(" · " + ago(now, num(r, "started")), style="dim")
            rows.append(t)
    return rows


def ci_note(it):
    """For the phone: the CI state once the unit is past the CI step and it is not green."""
    i, _ = stage_at(it)
    return i is not None and i > 1 and txt(it, "ci") in ("none", "red", "pending")


def parked(projects, marked, short=False):
    """The units parked on the product owner, one line: #52 PR #60 at CI ⚠ · tools PR #131 at merge ✖ accept."""
    own = projects[0][0]
    out = []
    for name, _, it in items(projects):
        st = txt(it, "stage")
        if not st:
            continue
        t = Text(name + " " if marked and name != own else "")
        if txt(it, "kind") == "accept":
            t.append("PR #%s" % num(it, "pr") if num(it, "pr") is not None else numbers(it, True), style=issue_style(it))
        else:
            t.append(numbers(it, True), style=issue_style(it))
        t.append(" " if short else " at ")
        stage_cell(st, t)
        if txt(it, "kind") == "accept":
            t.append(" accept", style="bold red")
        out.append(t)
    return out


def up_next(projects):
    out = []
    for name, snap in projects:
        q = lst(snap, "queue")
        ready = [it for it in q if it.get("blocked") is not True and num(it, "issue") is not None]
        blocked = len(q) - len(ready)
        if not q:
            out.append(Text("%s queue empty" % name, style="dim"))
            continue
        t = Text(name + " ")
        t.append(" ".join("#%d" % num(it, "issue") for it in ready[:5]) or "nothing ready", style="bold" if ready else "dim")
        if len(ready) > 5:
            t.append(" +%d" % (len(ready) - 5))
        if blocked:
            t.append(" (%d blocked)" % blocked, style="dim")
        out.append(t)
    return out


def joined(head, parts, width, indent):
    t = Text(head, style="bold") if isinstance(head, str) else head
    for k, p in enumerate(parts):
        if k:
            t.append(" · ", style="dim")
        t.append_text(p)
    return wrap(t, width, indent)


def title_line(own, width):
    t = Text("NOW", style="bold")
    t.append(" · running %s" % slots(own).replace("/", " of "))
    leg = Text()
    for k, (g, word) in enumerate(LEGEND):
        if k:
            leg.append("   ")
        glyph(g, leg).append(" " + word, style="dim")
    if len(t.plain) + 4 + len(leg.plain) <= width:
        t.append(" " * (width - len(t.plain) - len(leg.plain)))
        return [t.append_text(leg)]
    return [t] + wrap(Text("  ").append_text(leg), width, 2)


def now_section(projects, now, width, marked, last_lines=True, collapsed=False):
    rows = title_line(projects[0][1], width)
    us = units(projects)
    for name, _, it in us:
        t = Text("  " + (name + " " if marked else ""), style="bold")
        t.append(tag(it), style=issue_style(it))
        t.append("  ")
        t.append("PR #%d" % num(it, "pr") if num(it, "pr") is not None else "no PR yet",
                 style="" if num(it, "pr") is not None else "dim")
        if collapsed:
            t.append("  ").append_text(current_cell(it))
        if txt(it, "title"):
            t.append("  " + txt(it, "title"))
        rows += wrap(t, width, 6)
        if not collapsed:
            rows += wrap(Text("      ").append_text(pipeline(it)), width, 8)
        if last_lines and txt(it, "last_line"):
            rows.append(cut(Text("      " + txt(it, "last_line"), style="dim"), width))
    rows += others(projects, marked, now)
    if not us and not any(lst(s, "other_runs") for _, s in projects):
        rows.append(Text("  nothing running", style="dim"))
    p = parked(projects, marked)
    if p:
        rows += joined(Text("  parked (needs you):  ", style="bold"), p, width, 4)
    rows += joined(Text("  up next:  ", style="bold"), up_next(projects), width, 4)
    return rows


def phone_now(projects, now, width, marked):
    rows = [Text("NOW " + slots(projects[0][1]), style="bold")]
    us = units(projects)
    for name, _, it in us:
        t = Text(" " + (name + " " if marked else ""), style="bold")
        t.append(tag(it), style=issue_style(it))
        t.append(" ").append_text(current_cell(it))
        t.append(" · PR #%d" % num(it, "pr") if num(it, "pr") is not None else " · no PR yet",
                 style="" if num(it, "pr") is not None else "dim")
        if ci_note(it):
            ci_cell(it, t.append(" · CI "))
        rows += wrap(t, width, 3)
    rows += [cut(r_, width) for r_ in others(projects, marked, now)]
    if not us and not any(lst(s, "other_runs") for _, s in projects):
        rows.append(Text(" nothing running", style="dim"))
    p = parked(projects, marked, short=True)
    if p:
        rows += joined(Text(" parked: ", style="bold"), p, width, 2)
    rows += joined(Text(" up next: ", style="bold"), up_next(projects), width, 2)
    return rows

