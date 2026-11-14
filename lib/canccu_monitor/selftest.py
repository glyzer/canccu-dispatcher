# SPDX-License-Identifier: AGPL-3.0-or-later
"""canccu-monitor --self-test: offline checks of the "Inbox First" layout and of every fixture.

The mockup (tests/fixtures/monitor/inbox/: the project tools with the project web beside it, an
invented evening at Wed 06 Nov 2030 22:01 UTC) at 120×55, 140×65, 100×40, 80×30 and 60×30, then
every height from 65 down to 12 for the drop order; 8 needs-you items; an empty state; a folded
repeat; CI with no checks; NO_COLOR; the roadmap tables at 130 and 80 columns; a step with many
blocked issues and done packages (blocked-many.json) fitted at 120×55 and 80×30. Then every fixture
in tests/fixtures/monitor/ at 60, 100 and 160 columns, and a few redraws through Display. Prints
one FAIL line per failed check."""
import copy
import io
import json
import os
import re
import time

from rich.console import Console

from .data import load
from .draw import render
from .parts import PHONE_UPTO, fold_events
from .roadmap import fast_rows, later_line, step_sections
from .screen import ALT_OFF, ALT_ON, HIDE, SHOW, SYNC_OFF, SYNC_ON, Display, live

NOW = 1920110430  # 30 s after the fixtures' pass (2030-11-05 12:00:00 UTC)
MOCK_NOW = 1920232860  # the mockup's clock: Wed 06 Nov 2030 22:01 UTC
ANSI = re.compile(r"\x1b\[[0-9;]*m")
OSC8 = re.compile(r"\x1b\]8;[^\x1b]*\x1b\\")
# another project beside each fixture (whose project is web), for the one view of all projects
TOOLS = {"schema": 2, "project": "tools", "repo": "example-user/tools",
         "needs_you": [{"kind": "accept", "issue": 7, "pr": 8, "reason": "manual: x",
                        "url": "https://github.com/example-user/tools/pull/8"},
                       {"kind": "question", "issue": 9, "reason": "a question",
                        "url": "https://github.com/example-user/tools/issues/9"}],
         "running": [{"key": "11", "issue": 11, "kind": "work", "pipeline": "work", "title": "Tidy the help text",
                      "color": 33}],
         "steps": [{"milestone": 3, "title": "1 Basics", "track": "main", "current": True, "wave": 4, "plan": None}],
         "step_overview": [{"milestone": 3, "title": "1 Basics", "place": "current", "work_open": 2, "work_closed": 1,
                            "issues": [{"issue": 11, "title": "Tidy the help text", "status": "running"}]}]}
SIZES = ((120, 55), (140, 65), (100, 40), (80, 30), (60, 30))
PIPE_24 = "work ✓ › CI ∅ no checks › review ✓ changes › fix ✓ › fix-check ◉ 3/20 min · 4/30 turns › merge ○"
PIPE_27 = "work ◉ 41/150 min · 52/250 turns › CI ○ › review ○ › fix ○ › fix-check ○ › merge ○"
URLS = ()  # the cards' URLs, from the fixtures (inbox_checks)


def flat(s):
    return "".join(s.split())


def words_of(s):
    """The words of a frame, the box's sides left out (a wrapped card reads as one line)."""
    return " ".join(s.replace("┃", " ").split())


def frame(snap, err, width, height=None, other=(), no_color=False, now=NOW, name=None):
    """(plain text, raw output with colour codes and links) of one frame."""
    con = Console(file=io.StringIO(), width=width, force_terminal=True, color_system="256",
                  no_color=no_color, record=True)
    con.print(render(snap, err, now, width, list(other), name, height))
    return con.export_text(), con.file.getvalue()


def line_of(plain, raw, text):
    """The raw line (with its colour codes) of the first plain line that holds text."""
    rl = raw.split("\n")
    for i, p in enumerate(plain.split("\n")):
        if text in p and i < len(rl):
            return rl[i]
    return ""


def self_test():
    os.environ["TZ"] = "UTC"  # the mockup's clock times
    time.tzset()
    here = os.path.dirname(os.path.realpath(__file__))
    fx = os.path.join(here, "..", "..", "tests", "fixtures", "monitor")
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)

    global URLS
    mock = {n: load(os.path.join(fx, "inbox", n + ".json"))[0] for n in ("tools", "web")}
    URLS = tuple(it["url"] for n in ("web", "tools") for it in mock[n]["needs_you"])
    inbox_checks(mock, check)
    drop_order_checks(mock, check)
    many_checks(mock, check)
    empty_checks(check)
    ci_checks(mock, check)
    review_checks(mock, check)
    fixture_checks(fx, check)
    roadmap_checks(mock, check)
    blocked_checks(fx, check)
    screen_checks(fx, check)
    version_checks(mock, check)
    owner_checks(mock, check)
    for f in fails:
        print("FAIL " + f)
    print("canccu-monitor self-test: %d checks failed" % len(fails) if fails else "canccu-monitor self-test: ok")
    return 1 if fails else 0


def mock_frame(mock, w, h, no_color=False, own=None):
    return frame(own or mock["tools"], None, w, h, [("web", mock["web"])], no_color, MOCK_NOW, "tools")


