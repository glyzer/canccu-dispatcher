# SPDX-License-Identifier: AGPL-3.0-or-later
"""The top of the screen ("Inbox First"): the header and the NEEDS YOU box.

Header: every project with its pass age and ✓/⚠, the slots, the clock; today's spend in total and
per project; the 5-hour and weekly usage as bars with their reset times; the release the
dispatchers run (one line on a phone).

NEEDS YOU: one card per item of every project, oldest first. Line 1: the verb, project, issue → PR
(PR ← issues for a package), the whole reason, since when (clock time and age) and the stage
where it parked, with its glyph. Line 2: how: the action that clears it (HOW, per kind), and the
package. Line 3: the title. Line 4: the URLs as text and OSC 8 links. More than SHORTEN_FROM
items: no title lines and no how: for a repeated kind. The phone's cards are 2 lines: the verb,
numbers, short reason and age; then the URL. Nothing of the reason, numbers or URLs is cut."""
import re
import time

from rich.text import Text

from .data import lst, num, nums, obj, txt
from .parts import (DONE, NONE, NO_CHECKS, SCHEMA, STEPS, STUCK, YOU, ago, bar, clock, glyph, hm, issue_style,
                    line, url_lines, wrap)

VERBS = {"accept": "ACCEPT", "needs-you": "STUCK", "question": "QUESTION", "plan": "PLAN OK?",
         "checkpoint": "CHECKPOINT", "plan-invalid": "PLAN BAD", "budget": "BUDGET"}
# the action that clears an item, per kind (needs-you: per the stage it parked at)
HOW = {"accept": "label PR #{pr} accepted, or canccu-ship {i}",
       "plan": "read the plan, then label #{i} plan-ok, or comment on it",
       "question": "answer the worker's question in a comment on #{i}",
       "checkpoint": "check the step, then label #{i} checkpoint-ok, or close it",
       "plan-invalid": "read the epic #{i}: fix the plan or the issues; the planner runs again",
       "budget": "raise STEP_BUDGET in the project config (clears next pass), or stop the step",
       "needs-you/ci": "look at the checks on PR #{pr}; comment on #{i} to resume the worker, or remove needs-you",
       "needs-you/no-checks": "set up CI (or fix the path filter) for PR #{pr}; comment on #{i} to resume the worker",
       "needs-you": "read the needs-you comment on #{i}; comment the way on (the worker resumes), or remove needs-you"}
SHORTEN_FROM = 6  # this many items or more: no title lines, no how: for a repeated kind
VERB_W = 8


def pass_period(snap):
    """Seconds from one snapshot to the next: INTERVAL plus the longest of the last passes (a
    pass that starts workers can take minutes), so a busy dispatcher is never called stale."""
    durations = obj(snap, "pass").get("durations")
    longest = max([d for d in durations if isinstance(d, (int, float)) and not isinstance(d, bool)] or [0]) \
        if isinstance(durations, list) else (num(obj(snap, "pass"), "duration") or 0)
    return (num(snap, "interval") or 60) + longest


def healthy(snap, now):
    p = obj(snap, "pass")
    at = num(p, "at")
    return at is not None and now - at <= 3 * pass_period(snap) and p.get("ok") is not False and not snap.get("stale")


def usage_of(projects):
    for _, s in projects:
        if isinstance(s, dict) and obj(s, "usage"):
            return obj(s, "usage")
    return {}


def spend(projects):
    """(total, lower bound?, [(name, usd)])."""
    total, low, per = 0.0, False, []
    for name, s in projects:
        sp = obj(s, "spend")
        if num(sp, "today_usd") is not None:
            total += num(sp, "today_usd")
            per.append((name, num(sp, "today_usd")))
            low = low or bool(num(sp, "runs_without_cost"))
    return total, low, per


def slots(snap):
    caps = obj(snap, "caps")
    r, c = num(caps, "total_running"), num(caps, "total_cap")
    if r is None or c is None:
        r, c = num(caps, "running"), num(caps, "cap")
    return "%s/%s" % ("?" if r is None else r, "?" if c is None else c)


