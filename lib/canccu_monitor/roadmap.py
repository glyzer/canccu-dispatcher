# SPDX-License-Identifier: AGPL-3.0-or-later
"""ROADMAP: a table per project, the projects stacked (each as wide as the pane allows).

Steps (schema 2): Step · Work · Issues · Risk · Status · Waiting on. The Step cell carries the
step's number and name, NOW or NEXT, "N of M done" and the spend against the step budget; a row
per package, the issues outside a package grouped per status (a group of one shows its title),
the health pass and the checkpoint when they have something to say; the later steps are one row
spanning the other columns. The fast lane (no steps): Issue · Title · PR · Status (· Waiting on
when a row waits on something), a row per managed or queued issue. A snapshot without steps
(schema 1): the milestone bars of before, then the fast lane.

One status vocabulary, a mark each (VOCAB): ● running, ○ can go next, – blocked or later,
✖ needs you, ✓ done. "Waiting on" names the blocker in words. Nothing is cut: long cells wrap.
detail=False drops the later steps and the blocked groups; headers_only keeps a line per step.
The phone form (phone=True) puts each step's cell on a heading line above its table."""
import io
import re

from rich import box
from rich.console import Console
from rich.table import Table
from rich.text import Text

from .data import lst, num, nums, obj, other_keys, txt
from .parts import cut, issue_style, line, wrap

RUN, NEXT, WAIT, YOU, DONE = "●", "○", "–", "✖", "✓"
MARK_STYLE = {RUN: "green", NEXT: "cyan", WAIT: "dim", YOU: "bold red", DONE: "green"}
VOCAB = [(RUN, "running"), (NEXT, "can go next"), (WAIT, "blocked or later"), (YOU, "needs you"), (DONE, "done")]
# a package's state, a run's pipeline stage → (mark, word)
STATE = {"merged": (DONE, "merged"), "closed": (DONE, "closed"), "accept": (YOU, "accept"),
         "needs-you": (YOU, "needs you"), "refused": (YOU, "refused"), "pending": (NEXT, "ready"),
         "blocked": (WAIT, "blocked"), "work": (RUN, "working"), "ci": (RUN, "in CI"), "no-checks": (RUN, "no checks"),
         "review": (RUN, "in review"), "fix": (RUN, "fixing"), "fix-check": (RUN, "fix-check"),
         "merge": (RUN, "merging"), "merging": (RUN, "merging"), "plan": (RUN, "planning")}
# an issue's status in the step overview → (mark, word)
ISSUE = {"running": (RUN, "working"), "accept": (YOU, "accept"), "needs-you": (YOU, "needs you"),
         "ready": (NEXT, "ready"), "blocked": (WAIT, "blocked"), "done": (DONE, "done")}
# a parked unit's needs-you kind → (word, what it waits on)
PARKED = {"accept": ("accept", "your accept"), "plan": ("plan", "your OK"), "question": ("question", "your answer")}
ORDER = [RUN, YOU, NEXT, WAIT, DONE]
STEP_COLS = ["Step", "Work", "Issues", "Risk", "Status", "Waiting on"]
FAST_COLS = ["Issue", "Title", "PR", "Status", "Waiting on"]
FLEX = {"Work", "Title", "Waiting on"}  # the columns that wrap first when the table is too wide


def has_steps(snap):
    return bool(lst(snap, "steps") or lst(snap, "step_overview"))


def legend(width):
    """● running  ○ can go next  – blocked or later  ✖ needs you  ✓ done (wrapped to width)."""
    t = Text("  ")
    for k, (m, word) in enumerate(VOCAB):
        t.append(("  " if k else "") + m, style=MARK_STYLE[m])
        t.append(" " + word, style="dim")
    return wrap(t, width, 2)


def status(mark, word, pr=None):
    t = Text(mark, style=MARK_STYLE.get(mark, ""))
    t.append(" " + word, style="bold red" if mark == YOU else "dim" if mark == WAIT else "")
    if pr is not None:
        t.append(" PR #%d" % pr)
    return t