def version_checks(mock, check):
    """The header names the release each dispatcher runs: one version when all run the same, the
    other projects' own when they differ (a dispatcher not restarted after an upgrade), nothing
    from a snapshot without the field (an older dispatcher)."""
    tools, web = (copy.deepcopy(mock[n]) for n in ("tools", "web"))
    for w, _ in SIZES:
        what = "version at %d columns" % w
        tools["version"] = web["version"] = "1.2.3"
        plain = words_of(mock_frame({"tools": tools, "web": web}, w, 40)[0])
        check("v1.2.3" in plain and "web v1.2.3" not in plain, what + ": the one version, once")
        web["version"] = "1.2.0"
        plain = words_of(mock_frame({"tools": tools, "web": web}, w, 40)[0])
        check("v1.2.3" in plain and "web v1.2.0" in plain, what + ": the other project's own version")
    plain = words_of(mock_frame(mock, 120, 40)[0])
    check(not re.search(r"\bv\d+\.\d+", plain), "version: a snapshot without one shows none")


def inbox_checks(mock, check):
    """The mockup at each size: what each section says, whole. The words of the project web (the
    other project) are read from its fixture."""
    acc = mock["web"]["needs_you"][0]
    pv, pk = mock["web"]["steps"][0]["plan"]["packages"]
    repo = mock["web"]["repo"]
    ready = [i for i in mock["web"]["step_overview"][1]["issues"] if i["status"] == "ready"]
    step2, step3 = (o["title"] for o in mock["web"]["step_overview"][1:3])
    for w, h in SIZES:
        what = "mockup at %dx%d" % (w, h)
        try:
            plain, raw = mock_frame(mock, w, h)
        except Exception as e:  # the one thing the monitor must never do
            check(False, "%s: %s: %s" % (what, type(e).__name__, e))
            continue
        lines = plain.rstrip("\n").split("\n")
        words = words_of(plain)
        phone = w <= PHONE_UPTO
        check(all(len(x) <= w for x in lines), what + ": a line is wider than the terminal")
        check(len(lines) <= h, what + ": %d lines for a %d-line terminal" % (len(lines), h))
        for url in URLS:
            check(url in plain, what + ": the URL %s is not whole on one line" % url)
            check("\x1b]8;" in raw and url in raw, what + ": the URL %s is no OSC 8 link" % url)
        # the cards: oldest first, each with its verb, project, numbers, whole reason and age
        a, s22, s25 = plain.find("ACCEPT"), plain.find("STUCK"), plain.rfind("STUCK")
        check(0 <= a < s22 < s25, what + ": the cards are not oldest first (accept 18:55, #22 20:12, #25 21:34)")
        check("NEEDS YOU · 3" in plain, what + ": no NEEDS YOU title with the count")
        check(plain.find("NEEDS YOU") < plain.find("NOW") < plain.find("ROADMAP"), what + ": sections out of order")
        check("3h06m" in words and "1h49m" in words and "27m" in words, what + ": a card without its age")
        check("✖" in line_of(plain, raw, "NEEDS YOU") and "31m" in line_of(plain, raw, "NEEDS YOU"),
              what + ": NEEDS YOU is not a red ✖")
        if phone:
            head = lines[0] if w >= 80 else words_of(" ".join(lines[:2]))  # 2 lines below 80
            check("tools" in head and "web" in head and "slots 2/3" in head
                  and "$81.81" in head and "5h 27%" in head and "week 58%" in head,
                  what + ": the phone header is not one line (80 columns) with the projects, slots, spend and usage")
            check("ACCEPT web PR #240 (#212 +#213)" in words and acc["reason"] in words,
                  what + ": the phone accept card")
            check("STUCK tools #22 PR #29" in words and "CI still pending after 90 min" in words,
                  what + ": the phone stuck card (short reason)")
            i = next((k for k, x in enumerate(lines) if "ACCEPT" in x), -1)
            check(i >= 0 and URLS[0] in "".join(lines[i + 1:i + 3]), what + ": the phone card's URL is not under it")
            check("how:" not in plain, what + ": a phone card has a how: line")
            check("#24 fix-check ◉ 3/20 min · 4/30 turns" in words and "PR #31" in words and "∅ no checks" in words,
                  what + ": the phone NOW line of #24")
            check("#27 work ◉ 41/150 min · 52/250 turns" in words and "no PR yet" in words,
                  what + ": the phone NOW line of #27")
            check("ROADMAP web" in words and "%s NOW · 9 of 26 done" % step2 in words, what + ": the phone roadmap")
            continue
        check("today $81.81 · tools $17.64 · web $64.17" in words, what + ": spend per project in the header")
        check("5h ▰▰▱▱▱▱▱▱ 27% → 01:00" in words and "week ▰▰▰▰▰▱▱▱ 58% → Mon 09:00" in words,
              what + ": the usage bars with their resets")
        check("pass 1m ago ✓" in lines[0] and "web" in lines[0] and "slots 2/3" in lines[0]
              and "Wed 06 Nov 22:01" in lines[0], what + ": header line 1")
        check("┏" in plain and "┗" in plain and "┃" in line_of(plain, raw, "ACCEPT"), what + ": the box is not drawn")
        check("ACCEPT web PR #240 ← #212 +#213 · %s · waiting since 18:55 (3h06m)" % acc["reason"] in words,
              what + ": the accept card's line 1")
        check("how: label PR #240 accepted, or canccu-ship 212" in words
              and "pkg %s · step 2 · risk normal→high" % pk["name"] in words, what + ": the accept card's how")
        check(acc["title"] in words, what + ": the accept card's title")
        check("STUCK tools #22 → PR #29 · CI on PR #29 is still pending after 90 min · since 20:12 (1h49m) · stage CI ⚠"
              in words, what + ": the stuck card's line 1 (the whole reason)")
        check("how: look at the checks on PR #29" in words, what + ": the stuck card's how")
        check("https://github.com/example-user/tools/pull/29" in plain, what + ": the stuck card's PR URL")
        check("Retry downloads that time out" in words, what + ": the stuck card's title")
        check("NOW · running 2 of 3" in words, what + ": the NOW title")
        check("✓ done ◉ now ○ to come ⚠ stuck ∅ no checks ✖ you" in words, what + ": the legend")
        check("parked (needs you):" in words and "#22 PR #29 at CI ⚠" in words and "web PR #240 at merge ✖ accept" in words,
              what + ": the parked line")
        check("up next:" in words and "tools queue empty" in words and "web queue empty" in words,
              what + ": the up next line")
        check("ROADMAP web · %s" % repo in words and "ROADMAP tools · example-user/tools · no steps" in words,
              what + ": a roadmap per project with its repo")
        # the rest at full height: the roadmap's tables take more lines than 55, the drop order
        # (drop_order_checks) leaves some of it out at h
        plain, raw = mock_frame(mock, w, None)
        lines = plain.rstrip("\n").split("\n")
        words = words_of(plain)
        if w >= 120:  # the design width: each row on one line
            check(re.search(r"│ %s NOW +│" % step2, plain) is not None, what + ": the current step's cell")
            check(re.search(r"│ %s NEXT +│" % step3, plain) is not None, what + ": the next step's cell")
            check(re.search(r"│ %s +│ #212 #213 +│ normal→high +│ ✖ accept PR #240 +│ your accept +│" % pk["name"], plain)
                  is not None, what + ": the package row (issues, risk, status, waiting on)")
            check(re.search(r"│ %s +│ #211 +│ low +│ ✓ merged PR #238 +│" % pv["name"], plain) is not None,
                  what + ": the merged package")
        check("tools #27 no PR yet " + mock["tools"]["running"][0]["title"] in words, what + ": NOW line 1 of #27")
        check("tools #24 PR #31 " + mock["tools"]["running"][1]["title"] in words, what + ": NOW line 1 of #24")
        check(re.search(r"│ \(no package\) +│ %s +│ +│ ○ ready +│" % " ".join("#%d" % i["issue"] for i in ready), plain)
              is not None, what + ": the ready issues outside a package")
        check("health pass" not in words and "parallel tracks" not in words.lower() and "unplanned" not in words,
              what + ": a row with nothing to say")
        check(re.search(r"│ #27 +│ Add a dry-run flag", plain) is not None
              and re.search(r"│ #24 +│ Report the line of a bad config key +│ #31 +│ ● fix-check +│", plain) is not None
              and re.search(r"│ #22 +│ .* +│ #29 +│ ✖ needs you +│", plain) is not None, what + ": the fast lane's rows")
        check("RECENT" in plain and plain.find("RECENT") > plain.find("ROADMAP"), what + ": no RECENT under ROADMAP")
        check(not any("ROADMAP tools" in x and "ROADMAP web" in x for x in lines),
              what + ": the roadmaps are side by side")
        for text in (PIPE_24, PIPE_27):
            check(text in words, what + ": the pipeline %r" % text)
        check("[t52]" in plain and "…" in line_of(plain, raw, "[t52]"), what + ": the [tN] line is not there, cut with …")
        check("13 issues" in words and ("10 labelled blocked" in words or w < 120),  # it wraps below 120
              what + ": the blocked issues outside a package")
        check(re.search(r"│ Later +│ 4 Filters \(5\) · 5 Saved views \(3\)", plain) is not None, what + ": the later steps")
        rec = line_of(plain, raw, "×59")
        check("20:40–20:54" in rec and "⚠" in rec and "review post failed" in rec,
              what + ": the folded repeat (time range, ×59, ⚠)")
        check(0 <= plain.find("×59") < plain.find("web 18:05"), what + ": tools' events are not before web's")
        check("Roadmap note:" in words, what + ": the roadmap note is not in RECENT")
        check("https://" not in plain.split("RECENT")[-1], what + ": RECENT shows a line's link")
        # colours reinforce the glyphs
        check("32m" in line_of(plain, raw, "✓ merged"), what + ": ✓ merged is not green")
        check("33m" in line_of(plain, raw, "STUCK"), what + ": a stuck card is not yellow")
    plain, raw = mock_frame(mock, 120, 55)
    nc_plain, nc_raw = mock_frame(mock, 120, 55, no_color=True)
    check(nc_plain == plain, "NO_COLOR: not the same text")
    check(re.search(r"\x1b\[[0-9;]*3[0-7]m|38;5;", OSC8.sub("", nc_raw)) is None, "NO_COLOR: colour codes in the output")