def project_mark(name, snap, now, own, phone):
    t = Text(name, style="bold")
    if snap is None:
        return t.append(" ?", style="dim")
    at = num(obj(snap, "pass"), "at")
    if own and not phone:
        t.append(" · %s" % txt(snap, "repo", "?"))
    t.append((" " if phone else " · pass ") + ("%s ago" % ago(now, at) if not phone else ago(now, at))
             if at is not None else " · no pass yet")
    t.append(" ")
    glyph(DONE if healthy(snap, now) else STUCK, t)
    p = obj(snap, "pass")
    if p.get("paused") is True:
        t.append(" PAUSED", style="bold yellow")
    if num(p, "backoff_until") and num(p, "backoff_until") > now:
        t.append(" usage limit until %s" % hm(num(p, "backoff_until")), style="bold yellow")
    return t


def versions(projects):
    """The release the dispatchers run: the own project's, then each other project's that differs
    (its dispatcher was not restarted after an upgrade); nothing from snapshots without one."""
    own = txt(projects[0][1], "version")
    out = ["v" + own] if own else []
    out += ["%s v%s" % (n, txt(s, "version")) for n, s in projects[1:] if txt(s, "version") not in ("", own)]
    return " · ".join(out)


def header(projects, now, width, phone):
    own = projects[0][1]
    usage = usage_of(projects)
    total, low, per = spend(projects)
    money = ("≥ $%.2f" if low else "$%.2f") % total
    marks = [project_mark(n, s, now, k == 0, phone) for k, (n, s) in enumerate(projects)]
    u5, uw = num(usage, "five_hour"), num(usage, "seven_day")
    throttle = txt(usage, "text") if txt(usage, "state") in ("slow", "stop", "drain") else ""
    if phone:
        t = Text()
        for m in marks:
            t.append_text(m).append(" · ")
        t.append("slots %s · %s" % (slots(own), money))
        if u5 is not None:
            t.append(" · 5h %d%%" % u5)
        if uw is not None:
            t.append(" · week %d%%" % uw)
        if throttle:
            t.append(" · " + throttle, style="bold yellow")
        if versions(projects):
            t.append(" · " + versions(projects), style="dim")
        return wrap(t, width, 2)
    for gap in ("  │  ", " │ "):
        sep = (gap, "dim")
        t = Text()
        for m in marks:
            t.append_text(m).append(*sep)
        t.append("slots %s" % slots(own)).append(*sep)
        t.append(time.strftime("%a %d %b %H:%M %Z", time.localtime(now)), style="dim")
        if len(t.plain) <= width:
            break
    t2 = Text("today " + money)
    nocost = sum(num(obj(s, "spend"), "runs_without_cost") or 0 for _, s in projects)
    if nocost:
        t2.append(" (+%d run%s without a cost)" % (nocost, "" if nocost == 1 else "s"), style="dim")
    if len(per) > 1:
        t2.append(" · " + " · ".join("%s $%.2f" % (n, v) for n, v in per))
    freeze = txt(obj(own, "spend"), "freeze")
    if freeze:
        t2.append(" · freeze %s" % freeze, style="dim")
    if u5 is not None:
        t2.append(*sep).append("5h ").append(bar(u5), style="cyan").append(" %d%%" % u5)
        if num(usage, "resets_at"):
            t2.append(" → " + hm(num(usage, "resets_at")), style="dim")
    if uw is not None:
        t2.append(*sep).append("week ").append(bar(uw), style="cyan").append(" %d%%" % uw)
        if num(usage, "weekly_resets_at"):
            t2.append(" → " + time.strftime("%a %H:%M", time.localtime(num(usage, "weekly_resets_at"))), style="dim")
    if throttle:
        t2.append(*sep).append(throttle, style="bold yellow")
    if versions(projects):
        t2.append(*sep).append(versions(projects), style="dim")
    return wrap(t, width, 2) + wrap(t2, width, 2)


def banners(snap, now, width):
    out = []
    p = obj(snap, "pass")
    at = num(p, "at")
    if at is None or now - at > 3 * pass_period(snap):
        out.append(Text("dispatcher not running? " + ("last pass %s ago" % ago(now, at) if at is not None else "no pass time"),
                        style="bold white on red"))
    if p.get("ok") is False:
        out.append(Text("the last pass failed: %s" % txt(p, "error", "unknown error"), style="bold red"))
    if num(snap, "schema") is not None and num(snap, "schema") > SCHEMA:
        out.append(Text("snapshot schema %s is newer than this monitor (%d): update canccu-dispatcher"
                        % (num(snap, "schema"), SCHEMA), style="yellow"))
    stale = [s for s in snap.get("stale", []) if isinstance(s, str)] if isinstance(snap.get("stale"), list) else []
    if stale:
        out.append(Text("from an earlier pass: %s" % ", ".join(stale), style="yellow"))
    return [x for b in out for x in wrap(b, width, 2)]


