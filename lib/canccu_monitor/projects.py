# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Projects view: a block per project. Its head line (━━ name · repo · pass · runs n of CAP
· today $ · queue ━━), the runs table (Run · Kind · Stage · Age · Turns · Min · Cost · Title; a
live run's cost is –, a run started by hand is Kind other), a line per needs-you and
awaiting-accept item, the current step's line and its packages table (Package · Issues · Risk ·
Wave · Status · Waiting on; a package carried from an earlier wave reads 6→8), the queue table,
the parallel tracks one line. A project without steps has its open PRs where the step line is.

Only the Title column is cut (with …); Waiting on wraps. The tables are plain aligned columns,
no box; up to PHONE_UPTO columns each row is one line of its cells. focus: None, every project in
full; k, project k in full and the others their head line only."""
from rich.text import Text

from .data import lst, num, obj, other_keys, txt
from .inbox import VERBS, how, numbers, pr_url, project_mark, stage_text
from .now import units
from .parts import CUR, NO_CHECKS, NONE, STEPS, STUCK, YOU, ago, cut, glyph, issue_style, link, stage_at, tag, wrap
from .roadmap import done_of, package_row, running_styles

GAP = "  "


def fit_widths(widths, width, cut_col, wrap_col):
    """The columns' widths for the line width: the cut column, then the wrapping one, give up
    cells (to 8 and 12 at least); None when even that does not fit."""
    w = list(widths)
    room = width - 2 - len(GAP) * (len(w) - 1)
    for col, floor in ((cut_col, 8), (wrap_col, 12)):
        if col is not None and sum(w) > room:
            w[col] = max(floor, w[col] - (sum(w) - room))
    return w if sum(w) <= room else None


def columns(head, rows, width, cut_col=None, wrap_col=None, phone=False):
    """The rows as aligned columns under a dim header; the cut column cut with …, the wrapping
    one wrapped in its column. Too narrow (or phone): a line per row, its cells joined."""
    if not rows:
        return []
    widths = [max([len(h)] + [len(r[k].plain) for r in rows]) for k, h in enumerate(head)]
    ws = None if phone else fit_widths(widths, width, cut_col, wrap_col)
    if ws is None:
        return [x for r in rows for x in one_line(r, width, cut_col)]
    out = [Text(" " + GAP[1:] + GAP.join(h.ljust(ws[k]) for k, h in enumerate(head)).rstrip(), style="bold dim")]
    for r in rows:
        cells = []
        for k, c in enumerate(r):
            if k == cut_col:
                cells.append([cut(c, ws[k])])
            elif k == wrap_col and len(c.plain) > ws[k]:
                cells.append(wrap(c, ws[k]))
            else:
                cells.append([c])
        for j in range(max(len(c) for c in cells)):
            t = Text(GAP)
            for k, c in enumerate(cells):
                piece = c[j] if j < len(c) else Text("")
                t.append_text(piece)
                if k < len(cells) - 1:
                    t.append(" " * (ws[k] - len(piece.plain)) + GAP)
            t.rstrip()
            out.append(t)
    return out


def one_line(cells, width, cut_col):
    """A row as one line of its non-empty cells; the cut column last, cut to what is left."""
    t = Text(" ")
    for k, c in enumerate(cells):
        if k != cut_col and c.plain:
            t.append(" ").append_text(c)
    if cut_col is not None and cells[cut_col].plain:
        room = width - len(t.plain) - 1
        if room >= 8:
            return [t.append(" ").append_text(cut(cells[cut_col], room))]
        return wrap(t, width, 4)
    return wrap(t, width, 4)


def stage_short(it):
    """The current stage's name and glyph: work ◉, CI ∅ (no checks), CI ⚠ (past its cap)."""
    i, p = stage_at(it)
    m, mc = num(it, "minutes"), num(it, "min_cap")
    if p == NO_CHECKS:
        return glyph(NONE, Text("CI "))
    if p == "ci" and m is not None and mc and m >= mc:
        return glyph(STUCK, Text("CI "))
    return glyph(CUR, Text((dict(STEPS)[STEPS[i][0]] if i is not None else p or "?") + " "))