VOCAB = "● running ○ can go next – blocked or later ✖ needs you ✓ done"
LONG = ("a long title that goes on and on about the roadmap of the monitor so that it can never fit "
        "on one line of a phone and must wrap inside its cell rather than be cut short with an ellipsis")


def roadmap_part(plain):
    """The ROADMAP section's lines (up to RECENT)."""
    return plain[plain.find("ROADMAP"):plain.find("RECENT") if "RECENT" in plain else len(plain)]


def plain_rows(rows):
    return [[c.plain for c in r] for r in rows]


def roadmap_checks(mock, check):
    """A table per project, stacked; one status vocabulary; nothing cut; the phone form."""
    web, own = copy.deepcopy(mock["web"]), copy.deepcopy(mock["tools"])
    step2, step3 = (o["title"] for o in web["step_overview"][1:3])
    pv_name, pk_name = (p["name"] for p in web["steps"][0]["plan"]["packages"])
    secs = step_sections(web)
    check([[x.plain for x in s["head"]] for s in secs] == [[step2 + " NOW", "9 of 26 done", "$23.85 of $300"],
                                                           [step3 + " NEXT", "0 of 5 done"]],
          "roadmap: the step cells %r" % [[x.plain for x in s["head"]] for s in secs])
    want = [[pv_name, "#211", "low", "✓ merged PR #238", ""],
            [pk_name, "#212 #213", "normal→high", "✖ accept PR #240", "your accept"],
            ["(no package)", "#205 #219", "", "○ ready", ""],
            ["(no package)", "13 issues", "", "– blocked", "10 labelled blocked · 3 no ready label"],
            ["checkpoint", "#230", "", "– later", "the work above"]]
    check(plain_rows(secs[0]["rows"]) == want, "roadmap: the current step's rows %r" % plain_rows(secs[0]["rows"]))
    want = [[web["step_overview"][2]["issues"][0]["title"], "#241", "", "○ ready", ""],
            ["(no package)", "#242–#244 #250", "", "– blocked", "labelled blocked"]]
    check(plain_rows(secs[1]["rows"]) == want, "roadmap: the next step's rows %r" % plain_rows(secs[1]["rows"]))
    check(later_line(web) == " · ".join(["%s (%d)" % (o["title"], o["work_open"]) for o in web["step_overview"][3:7]]
                                        + ["8–11 empty"]),
          "roadmap: the later steps %r" % later_line(web))
    check(plain_rows(step_sections(web, detail=False)[1]["rows"]) == [want[0]], "roadmap: no detail keeps the blocked rows")
    fr = plain_rows(fast_rows(own))
    check([r[0] for r in fr] == ["#27", "#24", "#22", "#25"] and [r[2:4] for r in fr] == [
        ["–", "● working"], ["#31", "● fix-check"], ["#29", "✖ needs you"], ["#30", "✖ needs you"]],
        "roadmap: the fast lane's rows %r" % fr)
    # every mark: a package at work beside the merged one; a queue with a long title and a blocked one
    pk = copy.deepcopy(web["steps"][0]["plan"]["packages"][0])
    pk.update(name="export-csv", key="pkg-2-export-csv", issues=[216], state="work", pr=None)
    web["steps"][0]["plan"]["packages"].append(pk)
    own["queue"] = [{"issue": 40, "title": LONG, "blocked": False, "waits_on": None, "lane": "fast"},
                    {"issue": 41, "title": "x", "blocked": True, "waits_on": "blocked by 19", "lane": "fast"}]
    fr = plain_rows(fast_rows(own))
    check(fr[-2][3] == "○ queued" and fr[-1][3:] == ["– blocked", "#19"], "roadmap: the queue's rows %r" % fr[-2:])
    for w in (130, 80):
        what = "roadmap at %d" % w
        plain, raw = frame(own, None, w, None, [("web", web)], False, MOCK_NOW, "tools")
        part = roadmap_part(plain).replace("ROADMAP  ", "ROADMAP ")
        lines = part.rstrip("\n").split("\n")
        words = words_of(part)
        check(all(len(x) <= w for x in plain.split("\n")), what + ": a line is wider than the pane")
        check("…" not in part, what + ": a cell is cut with …")
        check(all(x in words for x in LONG.split()), what + ": the long title is not whole")
        check(part.count("┌") == (2 if w > PHONE_UPTO else 3), what + ": not one table per project (per step on a phone)")
        d, c = part.find("ROADMAP tools"), part.find("ROADMAP web")
        check(0 <= d < part.find("└") < c, what + ": the projects are not stacked")
        check(VOCAB in words, what + ": no legend of the status vocabulary")
        for mark in "●○–✖✓":
            check(any(mark + " " in x for x in lines if x.lstrip().startswith("│") and "ROADMAP web" in part[:part.find(x)]),
                  what + ": the steps table has no %s" % mark)
        for mark in "●○–✖":
            check(any(mark + " " in x for x in lines[:lines.index(next(x for x in lines if "ROADMAP web" in x))]
                      if x.lstrip().startswith("│")), what + ": the fast-lane table has no %s" % mark)
        check("32m" in line_of(plain, raw, "● working") and "36m" in line_of(plain, raw, "○ ready"),
              what + ": ● is not green or ○ is not cyan")
        check(all(s not in words for s in ("health pass", "parallel tracks", "depends on", "(labelled blocked)",
                                            "managed", "unplanned", "queue empty")), what + ": an old fragment")
        if w > PHONE_UPTO:
            check(re.search(r"│ Step +│ Work +│ Issues +│ Risk +│ Status +│ Waiting on +│", part) is not None,
                  what + ": the steps table's header")
            check(re.search(r"│ Issue +│ Title +│ PR +│ Status +│ Waiting on +│", part) is not None,
                  what + ": the fast-lane table's header")
            check(re.search(r"│ 9 of 26 done +│ %s +│" % pk_name, part) is not None
                  and re.search(r"│ \$23\.85 of \$300 +│ export-csv +│ #216 ", part) is not None,
                  what + ": the Step cell's lines are not spread over the step's rows")
            check(re.search(r"├─+┼─+┴─+┴─+┴─+┴─+┤", part) is not None and re.search(r"│ Later +│ 4 Filters", part),
                  what + ": the later steps are not one spanning row")
        else:
            check("│ Step" not in part and any(x.startswith(step2 + " NOW · 9 of 26 done · $23.85 of $300")
                                             for x in lines), what + ": the step is not a heading line")
            check(any(x.startswith("Later ") and "4 Filters (5)" in x for x in lines), what + ": the later steps' line")


