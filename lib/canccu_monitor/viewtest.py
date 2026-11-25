# SPDX-License-Identifier: AGPL-3.0-or-later
"""The self-test's checks of the views (#37): every view of the mockup and of every fixture at
each size (no exception, no line wider or more lines than the terminal, the strip on line 1, the
view bar on the last with the right tab marked); the Summary's sections, drop order and phone
form; the Projects tables, focus and scrolling; the Roadmap through the view; the Activity's
order, folding, failures, notes and runs table."""
import copy
import io
import os
import re

from rich.console import Console

from .data import load
from .views import NAMES, State, render_view, view_bar

SIZES = ((160, 60), (120, 40), (100, 40), (80, 30), (60, 20))
MOCK_NOW = 1920232860
NOW = 1920110430
LONG_TITLE = ("Make the search box remember the last ten queries per user and offer them as suggestions while "
              "typing, ranked by how often and how lately each was used, with a way to clear them one by one")


def shot(projects, st, w, h, now=MOCK_NOW, no_color=False):
    """(plain lines, raw output) of one frame of the view."""
    con = Console(file=io.StringIO(), width=w, force_terminal=True, color_system="256", record=True,
                  no_color=no_color)
    con.print(render_view(st, projects, now, w, h))
    plain = con.export_text()
    return plain.rstrip("\n").split("\n"), con.file.getvalue()


def words(lines):
    return " ".join(" ".join(lines).split())


def mock_projects(mock):
    return [("tools", mock["tools"]), ("web", mock["web"])]


def every_view_checks(projects, label, check, now=MOCK_NOW):
    for w, h in SIZES:
        for k, name in enumerate(NAMES):
            what = "%s %s at %dx%d" % (label, name, w, h)
            try:
                lines, _ = shot(projects, State(view=k), w, h, now)
            except Exception as e:  # the one thing the monitor must never do
                check(False, "%s: %s: %s" % (what, type(e).__name__, e))
                continue
            check(all(len(x) <= w for x in lines), what + ": a line is wider than the terminal")
            check(len(lines) <= h, what + ": %d lines for %d" % (len(lines), h))
            check(len(lines) == h, what + ": the view bar is not on the last line (%d lines)" % len(lines))
            check(projects[0][0] in lines[0], what + ": the strip is not on line 1")
            check("%d " % (k + 1) in lines[-1] and re.search(r"\[%d [A-Z]" % (k + 1), lines[-1]) is not None,
                  what + ": the bar does not mark the tab: %r" % lines[-1])
            check("q quit" in lines[-1], what + ": the bar has no q quit")


def strip_checks(mock, check):
    for w, h in SIZES:
        lines, _ = shot(mock_projects(mock), State(view=1), w, h)
        top = lines[0]
        what = "strip at %d" % w
        check("tools" in top and "web" in top and "✓" in top, what + ": the projects and their pass")
        if w >= 100:
            check("2/3" in top and "$81.81" in top and "5h 27%" in top and "week 58%" in top,
                  what + ": the slots, spend and usage: %r" % top)
        bar = lines[-1]
        check("✖3" in bar, what + ": no needs-you badge on the Summary tab: %r" % bar)
        check(("Projects" in bar) == (w > 80) and ("Proj" in bar), what + ": the short names at 80: %r" % bar)
        check("rotate off" in bar or w < 100, what + ": rotate off on the right: %r" % bar)
    one = copy.deepcopy(mock["web"])
    one.pop("usage", None)
    lines, _ = shot([("web", one)], State(view=1), 120, 40)
    check("usage unknown" in lines[0], "strip: no usage reads %r" % lines[0])