def against(n, cap):
    return "" if n is None else "%d/%d" % (n, cap) if cap else "%d" % n


def url_of(snap, it):
    repo, pr, n = txt(snap, "repo"), num(it, "pr"), num(it, "issue")
    if "/" not in repo:
        return ""
    return "https://github.com/%s/%s/%d" % ((repo, "pull", pr) if pr is not None else (repo, "issues", n)) \
        if pr is not None or n is not None else ""


def runs_table(name, snap, now, width, phone):
    rows = []
    for _, _, it in units([(name, snap)]):
        t = tag(it) + ("·PR #%d" % num(it, "pr") if num(it, "pr") is not None and num(it, "issue") is not None else "")
        u = url_of(snap, it)
        run = link(u, t) if u else Text(t)
        run.stylize(issue_style(it))
        rows.append([run, Text(txt(it, "kind", "?")), stage_short(it),
                     Text(ago(now, num(it, "started")), style="dim"),
                     Text(against(num(it, "turns"), num(it, "turn_cap"))), Text(against(num(it, "minutes"), num(it, "min_cap"))),
                     Text("–", style="dim"), Text(txt(it, "title"))])
    skip = other_keys(snap)
    for r in lst(snap, "other_runs"):
        key = txt(r, "key", "?")
        rows.append([Text(key if key in skip else "%s#%s" % (txt(r, "repo"), key)), Text("other", style="magenta"),
                     Text(txt(r, "kind", "?")), Text(ago(now, num(r, "started")), style="dim"), Text(""), Text(""),
                     Text("–", style="dim"), Text("")])
    if not rows:
        return [Text("  nothing running", style="dim")]
    return columns(["Run", "Kind", "Stage", "Age", "Turns", "Min", "Cost", "Title"], rows, width, cut_col=7, phone=phone)


def item_lines(snap, now, width):
    out = []
    for it in sorted(lst(snap, "needs_you"), key=lambda x: num(x, "since") or 0):
        kind = txt(it, "kind")
        t = glyph(YOU, Text("  ")).append(" " + VERBS.get(kind, kind.upper() or "?"), style="bold red")
        if txt(it, "owner") == "leader":
            t.append(" (leader)", style="dim")
        nums = numbers(it, False)
        url = txt(it, "url") or pr_url(snap, it)
        if nums:
            t.append(" ").append_text(link(url, nums) if url else Text(nums, style=issue_style(it)))
        if num(it, "since") is not None:
            t.append(" · " + ago(now, num(it, "since")), style="dim")
        if txt(it, "reason"):
            t.append(" · " + txt(it, "reason"))
        if kind != "accept" and stage_text(it) is not None:
            t.append(" · ", style="dim").append_text(stage_text(it))
        out += wrap(t, width, 6)
        out += wrap(Text("      how: ", style="dim").append(how(it), style="dim"), width, 11)
    return out


def step_line(snap, st, width):
    over = next((o for o in lst(snap, "step_overview") if num(o, "milestone") == num(st, "milestone")), {})
    plan = obj(st, "plan")
    t = Text("  step ", style="bold").append(txt(st, "title", "?"), style="bold")
    parts = []
    if num(plan, "wave") is not None:
        parts.append("wave %d" % num(plan, "wave"))
    if txt(st, "phase"):
        parts.append("phase " + txt(st, "phase"))
    if done_of(over):
        parts.append(done_of(over))
    b = obj(st, "budget")
    if num(b, "usd") is not None:
        parts.append("$%.2f of $%s%s" % (num(b, "usd"), num(b, "limit") if num(b, "limit") is not None else "?",
                                        " (over)" if b.get("over") is True else ""))
    h = obj(st, "health")
    if txt(h, "state"):
        parts.append("health %s" % txt(h, "state") + (" PR #%d" % num(h, "pr") if num(h, "pr") is not None else ""))
    cp = obj(st, "checkpoint")
    if num(cp, "issue") is not None:
        parts.append("checkpoint #%d %s" % (num(cp, "issue"), "waits on you" if cp.get("waiting") is True
                                            else txt(cp, "state") or "later"))
    for p in parts:
        t.append(" · ", style="dim").append(p)
    return wrap(t, width, 4), over