# ------------------------------------------------------------------ the cards

def items(projects):
    """[(project, snapshot, item)] of every project, oldest first (no time: last)."""
    out = [(n, s, it) for n, s in projects if isinstance(s, dict) for it in lst(s, "needs_you")]
    return sorted(out, key=lambda x: (num(x[2], "since") is None, num(x[2], "since") or 0))


def issues_of(it):
    i = nums(it, "issues")
    return i if i else [num(it, "issue")] if num(it, "issue") is not None else []


def numbers(it, phone):
    """#52 → PR #60; a package's PR #131 ← #103 +#104 (phone: #52 PR #60, PR #131 (#103 +#104))."""
    n, pr, iss = num(it, "issue"), num(it, "pr"), issues_of(it)
    if pr is not None and len(iss) > 1:
        rest = "#%d" % iss[0] + "".join(" +#%d" % x for x in iss[1:])
        return "PR #%d (%s)" % (pr, rest) if phone else "PR #%d ← %s" % (pr, rest)
    if n is not None and pr is not None:
        return "#%d PR #%d" % (n, pr) if phone else "#%d → PR #%d" % (n, pr)
    return "#%d" % n if n is not None else "PR #%d" % pr if pr is not None else ""


def stage_cell(st, t=None):
    """Where a unit parked, with its glyph: CI ⚠ (pending too long or red), CI ∅ (no checks),
    <stage> ✖ (appended to t when given)."""
    t = t if t is not None else Text()
    if st == "ci":
        return glyph(STUCK, t.append("CI "))
    if st == NO_CHECKS:
        return glyph(NONE, t.append("CI "))
    return glyph(YOU, t.append(dict(STEPS).get(st, st) + " "))


def stage_text(it):
    """stage CI ⚠, stage CI ∅, stage <name> ✖; None when unknown."""
    st = txt(it, "stage")
    return stage_cell(st, Text("stage ")) if st else None


def short_reason(it):
    """The reason without what the card's numbers already say (phone): "CI on PR #61 is still
    pending" → "CI still pending"."""
    r, pr = txt(it, "reason"), num(it, "pr")
    if pr is not None:
        r = re.sub(r" on PR #%d is\b" % pr, "", r)
        r = re.sub(r" (of|on) PR #%d\b" % pr, "", r)
    return r


def package_of(snap, it):
    """The package's plan entry ({} when unknown) and the step's short name."""
    key, step = txt(it, "package"), num(it, "step")
    pk, title = {}, ""
    for s in lst(snap, "steps"):
        if num(s, "milestone") == step and step is not None:
            title = txt(s, "title")
        for p in lst(obj(s, "plan"), "packages"):
            if key and txt(p, "key") == key:
                pk = p
    if not title:
        title = next((txt(o, "title") for o in lst(snap, "step_overview") if num(o, "milestone") == step), "")
    m = re.match(r"\d+", title)
    return pk, (m.group(0) if m else title or (str(step) if step is not None else ""))


def how(it):
    kind, st = txt(it, "kind"), txt(it, "stage")
    fmt = HOW.get("%s/%s" % (kind, st)) or HOW.get(kind) or HOW["needs-you"]
    n, pr = num(it, "issue"), num(it, "pr")
    return fmt.format(i=n if n is not None else "?", pr=pr if pr is not None else "?")


def pr_url(snap, it):
    pr, repo = num(it, "pr"), txt(snap, "repo")
    if pr is None or "/" not in repo:
        return ""
    u = "https://github.com/%s/pull/%d" % (repo, pr)
    return "" if u == txt(it, "url") else u


def label(snap, it):
    """What a repeated kind's how: points back to: #n, PR #n, else its step, else the verb."""
    if num(it, "issue") is not None:
        return "#%d" % num(it, "issue")
    if num(it, "pr") is not None:
        return "PR #%d" % num(it, "pr")
    step = package_of(snap, it)[1]
    return "step %s" % step if step else VERBS.get(txt(it, "kind"), txt(it, "kind") or "?")