def cell_heights(part, col):
    """[(the row's first line, the lines its col cell takes)] of the first table in part with a
    header; a row starts where Issues has text."""
    lines = part.split("\n")
    head = next((x for x in lines if "│ Status" in x), None)
    if head is None:
        return []
    names = [c.strip() for c in head.split("│")]
    ks, kc, out = names.index("Issues"), names.index(col), []
    for x in lines[lines.index(head) + 2:]:
        cells = x.split("│")
        if x.startswith("└") or len(cells) != len(names):
            break
        if cells[ks].strip():
            out.append([x, 0])
        if out and cells[kc].strip():
            out[-1][1] += 1
    return out


def blocked_checks(fx, check):
    """A step with 20 merged packages and 23 blocked issues over 17 blocker sets (blocked-many.json):
    the package table survives at 120x55 (the done packages folded into one row), the phone at
    80x30 keeps the running, ready and needs-you packages; no blocked cell takes more than two
    lines, also with another project beside it."""
    snap = load(os.path.join(fx, "blocked-many.json"))[0]
    for w, h in ((120, 55), (80, 30)):
        what = "blocked-many at %dx%d" % (w, h)
        plain = frame(snap, None, w, h)[0]
        part = roadmap_part(plain)
        part = part[part.find("ROADMAP  web"):part.find("ROADMAP  tools")]
        words = words_of(part)
        check(len(plain.rstrip("\n").split("\n")) <= h, what + ": more lines than the terminal")
        check(all(x in words for x in ("exporter", "● working", "importer", "○ ready", "sharing", "✖ accept")),
              what + ": the running, ready and needs-you packages are not in the table")
        if w > PHONE_UPTO:
            check("│ Step" in part, what + ": no package table")
            check("20 merged" in words and "merged-0" not in words, what + ": the done packages are not one row")
    for w in (160, 120, 100, 80, 60):
        what = "blocked-many at %d" % w
        part = roadmap_part(frame(snap, None, w, None, (("tools", TOOLS),))[0])
        rows = cell_heights(part[part.find("ROADMAP  web"):], "Waiting on")
        blocked = [r for r in rows if "– blocked" in r[0]]
        check(blocked and all(n <= 2 for _, n in blocked), what + ": a blocked cell is longer than two lines %r"
              % [n for _, n in rows])
        cell = words_of(" ".join(x.split("│")[-2] for x in part.split("\n") if x.count("│") > 5))
        tops = re.findall(r"#\d+×\d+", cell)
        named = "behind #306×8" in cell and re.search(r"\+\d+ more", cell) \
            and tops[:2] in (["#306×8"], ["#306×8", "#109×4"])
        check(w > 140 or named or w <= 60 and "16 blockers" in cell,
              what + ": the blocked cell is not the top blockers, then +N more: %r" % cell)