def waiting(w):
    """The snapshot's waits_on in words: depends on auth → auth, blocked by 12 14 → #12 #14."""
    w = (w or "").strip()
    if w.startswith("depends on "):
        return w[len("depends on "):]
    if w.startswith("blocked by "):
        return " ".join("#" + n for n in w[len("blocked by "):].split())
    m = re.match(r"waits: one-at-a-time issue (#\d+) is open", w)
    if m:
        return "%s (one at a time)" % m.group(1)
    return "the step budget" if w == "step budget reached" else w


def ready_wait(snap):
    """What a ready issue waits on: the usage limit, a free slot, or nothing."""
    if txt(obj(snap, "usage"), "state") in ("stop", "drain"):
        return "the usage limit"
    c = obj(snap, "caps")
    for r, cap in (("running", "cap"), ("total_running", "total_cap")):
        if num(c, r) is not None and num(c, cap) and num(c, r) >= num(c, cap):
            return "a free slot"
    return ""


def run_status(it):
    """A running unit's (mark, word) from its stage: a review not started yet can go next."""
    p = txt(it, "pipeline")
    if p == "review" and txt(it, "kind") == "waiting":
        return NEXT, "waits for review"
    return STATE.get(p, (RUN, p or "running"))


def issue_list(ns):
    """#48 #130; a run of 3 or more as #107–#109; more than 3 issues in more than 2 parts: N issues."""
    ns, parts, k = sorted(set(ns)), [], 0
    while k < len(ns):
        j = k
        while j + 1 < len(ns) and ns[j + 1] == ns[j] + 1:
            j += 1
        if j - k >= 2:
            parts.append("#%d–#%d" % (ns[k], ns[j]))
        else:
            parts += ["#%d" % n for n in ns[k:j + 1]]
        k = j + 1
    return " ".join(parts) if len(parts) <= 2 or len(ns) <= 3 else "%d issues" % len(ns)


def counted(reasons):
    """One reason as it is; several counted, the most first: 12 labelled blocked · 2 no ready
    label · 1 behind #110; each once: no ready label · #110."""
    rs = [r for r in reasons if r]
    counts = {}
    for r in rs:
        counts[r] = counts.get(r, 0) + 1
    if len(counts) == 1 and len(rs) == len(reasons) or all(c == 1 for c in counts.values()):
        return " · ".join(counts)
    return " · ".join("%d %s%s" % (c, "behind " if r.startswith("#") else "", r)
                      for r, c in sorted(counts.items(), key=lambda x: -x[1]))


def done_of(over):
    o, c = num(over, "work_open"), num(over, "work_closed")
    return "%d of %d done" % (c, o + c) if o is not None and c is not None else ""


# ------------------------------------------------------------------ the model

def by_key(items, key):
    return {(txt(i, key) if key == "package" else num(i, key)): i for i in items
            if (txt(i, key) if key == "package" else num(i, key) is not None)}


def package_row(snap, p, over, styles):
    key, state = txt(p, "key"), txt(p, "state", "?")
    iss = nums(p, "issues")
    it = by_key(lst(snap, "running"), "package").get(key) if key else None
    mark, word = run_status(it) if it is not None and state not in ("accept", "needs-you", "refused", "merged", "closed") \
        else STATE.get(state, (RUN, state))
    waits = [waiting(txt(i, "waits_on")) for i in lst(over, "issues") if num(i, "issue") in iss and txt(i, "waits_on")]
    waits += [waiting(txt(q, "waits_on")) for q in lst(snap, "queue") if key and txt(q, "package") == key
              and txt(q, "waits_on")]
    deps = [d for d in p.get("depends_on", []) if isinstance(d, str)] if isinstance(p.get("depends_on"), list) else []
    if state == "accept":
        wait = "your accept"
    elif state == "blocked" and deps:
        wait = ", ".join(deps)
    elif waits:
        wait = waits[0]
    else:
        wait = ready_wait(snap) if (mark, word) == (NEXT, "ready") else ""
    return [Text(txt(p, "name", "?"), style=styles.get(key, "bold")), Text(" ".join("#%d" % n for n in iss)),
            Text(risk_of(p), style="dim"), status(mark, word, num(p, "pr")), Text(wait)]