def card(name, snap, it, now, inner, marked, first_of_kind, short):
    """The full card's lines at the box's inner width."""
    kind = txt(it, "kind")
    since = num(it, "since")
    head = glyph(YOU)
    head.append(" " + VERBS.get(kind, kind.upper() or "?").ljust(VERB_W), style="bold red")
    if marked:
        head.append(" " + name, style="bold")
    if numbers(it, False):  # a step's item may have neither issue nor PR
        head.append(" ").append(numbers(it, False), style=issue_style(it))
    parts = [Text(txt(it, "reason"))] if txt(it, "reason") else []
    if since is not None:
        parts.append(Text("%ssince %s (%s)" % ("waiting " if kind == "accept" else "", clock(now, since), ago(now, since)),
                          style="dim"))
    if kind != "accept" and stage_text(it) is not None:
        parts.append(stage_text(it))
    for p in parts:
        head.append(" · ", style="dim").append_text(p)
    style = "yellow" if txt(it, "stage") in ("ci", NO_CHECKS) else ""
    if style:
        head.stylize(style, 2, 2 + VERB_W + 1)
    ind = 2 + VERB_W + 1
    out = wrap(head, inner, ind)
    h = Text(" " * ind)
    pk, step = package_of(snap, it)
    extra = []
    if pk or txt(it, "package"):
        extra.append("pkg %s" % (txt(pk, "name") or txt(it, "package")))
    if step:
        extra.append("step %s" % step)
    risk, eff = txt(pk, "risk"), txt(pk, "risk_effective")
    if risk:
        extra.append("risk %s" % (risk if not eff or eff == risk else "%s→%s" % (risk, eff)))
    if first_of_kind is None:
        h.append("how: ", style="bold").append(how(it))
    elif not short:
        h.append("how: ", style="bold").append("same as %s" % first_of_kind)
    if extra:
        if len(h.plain) > ind:
            h.append(" · ", style="dim")
        h.append(" · ".join(extra), style="dim")
    if len(h.plain) > ind:
        out += wrap(h, inner, ind + 2)
    if not short and txt(it, "title"):
        out += wrap(Text(" " * ind + txt(it, "title")), inner, ind)
    out += url_lines([("", txt(it, "url")), ("PR", pr_url(snap, it))], inner, ind)
    return out


def box(projects, now, width, marked, short_more=False):
    """The NEEDS YOU box (never dropped). short_more: no title lines and no repeated how:, also
    with fewer items (the height is short)."""
    its = items(projects)
    if not its:
        return [line(glyph(DONE), (" nothing needs you", "green"))]
    inner = width - 4
    short = len(its) >= SHORTEN_FROM or short_more
    title = line((" ", ""), glyph(YOU), (" NEEDS YOU · %d " % len(its), "bold red"),
                 ("━ what to do · oldest first ", "red"))
    top = line(("┏━", "bold red"), title)
    top.append("━" * max(0, width - 1 - len(top.plain)), style="bold red").append("┓", style="bold red")
    rows = [top]
    seen = {}
    for name, snap, it in its:
        k = (txt(it, "kind"), txt(it, "stage"))
        first = seen.get(k)
        if first is None:
            seen[k] = ("%s " % name if marked and name != projects[0][0] else "") + label(snap, it)
        for ln in card(name, snap, it, now, inner, marked, first, short):
            ln.append(" " * max(0, inner - len(ln.plain)))
            rows.append(line(("┃ ", "bold red"), ln, (" ┃", "bold red")))
    rows.append(line(("┗" + "━" * (width - 2) + "┛", "bold red")))
    return rows


def phone_cards(projects, now, width, marked):
    its = items(projects)
    if not its:
        return [line(glyph(DONE), (" nothing needs you", "green"))]
    rows = [line(glyph(YOU), (" NEEDS YOU · %d" % len(its), "bold red"))]
    for name, snap, it in its:
        kind = txt(it, "kind")
        t = glyph(YOU)
        t.append(" " + VERBS.get(kind, kind.upper() or "?"), style="bold red")
        if marked:
            t.append(" " + name, style="bold")
        if numbers(it, True):
            t.append(" ").append(numbers(it, True), style=issue_style(it))
        if short_reason(it):
            t.append(" · " + short_reason(it))
        if num(it, "since") is not None:
            t.append(" · " + ago(now, num(it, "since")), style="dim")
        rows += wrap(t, width, 2)
        rows += url_lines([("", txt(it, "url") or pr_url(snap, it))], width, 2)
    return rows