def has_pipe(plain):
    return "›" in plain[plain.find("NOW"):plain.find("ROADMAP")]


def drop_order_checks(mock, check):
    """Less height drops, in order: the [tN] lines, roadmap later and blocked detail, the other
    project's events, RECENT, NOW's pipeline lines (to the stage), the roadmap to step headers.
    The NEEDS YOU box never drops."""
    for w in (140, 120, 80):
        prev = None
        for h in range(65, 11, -1):
            what = "drop order at %dx%d" % (w, h)
            plain, _ = mock_frame(mock, w, h)
            lines = plain.rstrip("\n").split("\n")
            words = words_of(plain)
            check(all(u in plain for u in URLS) and "ACCEPT" in plain and plain.count("STUCK") == 2,
                  what + ": the NEEDS YOU box lost an item")
            if h >= 30 or w > PHONE_UPTO:
                check(len(lines) <= h, what + ": %d lines" % len(lines))
            shown = {"tN": "[t52]" in plain, "later": "4 Filters" in words,
                     "other events": "web 18:" in words, "recent": "RECENT" in plain,
                     "pipeline": has_pipe(plain), "roadmap detail": mock["web"]["steps"][0]["plan"]["packages"][1]["name"] in words}
            order = ["tN", "later", "other events", "recent", "pipeline", "roadmap detail"]
            if w <= PHONE_UPTO:  # the phone shows neither [tN] lines nor the pipeline
                order = [k for k in order if k not in ("tN", "pipeline")]
            for i, k in enumerate(order):
                if not shown[k]:  # what drops after it is still there only if it is
                    check(not any(shown[j] for j in order[:i]), what + ": %s dropped while %s shown" % (
                        k, [j for j in order[:i] if shown[j]]))
            if prev is not None:
                check(all(prev[k] or not shown[k] for k in shown), what + ": a smaller height shows more")
            prev = shown