def risk_of(p):
    r, e = txt(p, "risk"), txt(p, "risk_effective")
    return r if not e or e == r else "%s→%s" % (r or "?", e)


def loose_rows(snap, loose, detail, styles):
    """The issues outside a package, a row per status (a group of one: its title)."""
    running = by_key(lst(snap, "running"), "issue")
    groups = {}
    for i in loose:
        s = txt(i, "status") or "blocked"
        it = running.get(num(i, "issue")) if s == "running" else None
        mw = run_status(it) if it is not None else ISSUE.get(s, (WAIT, s))
        groups.setdefault(mw, []).append(i)
    rows = []
    for (mark, word), items in sorted(groups.items(), key=lambda g: ORDER.index(g[0][0]) if g[0][0] in ORDER else 9):
        if mark == WAIT and not detail:
            continue
        one = items[0] if len(items) == 1 else None
        title = txt(one, "title") if one is not None else ""
        name = Text(title, style=styles.get(num(one, "issue"), "")) if title else Text("(no package)", style="dim")
        if mark == YOU and word == "accept":
            wait = "your accept"
        elif (mark, word) == (NEXT, "ready"):
            wait = ready_wait(snap)
        else:
            wait = counted([waiting(txt(i, "waits_on")) for i in items])
        rows.append([name, Text(issue_list([num(i, "issue") for i in items])), Text(""), status(mark, word), Text(wait)])
    return rows


def running_styles(snap):
    """{package key or issue: the issue's own colour} of what runs now."""
    out = {}
    for it in lst(snap, "running"):
        if num(it, "color") is None:
            continue
        if num(it, "issue") is not None:
            out[num(it, "issue")] = issue_style(it)
        if txt(it, "package"):
            out[txt(it, "package")] = issue_style(it)
    return out


def current_rows(snap, st, over, detail):
    plan = obj(st, "plan")
    packages = lst(plan, "packages")
    styles = running_styles(snap)
    rows = [package_row(snap, p, over, styles) for p in packages]
    seen = {n for p in packages for n in nums(p, "issues")}
    by_n = {num(i, "issue"): i for i in lst(over, "issues") if num(i, "issue") is not None}
    loose = [by_n[n] for n in by_n if n not in seen]
    loose += [{"issue": n, "status": "blocked", "waits_on": "left out of the plan"}
              for n in nums(plan, "left_out") if n not in seen and n not in by_n]
    rows += loose_rows(snap, loose, detail, styles)
    if not rows and (txt(st, "phase") == "planning"
                     or any(txt(it, "pipeline") == "plan" for it in lst(snap, "running"))):
        rows.append([Text("plan"), Text(""), Text(""), status(RUN, "planning"), Text("")])
    h = obj(st, "health")
    hs = {"pending": (WAIT, "later", "the work above"), "running": (RUN, "working", ""),
          "merged": (DONE, "merged", ""), "closed": (DONE, "closed", "")}.get(txt(h, "state"))
    if hs:
        rows.append([Text("health pass"), Text(""), Text(""), status(hs[0], hs[1], num(h, "pr")), Text(hs[2])])
    cp = obj(st, "checkpoint")
    if num(cp, "issue") is not None:
        mark, word, wait = (YOU, "needs you", "your go") if cp.get("waiting") is True else \
            (DONE, "done", "") if txt(cp, "state") == "closed" else (WAIT, "later", "the work above")
        rows.append([Text("checkpoint"), Text("#%d" % num(cp, "issue")), Text(""), status(mark, word), Text(wait)])
    return rows