def summary_checks(mock, check):
    projects = mock_projects(mock)
    lines, raw = shot(projects, State(), 120, 60)
    text = "\n".join(lines)
    w = words(lines)
    order = [text.find(s) for s in ("NEEDS YOU", "NOW", "STEPS", "RECENT")]
    check(all(x >= 0 for x in order) and order == sorted(order), "summary: the sections are not in order %r" % order)
    check("today $81.81" in w and "5h ▰▰▱▱▱▱▱▱ 27%" in w, "summary: the full header")
    acc = next(x for x in lines if "ACCEPT" in x)
    check("web" in acc and "PR #240" in acc and "3h06m" in acc, "summary: the accept line %r" % acc)
    check(len([x for x in lines if x.lstrip().startswith("how:")]) == 3, "summary: a how: line under each item")
    check(any("#27" in x and "41/150 min" in x and "52/250 turns" in x for x in lines), "summary: a NOW line per run")
    check(any(x.strip().startswith("web") and "9 of 26" in x and "$23.85 of $300" in x for x in lines),
          "summary: the step line of web")
    check(any(x.strip().startswith("tools") and "no steps" in x for x in lines), "summary: the simple project's line")
    check("\x1b]8;" in raw and "pull/240" in raw, "summary: the accept's number is no link")
    # drop order: how:, RECENT, the legend, the blank lines; the needs-you lines never
    seen = []
    for h in range(60, 9, -1):
        lines, _ = shot(projects, State(), 120, h)
        check(len(lines) == h and all(len(x) <= 120 for x in lines), "summary at height %d: does not fit" % h)
        check(sum("ACCEPT" in x or "STUCK" in x for x in lines) == 3, "summary at height %d: a needs-you line dropped" % h)
        state = ("how:" in "\n".join(lines), "RECENT" in "\n".join(lines))
        seen.append(state)
    check(seen[0] == (True, True) and seen[-1] == (False, False), "summary: the drop order %r" % seen[::10])
    first_no_how = next(i for i, s in enumerate(seen) if not s[0])
    first_no_recent = next(i for i, s in enumerate(seen) if not s[1])
    check(first_no_how <= first_no_recent, "summary: RECENT drops before the how: lines")
    # cut with …: a long title on a run; never a number or an age
    own = copy.deepcopy(mock["tools"])
    own["running"][0]["title"] = LONG_TITLE
    lines, _ = shot([("tools", own), ("web", mock["web"])], State(), 100, 40)
    run = next(x for x in lines if "#27" in x and "min" in x)
    check(run.endswith("…") and "41/150 min" in run, "summary: a long title is not cut with …: %r" % run)
    # the phone form
    lines, _ = shot(projects, State(), 80, 30)
    check(all(not set(x) & set("┏┃┌│") for x in lines), "summary phone: a box or table")
    check(any("ACCEPT" in x for x in lines) and any("NOW" in x for x in lines), "summary phone: the sections")


def projects_checks(mock, check):
    projects = mock_projects(mock)
    web = copy.deepcopy(mock["web"])
    web["steps"][0]["plan"]["wave"] = 8
    web["steps"][0]["plan"]["packages"][1]["carried_from"] = 6
    own = copy.deepcopy(mock["tools"])
    own["running"][0]["title"] = LONG_TITLE
    own["other_runs"] = [{"repo": own["repo_name"], "key": "77", "kind": "work", "started": MOCK_NOW - 600}]
    ps = [("tools", own), ("web", web)]
    lines, raw = shot(ps, State(view=1), 160, 200)
    w = words(lines)
    check(sum(x.startswith("━━ ") for x in lines) == 2, "projects: not one head line per project")
    check(re.search(r"━━ tools · example-user/tools · pass .* · runs \d+ of \d+ · today \$17\.64 · queue 0 ━", w)
          is not None, "projects: the head line %r" % next((x for x in lines if x.startswith("━━ tools")), ""))
    check(all(c in w for c in ("Run", "Kind", "Stage", "Age", "Turns", "Min", "Cost", "Title")), "projects: the runs header")
    run = next(x for x in lines if "#27" in x and "work" in x)
    check(run.endswith("…") and "–" in run, "projects: a cut title ends in …, a live run's cost is –: %r" % run)
    check(any("other" in x and "77" in x for x in lines), "projects: a run by hand as Kind other")
    check(all(c in w for c in ("Package", "Issues", "Risk", "Wave", "Status", "Waiting on")), "projects: the packages header")
    check(any("search-box" in x and "6→8" in x for x in lines), "projects: a carried package's wave")
    check(any("ACCEPT" in x and "PR #240" in x for x in lines), "projects: the awaiting-accept line")
    check(sum("…" in x for x in lines) == 1, "projects: something else than the title is cut")
    # the focus: all → tools → web → all
    st = State(view=1)
    heads = []
    for _ in range(4):
        lines, _ = shot(ps, st, 160, 200)
        heads.append(sum(1 for x in lines if "Package" in x or ("Run" in x and "Kind" in x)))
        st.key("p", len(ps), 40)
    check(heads[0] == 2 and heads[1] < heads[0] and heads[2] < heads[0] and heads[3] == heads[0],
          "projects: the focus cycle %r" % heads)
    # scrolling clamps
    st = State(view=1)
    for _ in range(500):
        st.key("down", len(ps), 20)
    lines, _ = shot(ps, st, 120, 20)
    full, _ = shot(ps, State(view=1), 120, 400)
    body = len([x for x in full[1:-1] if x.strip()])
    check(st.scroll[1] <= body and lines[-2].strip(), "projects: scrolling past the end %d" % st.scroll[1])
    st.key("home", len(ps), 20)
    check(st.scroll[1] == 0, "projects: Home")
    st.key("end", len(ps), 20)
    shot(ps, st, 120, 20)
    end = st.scroll[1]
    st.key("pgup", len(ps), 20)
    check(st.scroll[1] < end, "projects: PgUp")
    lines, _ = shot(ps, State(view=1), 80, 30)
    check(all(not set(x) & set("┏┃┌│") for x in lines), "projects phone: a box or table")