def owner_checks(mock, check):
    """NEEDS YOU holds the product owner's items only; the leader's are one LEADER line under the
    box (on the phone only their count). A snapshot without owner: every item is the product
    owner's, as before."""
    total = sum(len(mock[n]["needs_you"]) for n in ("tools", "web"))
    for w, h in SIZES:
        plain = mock_frame(mock, w, h)[0]
        check("LEADER:" not in plain and "NEEDS YOU · %d" % total in plain,
              "owner at %dx%d: a snapshot without owner shows every item, no LEADER line" % (w, h))
    own = copy.deepcopy(mock["tools"])
    for it in own["needs_you"]:
        it["owner"] = "po"
    q = own["needs_you"][1]
    q.update(owner="leader", since=MOCK_NOW - 600)
    own["needs_you"].append({"kind": "accept", "issue": 12, "pr": 13, "reason": "manual: plan tier", "owner": "leader",
                             "since": MOCK_NOW - 300, "url": "https://github.com/example-user/tools/pull/13"})
    for w, h in SIZES:
        what = "owner at %dx%d" % (w, h)
        plain = mock_frame(mock, w, h, own=own)[0]
        words = words_of(plain)
        check("NEEDS YOU · %d" % (total - 1) in plain, what + ": the leader's items are counted in NEEDS YOU")
        box = words[words.find("NEEDS YOU"):words.find("LEADER:")]  # the event log may name the item too
        check(q["reason"] not in box and "manual: plan tier" not in box, what + ": a leader's card is in NEEDS YOU")
        check("LEADER: 2 items · oldest 10m" in words, what + ": no LEADER line with the count and the oldest age")
        listed = "#%d %s 10m" % (q["issue"], q["kind"]) in words and "#12 accept 5m" in words
        check(listed if w > PHONE_UPTO else not listed, what + ": the leader's items are listed only on the wide screen")
    for it in own["needs_you"]:
        it["owner"] = "leader"
    alone = copy.deepcopy(mock)
    alone["web"]["needs_you"] = []
    plain = mock_frame(alone, 120, 55, own=own)[0]
    check("nothing needs you" in words_of(plain) and "LEADER: 3 items" in words_of(plain),
          "owner: only the leader's items: nothing needs you, and the LEADER line")


def many_checks(mock, check):
    """8 needs-you items: every card stays; the title lines go, then how: for repeated kinds."""
    own = copy.deepcopy(mock["tools"])
    base = own["needs_you"][0]
    for k in range(6):
        it = copy.deepcopy(base)
        it.update(issue=60 + k, pr=70 + k, since=base["since"] + 60 * (k + 1),
                  reason="CI on PR #%d is still pending after 90 min" % (70 + k),
                  url="https://github.com/example-user/tools/issues/%d" % (60 + k), title="Title %d" % (60 + k))
        own["needs_you"].append(it)
    for w, h in ((120, 55), (140, 65), (80, 30), (60, 30)):
        what = "8 needs-you at %dx%d" % (w, h)
        plain, _ = mock_frame(mock, w, h, own=own)
        words = words_of(plain)
        check("NEEDS YOU · 9" in plain, what + ": not every item counted")
        check(all("#%d" % (60 + k) in words and "https://github.com/example-user/tools/issues/%d" % (60 + k) in plain
                  for k in range(6)), what + ": an item or its URL is missing")
        check("Title 60" not in words_of(plain[:plain.find("NOW")]), what + ": the title lines are not dropped with more than 5 items")
        check(words.count("how:") <= 2, what + ": how: is repeated for a repeated kind")
        if w > PHONE_UPTO:
            check("┗" in plain, what + ": the box is not closed")
            check(len(plain.rstrip("\n").split("\n")) <= h, what + ": too many lines")


def empty_checks(check):
    snap = {"schema": 2, "project": "web", "repo": "example-org/web", "pass": {"at": NOW - 30, "ok": True},
            "caps": {"running": 0, "cap": 3}, "spend": {"today_usd": 0}, "usage": {}}
    for w, h in SIZES:
        what = "empty at %dx%d" % (w, h)
        plain, _ = frame(snap, None, w, h, name="web")
        words = words_of(plain)
        check("nothing needs you" in words and "nothing running" in words and "queue empty" in words,
              what + ": the empty state")
        check(len(plain.rstrip("\n").split("\n")) <= h, what + ": too many lines")


def ci_checks(mock, check):
    """CI in text: ✓, ◉ 12m (running), ⚠ 90m+ (pending too long), ∅ no checks."""
    own = copy.deepcopy(mock["tools"])
    own["running"][0].update(kind="waiting", pipeline="ci", minutes=12, min_cap=90, turns=None, turn_cap=None, pr=33,
                             ci="pending", last_line="")
    own["running"][1].update(kind="waiting", pipeline="merge", ci="green", minutes=3, min_cap=None, turns=None,
                             turn_cap=None, review_verdict=None)
    for w, h in ((120, 55), (80, 30)):
        words = words_of(mock_frame(mock, w, h, own=own)[0])
        if w > PHONE_UPTO:
            check("work ✓ › CI ◉ 12m › review ○" in words, "CI running at %d: not ◉ 12m" % w)
            check("work ✓ › CI ✓ › review ✓ pass › fix – › fix-check – › merge ◉ 3m" in words,
                  "CI green at %d: not ✓ (a review that passed skips the fix)" % w)
        else:
            check("#27 CI ◉ 12m" in words, "CI running at %d: not ◉ 12m" % w)
    own["running"][0].update(minutes=95)
    words = words_of(mock_frame(mock, 120, 55, own=own)[0])
    check("CI ⚠ 90m+" in words, "CI pending past its cap: not ⚠ 90m+")
    own["running"][0].update(pipeline="no-checks", ci="none", minutes=2, min_cap=10)
    words = words_of(mock_frame(mock, 120, 55, own=own)[0])
    check("work ✓ › CI ∅ no checks 2/10 min › review ○" in words, "CI with no checks: not ∅ no checks")