def step_head(title, place, over, st=None):
    t = Text(title, style="bold")
    t.append(" " + place, style="bold green" if place == "NOW" else "bold cyan")
    head = [t]
    if st is not None and txt(st, "track") == "parallel" and not title.lower().startswith("parallel"):
        head.append(Text("parallel track", style="dim"))
    if done_of(over):
        head.append(Text(done_of(over)))
    b = obj(st, "budget")
    if num(b, "usd") is not None:
        head.append(Text("$%.2f of $%s" % (num(b, "usd"), num(b, "limit") if num(b, "limit") is not None else "?"),
                         style="bold red" if b.get("over") is True else ""))
    if st is not None and txt(st, "phase") not in ("", "running"):
        head.append(Text("phase: " + txt(st, "phase"),
                         style="yellow" if txt(st, "phase") in ("needs-you", "checkpoint") else "dim"))
    return head


def next_and_later(snap):
    """(next steps as overview items, later steps as (title, open, closed), open parallel-track work).
    From the step overview; a schema-2 snapshot without it: from the milestones."""
    view = lst(snap, "step_overview")
    if view:
        nxt = [o for o in view if txt(o, "place") == "next"]
        later = [(txt(o, "title", "?"), num(o, "work_open") or 0, num(o, "work_closed") or 0)
                 for o in view if txt(o, "place") == "later" and txt(o, "track") != "parallel"]
        par = sum(num(o, "work_open") or 0 for o in view if txt(o, "track") == "parallel" and txt(o, "place") != "current")
        return nxt, later, par
    ms = lst(snap, "milestones")
    titles = [txt(m, "title") for m in ms]
    main = [txt(s, "title") for s in lst(snap, "steps") if s.get("current") is True and txt(s, "track") == "main"]
    at = titles.index(main[0]) + 1 if main and main[0] in titles else len(titles)
    rest = [m for m in ms[at:] if not txt(m, "title").lower().startswith("parallel tracks")]
    nxt = [{"title": txt(m, "title"), "work_open": num(m, "open") or 0, "work_closed": num(m, "closed") or 0}
           for m in rest[:1]]
    return nxt, [(txt(m, "title", "?"), num(m, "open") or 0, num(m, "closed") or 0) for m in rest[1:]], 0


def step_sections(snap, detail=True):
    """[{head: [Text] (the Step cell), rows: [[Work, Issues, Risk, Status, Waiting on]]}]: the
    current steps (the main track first), then the next step."""
    view = lst(snap, "step_overview")
    current = [s for s in lst(snap, "steps") if s.get("current") is True]
    current.sort(key=lambda s: txt(s, "track") != "main")
    out = []
    for st in current:
        over = next((o for o in view if num(o, "milestone") == num(st, "milestone")), {})
        out.append({"head": step_head(txt(st, "title", "?"), "NOW", over, st),
                    "rows": current_rows(snap, st, over, detail)})
    for o in next_and_later(snap)[0]:
        issues = [i for i in lst(o, "issues") if num(i, "issue") is not None]
        rows = loose_rows(snap, issues, detail, running_styles(snap))
        if not issues and not (num(o, "work_open") or 0):
            rows = [[Text("no issues yet", style="dim"), Text(""), Text(""), Text(""), Text("")]]
        out.append({"head": step_head(txt(o, "title", "?"), "NEXT", o), "rows": rows})
    return out


def later_line(snap):
    """4 Sharing (5) · 5 Export (4) · 8–11 empty: a run of empty numbered steps as a range; the
    parallel tracks when they have open work."""
    _, later, par = next_and_later(snap)
    parts, run = [], []

    def flush():
        if len(run) > 1:
            parts.append("%s–%s empty" % (run[0][0], run[-1][0]))
        elif run:
            parts.append("%s empty" % run[0][1])
        run.clear()
    for title, k, closed in later:
        m = re.match(r"(\d+)\b", title)
        if not k and not closed and m:
            run.append((m.group(1), title))
            continue
        flush()
        parts.append("%s (%s)" % (title, k if k else "all closed" if closed else "empty"))
    flush()
    if par:
        parts.append("Parallel tracks (%d)" % par)
    return " · ".join(parts)


def fast_units(snap):
    """The fast lane's units: running ones (no package) and the needs-you ones parked on a stage."""
    skip = other_keys(snap)
    run = [it for it in lst(snap, "running") if not txt(it, "package") and num(it, "issue") is not None
           and not (txt(it, "key") and txt(it, "key") in skip)]
    parked = [it for it in lst(snap, "needs_you") if not txt(it, "package") and txt(it, "stage")
              and num(it, "issue") is not None]
    return run, parked