def roadmap_view_checks(mock, check):
    projects = mock_projects(mock)
    lines, raw = shot(projects, State(view=2), 130, 300)
    text = "\n".join(lines)
    w = words(lines)
    check("ROADMAP web" in w and "ROADMAP tools" in w, "roadmap view: a roadmap per project")
    check("no steps (simple workflow)" in w, "roadmap view: the simple project")
    check("…" not in text, "roadmap view: a cell is cut")
    check("│ Later" in text and "13 issues" in w, "roadmap view: not at full detail")
    check("● running" in w and "✓ done" in w, "roadmap view: no legend")
    lines, _ = shot(projects, State(view=2), 80, 300)
    check(all(not set(x) & set("┏┃┌│") for x in lines), "roadmap view phone: a box or table")
    check(any("search-box" in x and "accept" in x for x in lines), "roadmap view phone: the package line")


def activity_checks(mock, fx, check):
    projects = mock_projects(mock)
    lines, raw = shot(projects, State(view=3), 120, 300)
    text = "\n".join(lines)
    w = words(lines)
    check(re.search(r"today · .*web \$64\.17.*needs you 3", w) is not None, "activity: the today line")
    check("RUNS ENDED TODAY" in w and "finished[]" in w, "activity: the runs line without finished[]")
    ev = [x for x in lines if re.match(r"\s*(\w+ )?\d\d:\d\d", x)]
    times = [re.search(r"\d\d:\d\d", x).group(0) for x in ev]
    check(times == sorted(times, reverse=True) and len(times) > 5, "activity: events not newest first %r" % times)
    check("×59" in w, "activity: the repeat is not folded")
    check(any("⚠" in x and "failed" in x for x in lines), "activity: no ⚠ on a failure")
    check("Roadmap note:" in w, "activity: the roadmap note is not among the events")
    check("tools" in text and "web" in text, "activity: not every project's events")
    check("…" not in text, "activity: something is cut")
    check("\x1b]8;" in raw, "activity: a URL is no link")
    web = copy.deepcopy(mock["web"])
    web["steps"][0]["notes"].append({"at": MOCK_NOW - 60, "kind": "follow-up", "pr": 240, "text": "split the index"})
    web["finished"] = [{"key": "pkg-2-search-box", "issue": 212, "kind": "review", "ended": MOCK_NOW - 120,
                        "minutes": 7, "turns": 12, "cost_usd": 1.25, "outcome": "done"},
                       {"key": "24", "issue": 24, "kind": "worker", "ended": MOCK_NOW - 3600, "minutes": 40,
                        "turns": 60, "cost_usd": None, "outcome": "stopped"}]
    lines, _ = shot([("tools", mock["tools"]), ("web", web)], State(view=3), 120, 300)
    w = words(lines)
    check("Follow-up: split the index" in w, "activity: the follow-up is not among the events")
    check(all(c in w for c in ("Ended", "Project", "Run", "Kind", "Min", "Turns", "Cost", "Outcome")),
          "activity: the runs table's header")
    r1 = next((x for x in lines if "$1.25" in x), "")
    check("review" in r1 and "done" in r1 and "web" in r1, "activity: the finished run %r" % r1)
    check(any("stopped" in x and "–" in x for x in lines), "activity: a run without a cost")
    check("finished[]" not in w, "activity: the missing-field line with the field there")
    lines, _ = shot([("tools", mock["tools"]), ("web", web)], State(view=3), 80, 300)
    check(all(not set(x) & set("┏┃┌│") for x in lines), "activity phone: a box or table")


QUEUE_ORDER = [20, 21, 22, 23, 31, 30, 32, 40, 50, 51, 60, 61]