def review_checks(mock, check):
    """After a review: a fix round waiting on CI, CI pending or unknown past its step, red CI on
    the phone, step items without an issue or PR, what folds."""
    own = copy.deepcopy(mock["tools"])
    own["running"][1].update(kind="waiting", pipeline="ci", ci="pending", minutes=12, min_cap=90, turns=None,
                             turn_cap=None, review_verdict="changes")
    words = words_of(mock_frame(mock, 120, 55, own=own)[0])
    check("work ✓ › CI ◉ 12m › review ✓ changes › fix ✓ › fix-check ○ › merge ○" in words,
          "a fix round waiting on CI: not at the CI step with the review and the fix done")
    own["running"][1].update(pipeline="fix-check", minutes=12, min_cap=None)
    words = words_of(mock_frame(mock, 120, 55, own=own)[0])
    check("CI ◉ running › review ✓ changes" in words and "CI ✓" not in words, "CI pending past its step reads ✓")
    own["running"][1].update(ci=None)
    words = words_of(mock_frame(mock, 120, 55, own=own)[0])
    check("work ✓ › CI ? › review ✓ changes" in words, "an unknown CI state past its step is not ?")
    own["running"][1].update(ci="red")
    words = words_of(mock_frame(mock, 80, 30, own=own)[0])
    check("PR #31 · CI ✖ red" in words, "the phone does not show red CI past its step")
    own = copy.deepcopy(mock["tools"])
    for k in (1, 2):
        own["needs_you"].append({"kind": "budget", "issue": None, "pr": None, "reason": "step %d over budget" % k,
                                 "since": MOCK_NOW - 2400 + k, "step": 9, "url": ""})
    plain = mock_frame(mock, 120, 55, own=own)[0]
    check("None" not in plain, "a step item without an issue or PR reads None")
    check("BUDGET tools · step 1 over budget" in words_of(plain) and "tools  ·" not in plain,
          "a card without numbers has an empty segment")
    check("how: same as step 9" in words_of(plain), "a repeated step item's how: does not name the step")
    ev = [{"at": 1, "text": "step 12 planned"}, {"at": 2, "text": "step 13 planned"},
          {"at": 3, "text": "#5 review post failed (try 1): x"}, {"at": 4, "text": "#5 review post failed (try 2): x"},
          {"at": 5, "text": "#5 CI pending after 3 min"}, {"at": 6, "text": "#5 CI pending after 4 min"}]
    check([r["count"] for r in fold_events(ev)] == [1, 1, 2, 2], "fold: only counters fold (try N, after N min)")


def fixture_checks(fx, check):
    """Every fixture at 60, 100 and 160 columns (40 lines), with another project beside it."""
    names = sorted(f for f in os.listdir(fx) if f.endswith(".json")) + ["missing.json"]
    for name in names:
        for w in (60, 100, 160):
            what = "%s at %d" % (name, w)
            try:
                snap, err = load(os.path.join(fx, name))
                plain, raw = frame(snap, err, w, 40, (("tools", TOOLS),))
                big, _ = frame(snap, err, w, None, (("tools", TOOLS),))
            except Exception as e:  # the one thing the monitor must never do
                check(False, "%s: %s: %s" % (what, type(e).__name__, e))
                continue
            lines = plain.rstrip("\n").split("\n")
            check(all(len(x) <= w for x in lines), what + ": a line is wider than the terminal")
            words = words_of(plain)
            if name in ("missing.json", "empty.json", "truncated.json", "not-object.json"):
                check(plain.startswith("canccu-monitor: "), what + ": no one-line reason")
                continue
            check(len(lines) <= 40, what + ": more lines than the terminal")
            check(plain.find("NEEDS YOU") < plain.find("NOW"), what + ": NEEDS YOU is not above NOW")
            check(("dispatcher not running?" in words) == (name in ("stale.json", "wrong-types.json")),
                  what + ": the stale banner is wrong")
            check("ACCEPT tools #7 → PR #8" in words or "ACCEPT tools #7 PR #8" in words,
                  what + ": the other project's needs-you item is not in the box")
            check("tools #11" in words_of(big), what + ": the other project's running item is not under NOW")
            for it in snap.get("needs_you", []) if isinstance(snap.get("needs_you"), list) else []:
                url = it.get("url") if isinstance(it, dict) else None
                if isinstance(url, str) and url.startswith("https://"):
                    check(url in flat(plain), what + ": the URL %s is cut" % url)
                    check("\x1b]8;" in raw and url in raw, what + ": the URL %s is no OSC 8 link" % url)
            bw = words_of(big)
            if name == "busy.json" and w > PHONE_UPTO:
                check("today ≥ $12.40 (+2 runs without a cost)" in bw or "≥ $12.40" in bw, what + ": no lower-bound spend")
                check("◆" in big and "█" in big, what + ": an old snapshot does not show the milestone bars")
                check(re.search(r"│ #46 +│ feat: email the export +│ – +│ – blocked +│ #45 +│", big) is not None,
                      what + ": no blocked reason")
            if name == "newer-schema.json":
                check("newer than this monitor" in words, what + ": no schema warning")
            if name == "steps.json":
                steps_checks(big, bw, w, what, check)
            if name == "packages.json":
                packages_checks(big, bw, w, what, check)


def steps_checks(plain, words, w, what, check):
    """The snapshot the dispatcher wrote (tests/canccu-snapshot2.sh): a checkpoint waiting."""
    check("3 Search NOW" in words and "1 of 5 done" in words, what + ": no current step with work issues done/total")
    check("https://github.com/example-org/web/issues/95#issuecomment-7" in flat(plain), what + ": no checkpoint summary link")
    check("CHECKPOINT" in words, what + ": the checkpoint card")
    check("other 77 · cc" in words and "other 55 · worker" in words, what + ": the runs by hand are not under NOW as other")
    if w <= PHONE_UPTO:
        return
    check("$5.00 of $4" in words, what + ": the step's spend against STEP_BUDGET")
    check(re.search(r"│ list +│ #104 +│ low +│ – blocked +│ auth +│", plain) is not None, what + ": the blocked package")
    check(re.search(r"│ checkpoint +│ #95 +│ +│ ✖ needs you +│ your go +│", plain) is not None, what + ": the waiting checkpoint")
    check("4 Sharing NEXT" in words, what + ": the next step")
    check("5 Export empty · 6 Later (1)" in words, what + ": the later steps")
    check("Follow-up: split the parser (PR #50)" in words, what + ": no Follow-up in RECENT")