def fast_rows(snap):
    """[[Issue, Title, PR, Status, Waiting on]]: the fast lane's running, parked and queued issues."""
    run, parked = fast_units(snap)
    rows, seen = [], set()

    def row(it, mark, word, wait):
        seen.add(num(it, "issue"))
        pr = num(it, "pr")
        rows.append([Text("#%d" % num(it, "issue"), style=issue_style(it)), Text(txt(it, "title")),
                     Text("#%d" % pr if pr is not None else "–", style="" if pr is not None else "dim"),
                     status(mark, word), Text(wait)])
    for it in run:
        row(it, *run_status(it), "")
    for it in parked:
        word, wait = PARKED.get(txt(it, "kind"), ("needs you", ""))
        row(it, YOU, word, wait)
    for q in lst(snap, "queue"):
        if txt(q, "lane") not in ("", "fast") or num(q, "issue") is None or num(q, "issue") in seen:
            continue
        if q.get("blocked") is True:
            row(q, WAIT, "blocked", waiting(txt(q, "waits_on")))
        else:
            row(q, NEXT, "queued", ready_wait(snap))
    return rows


# ------------------------------------------------------------------ drawing

def render_lines(renderable, width):
    """The renderable as Text lines of at most width cells (rich draws, the frame counts lines)."""
    con = Console(file=io.StringIO(), width=width, force_terminal=True, color_system="truecolor")
    out = []
    for segs in con.render_lines(renderable, con.options.update_width(width), pad=False):
        t = Text()
        for s in segs:
            if not s.control:
                t.append(s.text, s.style)
        t.rstrip()
        out.append(t)
    return out


def col_widths(cols, rows, width, header):
    """The columns' widths when the table is wider than width: the widest column gives up a cell
    at a time, never below its longest word; the text columns (FLEX) first, down to 16 cells. None
    (rich's own) when it fits, or when the words do not: rich would break a name in the middle."""
    room = width - 3 * len(cols) - 1
    cells = [[c.plain for c in col] + ([h] if header else []) for h, col in zip(cols, zip(*rows))] if rows else []
    mx = [max(len(x) for cell in col for x in cell.split("\n")) for col in cells]
    mn = [max([len(w) for cell in col for w in cell.split()] or [0]) for col in cells]
    if not cells or sum(mx) <= room or sum(mn) > room:
        return None
    w = list(mx)
    for floor in ([max(b, 16) if c in FLEX else a for a, b, c in zip(mx, mn, cols)], mn):
        while sum(w) > room and any(a > b for a, b in zip(w, floor)):
            k = max((j for j in range(len(w)) if w[j] > floor[j]), key=lambda j: w[j])
            w[k] -= 1
    return w


def table(cols, sections, width, header=True):
    """A box table (┌─┬─┐) of the sections' rows, a line between sections; the columns wrap, never cut."""
    t = Table(box=box.SQUARE, show_header=header, header_style="bold", expand=False)
    ws = col_widths(cols, [r for rows in sections for r in rows], width, header)
    for k, c in enumerate(cols):
        t.add_column(c, overflow="fold", width=ws[k] if ws else None)
    for k, rows in enumerate(sections):
        for j, r in enumerate(rows):
            t.add_row(*r, end_section=j == len(rows) - 1 and k < len(sections) - 1)
    return render_lines(t, width)


def spanning(lines, label, text):
    """The table with one more row: label in the first column, text across the others (the later steps)."""
    bottom = lines[-1].plain if lines else ""
    p0, n = bottom.find("┴"), len(bottom)
    if not bottom.startswith("└") or p0 < 0 or n - p0 - 4 < 10:
        return lines + wrap(line(("  " + label + "  ", "bold"), text), n or 40, 4)
    out = lines[:-1] + [Text("├" + bottom[1:p0] + "┼" + bottom[p0 + 1:n - 1] + "┤")]
    for k, piece in enumerate(wrap(Text(text), n - p0 - 4)):
        t = Text("│ ")
        t.append((label if k == 0 else "").ljust(p0 - 3), style="bold")
        t.append(" │ ")
        t.append_text(piece)
        t.append(" " * (n - p0 - 4 - len(piece.plain)) + " │")
        out.append(t)
    return out + [Text("└" + "─" * (p0 - 1) + "┴" + "─" * (n - p0 - 2) + "┘")]