def queue_checks(fx, check):
    """The Queue view (#293): every open issue once, in take order, at both widths; scrolling to
    the last line; an older snapshot without unscheduled[]."""
    snap, _ = load(os.path.join(fx, "queue.json"))
    for w in (120, 60):
        lines, _ = shot([("web", snap)], State(view=4), w, 100)
        seen = [int(m) for m in re.findall(r"^ +\S #(\d+)", "\n".join(lines), re.M)]
        check(seen == QUEUE_ORDER, "queue at %d: the issues %r" % (w, seen))
        check(all(len(x) <= w for x in lines), "queue at %d: a line is wider" % w)
        names = ["Running", "Needs you", "Queue", "3 Events · NOW", "4 Payments · NEXT", "5 Reports · LATER", "Not scheduled"]
        check([x.strip() for x in lines if x.strip() in names] == names, "queue at %d: the sections" % w)
    wide, _ = shot([("web", snap)], State(view=4), 120, 100)
    check(sum("#21 " in x for x in wide) == 1, "queue: an issue listed twice in one section shows once")
    check(any("#22" in x and " list" in x and "104" not in x for x in wide),
          "queue: a single-issue package shows its name, not its issue number")
    longt = dict(snap, step_overview=[dict(o, title="5 A very long step title that certainly will not fit on one line of a phone-width screen at all")
                                      if o.get("place") == "later" else o for o in snap["step_overview"]])
    lines, _ = shot([("web", longt)], State(view=4), 60, 100)
    check(all(len(x) <= 60 for x in lines) and any("LATER" in x for x in lines), "queue: a long step title wraps and keeps LATER")
    check(any("#23" in x and "blocked" in x for x in wide), "queue: a blocked issue keeps its place, marked blocked")
    check(any(x.startswith("Not scheduled") for x in wide), "queue: no Not scheduled section")
    untitled = dict(snap, step_overview=[{k: v for k, v in o.items() if k != "title"} if o.get("place") == "later" else o
                                         for o in snap["step_overview"]],
                    needs_you=[{"issue": 77, "title": "Unknown kind", "kind": "odd", "url": "u"}])
    lines, _ = shot([("web", untitled)], State(view=4), 120, 100)
    later = [o["milestone"] for o in snap["step_overview"] if o.get("place") == "later"][0]
    check(any(x.strip() == "step %d · LATER" % later for x in lines), "queue: a step without a title keeps its number")
    check(any("#77" in x and x.rstrip().endswith("your decision") for x in lines),
          "queue: a needs-you item of an unknown kind says your decision")
    old = {k: v for k, v in snap.items() if k != "unscheduled"}
    lines, _ = shot([("web", old)], State(view=4), 120, 100)
    check(not any(x.startswith("Not scheduled") for x in lines) and any("#50" in x for x in lines),
          "queue: a snapshot without unscheduled[]")
    lines, _ = shot([("web", dict(old, running=[], needs_you=[], queue=[], step_overview=[]))], State(view=4), 120, 20)
    check(any("no open issues" in x for x in lines), "queue: nothing open has no line")
    long = dict(snap, unscheduled=[{"issue": 100 + k, "title": "Idea %d" % k, "url": "u"} for k in range(40)])
    st = State(view=4)
    st.key("end", 1, 11)
    lines, _ = shot([("web", long)], st, 120, 12)
    check(any("#139" in x for x in lines), "queue: End does not show the last issue")
    st.key("home", 1, 11)
    lines, _ = shot([("web", long)], st, 120, 12)
    check(any("QUEUE" in x for x in lines), "queue: Home does not show the top")


def bar_checks(check):
    """The view bar keeps its last hint whole at every width a long-name bar nearly fills (81 to 84), also with 12 needs-you items."""
    for needs in (2, 12):
        for w in range(60, 131):
            bar = view_bar(State(view=0), needs, w).plain
            check(len(bar) <= w and bar.rstrip().endswith("q quit") or "rotate" in bar,
                  "bar at %d, %d needs-you: the last hint is cut: %r" % (w, needs, bar))


def view_checks(mock, fx, check):
    every_view_checks(mock_projects(mock), "mockup", check)
    for f in sorted(os.listdir(fx)):
        if f.endswith(".json"):
            snap, err = load(os.path.join(fx, f))
            if snap is not None:
                every_view_checks([("web", snap)], f, check, NOW)
    strip_checks(mock, check)
    summary_checks(mock, check)
    projects_checks(mock, check)
    roadmap_view_checks(mock, check)
    activity_checks(mock, fx, check)
    queue_checks(fx, check)
    bar_checks(check)
    one = [("web", mock["web"])]
    every_view_checks(one, "one project", check)
    lines, _ = shot(one, State(view=1), 120, 100)
    check(sum(x.startswith("━━ ") for x in lines) == 1, "one project: not one block")
    plain, _ = shot(mock_projects(mock), State(), 120, 40, no_color=True)
    colour, _ = shot(mock_projects(mock), State(), 120, 40)
    check(plain == colour, "NO_COLOR: the text differs")