def packages_checks(plain, words, w, what, check):
    """Packages in every stage, a parallel track, a run of another repo."""
    check("other other-repo#12 · cc" in words, what + ": a run of another repo in the workers dir")
    if w <= PHONE_UPTO:
        return
    for word in ("✓ merged PR #71", "✓ closed", "✖ refused", "✖ needs you PR #74", "○ ready", "✖ accept PR #69",
                 "● working", "● in CI PR #65", "● in review PR #66", "● fixing PR #67", "● fix-check PR #68",
                 "● merging PR #70"):
        check(word in words, what + ": no package state %r" % word)
    check(re.search(r"│ b +│ #302 +│ low +│ – blocked +│ a +│", plain) is not None, what + ": the blocked package")
    check("depends on" not in words, what + ": a depends on fragment")
    check("an old note" not in words, what + ": an old note is shown as new")


class Writes:
    """A terminal that keeps each write apart."""

    def __init__(self):
        self.writes = []

    def write(self, s):
        self.writes.append(s)

    def flush(self):
        pass


def screen_checks(fx, check):
    """A few redraws through Display: the cursor hidden first, never shown while drawing, shown on
    exit (also after an error); a frame that did not change writes nothing, also one with links; a
    frame fits the terminal's height."""
    snaps = {n: load(os.path.join(fx, n))[0] for n in ("busy.json", "normal.json", "steps.json", "packages.json")}
    con = Console(file=io.StringIO(), width=100, height=30, force_terminal=True, color_system="256")
    other = [("tools", TOOLS)]
    snaps["spent"] = json.loads(json.dumps(snaps["busy.json"]))
    snaps["spent"]["spend"]["today_usd"] += 1
    steps = [("busy.json", (100, 30)), ("busy.json", (100, 30)), ("spent", (100, 30)),
             ("normal.json", (60, 20))]

    def frame_():
        name, con.size = steps.pop(0)
        return render(snaps[name], None, NOW, con.width, other, None, con.height)

    term = Writes()
    live(Display(con, term), frame_, pause=0, count=len(steps))
    w = term.writes
    cups = [len(re.findall(r"\x1b\[\d+;1H", x)) for x in w]
    check(len(w) == 5, "screen: %d writes, not 5 (enter, frame, changed lines, resize, exit)" % len(w))
    check(w[0].startswith(ALT_ON + HIDE), "screen: the cursor is not hidden first")
    check(all(SHOW not in x for x in w[:-1]), "screen: the cursor is shown during the redraws")
    check(w[-1].endswith(SHOW + ALT_OFF), "screen: the cursor is not shown on exit")
    check(all(x.startswith(SYNC_ON + HIDE) and x.endswith(SYNC_OFF) for x in w[1:-1]),
          "screen: a redraw is not synchronized, or does not re-hide the cursor")
    check(cups[1:4] == [30, cups[2], 20] and 0 < cups[2] < 30,
          "screen: lines written per redraw %s, not all / only the changed ones / all" % cups[1:4])
    rows = re.split(r"\x1b\[\d+;1H", re.sub(r"\x1b\[\?\d+[hl]", "", w[1]))[1:]
    plain = [ANSI.sub("", OSC8.sub("", r)) for r in rows]
    check(len(plain) == 30 and all(len(r) == 100 for r in plain),
          "screen: a line is not exactly the terminal's width")
    check(any("NEEDS YOU" in r for r in plain), "screen: the frame is not drawn")
    # the step view with its links, drawn twice from the same snapshot: the second writes nothing
    for name, size in (("steps.json", (160, 60)), ("packages.json", (100, 80)), ("steps.json", (60, 50))):
        con.size = size
        term = Writes()
        live(Display(con, term), lambda: render(snaps[name], None, NOW, con.width, other, None, con.height),
             pause=0, count=2)
        check(len(term.writes) == 3 and "\x1b]8;;https://" in term.writes[1],
              "screen: %s at %d: an unchanged frame with links is written again (%d writes, not 3)"
              % (name, size[0], len(term.writes)))
    # a live dispatcher: the same snapshot, a pass 10 s ago, a clock that moves (2 s, then past
    # the minute): the 2 s redraw writes nothing, the one past the minute only what changed
    fresh = json.loads(json.dumps(snaps["busy.json"]))
    fresh["pass"]["at"] = NOW - 10
    clock = [NOW, NOW + 2, NOW + 52]

    def tick():
        return render(fresh, None, clock.pop(0), con.width, other, None, con.height)
    con.size = (100, 30)
    term = Writes()
    live(Display(con, term), tick, pause=0, count=len(clock))
    w = term.writes
    cups = [len(re.findall(r"\x1b\[\d+;1H", x)) for x in w]
    check(len(w) == 4 and cups[1] == 30, "screen: a fresh pass 2 s later is redrawn (%d writes, not 4)" % len(w))
    check(len(w) == 4 and 0 < cups[2] < 30 and "pass 1m ago" in ANSI.sub("", w[2]),
          "screen: the pass age is not redrawn once it passes the minute")
    for exc in (KeyboardInterrupt, RuntimeError):
        def boom():
            raise exc()
        term = Writes()
        try:
            live(Display(con, term), boom, pause=0)
        except exc:
            pass
        check(term.writes[-1].endswith(SHOW + ALT_OFF), "screen: no cursor after " + exc.__name__)