def step_cell(head, j, n):
    """Row j's part of the Step cell: a line of it per row, the rest in the last row."""
    if j < n - 1:
        return head[j] if j < len(head) else Text("")
    return Text("\n").join(head[j:])


def fast_table(snap, width):
    rows = fast_rows(snap)
    if not rows:
        return []
    cols = FAST_COLS if any(r[4].plain for r in rows) else FAST_COLS[:4]
    return table(cols, [[r[:len(cols)] for r in rows]], width)


def title_line(name, snap, width):
    t = line(("ROADMAP  ", "bold"), (name, "bold"), (" · " + txt(snap, "repo", "?"), "dim"))
    if not has_steps(snap) and not lst(snap, "milestones"):
        t.append(" · no steps", style="dim")
        if not fast_rows(snap):
            t.append(" · nothing running or queued", style="dim")
    return wrap(t, width, 2)


def roadmap(name, snap, width, detail=True, headers_only=False, phone=False):
    """The project's roadmap, as lines of at most width cells."""
    if snap is None:
        return [Text("ROADMAP  %s: no snapshot" % name, style="dim")]
    rows = title_line(name, snap, width)
    if not has_steps(snap):
        if headers_only:
            return rows
        if lst(snap, "milestones"):
            rows += [cut(x, width) for x in bars(snap)]
        return rows + fast_table(snap, width)
    secs = step_sections(snap, detail)
    if not lst(snap, "steps") or not any(s.get("current") is True for s in lst(snap, "steps")):
        rows.append(Text("  no current step", style="dim"))
    if headers_only:
        lead = Text("" if phone else "  ")
        return rows + [x for s in secs for x in wrap(lead + Text(" · ").join(s["head"]), width, 4)]
    later = later_line(snap) if detail else ""
    if phone:
        for k, s in enumerate(secs):
            rows += wrap(Text(" · ").join(s["head"]), width, 2)
            rows += table(STEP_COLS[1:], [s["rows"]], width, header=k == 0) if s["rows"] else []
        if later:
            rows += wrap(line(("Later ", "bold"), later), width, 2)
    elif secs:
        lines = table(STEP_COLS, [[[step_cell(s["head"], j, len(s["rows"] or [0]))] + r
                                   for j, r in enumerate(s["rows"] or [[Text("")] * 5])] for s in secs], width)
        rows += spanning(lines, "Later", later) if later else lines
    elif later:
        rows += wrap(line(("  Later  ", "bold"), later), width, 4)
    fast = fast_table(snap, width)
    if fast:
        rows += [Text("  fast lane", style="bold")] + fast
    return rows


def bars(snap):
    """The roadmap before steps (schema 1): a bar per milestone, ◆ per checkpoint."""
    items = lst(snap, "milestones")
    rows = []
    name_w = min(28, max([len(txt(m, "title")) for m in items] or [0]))
    for m in items:
        o, c = num(m, "open") or 0, num(m, "closed") or 0
        total = o + c
        filled = round(16 * c / total) if total else 0
        t = Text("  ")
        title = txt(m, "title")
        t.append((title if len(title) <= name_w else title[:name_w - 1] + "…").ljust(name_w) + " ")
        t.append("█" * filled, style="green")
        t.append("░" * (16 - filled), style="bright_black")
        t.append(" %d/%d" % (c, total))
        for cp in lst(m, "checkpoints"):
            st = "green" if txt(cp, "state") == "closed" else "bold yellow" if cp.get("ready") is True else "dim"
            t.append(" ◆#%s" % num(cp, "issue"), style=st)
        rows.append(t)
    return rows