def packages_table(snap, st, over, width, phone):
    plan = obj(st, "plan")
    wave, styles = num(plan, "wave"), running_styles(snap)
    rows = []
    for p in lst(plan, "packages"):
        name, iss, risk, status, wait = package_row(snap, p, over, styles)
        carried = num(p, "carried_from")
        w = "%d→%d" % (carried, wave) if carried is not None and wave is not None else "" if wave is None else str(wave)
        rows.append([name, iss, risk, Text(w), status, wait])
    return columns(["Package", "Issues", "Risk", "Wave", "Status", "Waiting on"], rows, width, wrap_col=5, phone=phone)


def queue_table(snap, width, phone):
    rows = []
    for q in lst(snap, "queue"):
        if num(q, "issue") is None:
            continue
        wait = txt(q, "waits_on") if q.get("blocked") is True else ""
        rows.append([Text("#%d" % num(q, "issue"), style="bold"), Text(txt(q, "lane") or "fast", style="dim"),
                     Text(wait), Text(txt(q, "title"))])
    if not rows:
        return []
    return [Text("  queue", style="bold")] + columns(["Issue", "Lane", "Waiting on", "Title"], rows, width, cut_col=3,
                                                    wrap_col=2, phone=phone)


def head_line(name, snap, now, width):
    t = Text("━━ ", style="bold")
    if not isinstance(snap, dict):
        return [t.append(name + " · no snapshot", style="bold")]
    t.append_text(project_mark(name, snap, now, True, False))
    caps, sp = obj(snap, "caps"), obj(snap, "spend")
    t.append(" · runs %s of %s" % (num(caps, "running") if num(caps, "running") is not None else "?",
                                    num(caps, "cap") if num(caps, "cap") is not None else "?"))
    if num(sp, "today_usd") is not None:
        t.append(" · today $%.2f" % num(sp, "today_usd"))
    t.append(" · queue %d " % len(lst(snap, "queue")))
    if len(t.plain) + 2 <= width:
        return [t.append("━" * (width - len(t.plain)), style="bold")]
    return wrap(t, width, 3)


def block(name, snap, now, width):
    phone = width <= 80
    out = head_line(name, snap, now, width)
    if not isinstance(snap, dict):
        return out
    out += runs_table(name, snap, now, width, phone)
    out += item_lines(snap, now, width)
    current = [s for s in lst(snap, "steps") if s.get("current") is True]
    main = [s for s in current if txt(s, "track") != "parallel"]
    for st in main[:1] or current[:1]:
        line, over = step_line(snap, st, width)
        out += line + packages_table(snap, st, over, width, phone)
    par = [s for s in current if s not in (main[:1] or current[:1])]
    if par:
        t = Text("  parallel tracks: ", style="bold")
        for k, s in enumerate(par):
            over = next((o for o in lst(snap, "step_overview") if num(o, "milestone") == num(s, "milestone")), {})
            t.append((" · " if k else "") + txt(s, "title", "?") + (" (%s)" % done_of(over) if done_of(over) else ""))
        out += wrap(t, width, 4)
    if not current:
        prs = sorted({num(it, "pr") for it in lst(snap, "running") + lst(snap, "needs_you") if num(it, "pr") is not None})
        out.append(Text("  no steps (simple workflow) · " + ("open PRs " + " ".join("#%d" % p for p in prs)
                                                              if prs else "no open PR"), style="dim"))
    return out + queue_table(snap, width, phone)


def projects_view(projects, now, width, focus=None):
    out = []
    for k, (name, snap) in enumerate(projects):
        if k:
            out.append(Text(""))
        out += block(name, snap, now, width) if focus is None or focus == k else head_line(name, snap, now, width)
    return out
