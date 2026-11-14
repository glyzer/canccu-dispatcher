# SPDX-License-Identifier: AGPL-3.0-or-later
"""Fitting the ROADMAP table: a blocked group's Waiting on capped at two lines, the done packages
folded into one row.

A step with split issues has many blocked issues, nearly each behind its own set of blockers;
listed in full, the one Waiting on cell wrapped to some 25 lines and the table no longer fitted
any pane, so the monitor fell back to the one-line step headers."""
import io
import re

from rich.console import Console
from rich.text import Text

MAX_LINES = 2
_CON = Console(file=io.StringIO(), width=200)


def lines_at(s, width):
    """The lines s takes in a table cell of width cells (rich wraps it the same way)."""
    return len(Text(s).wrap(_CON, max(1, width), overflow="fold"))


def blockers(reasons):
    """[(blocker, issues behind it)], the most first: a "#12 #14" reason counts for #12 and for #14
    (the count per blocker set says little once nearly every issue has its own set)."""
    counts = {}
    for r in reasons:
        for k in r.split() if re.fullmatch(r"#\d+( #\d+)*", r) else [r]:
            counts[k] = counts.get(k, 0) + 1
    return sorted(counts.items(), key=lambda x: -x[1])


def top(tops, more):
    """behind #306×8, #109×4 · +11 more (the Issues cell beside it names the issues; no space before
    the count, so a line never breaks between a blocker and its count)."""
    if not tops:
        return "%d blockers" % more
    parts, behind = [], False
    for r, c in tops:
        lead = "behind " if r.startswith("#") and not behind else ""
        behind = behind or r.startswith("#")
        parts.append("%s%s×%d" % (lead, r, c))
    return ", ".join(parts) + (" · +%d more" % more if more else "")


class Capped(Text):
    """A blocked group's Waiting on: the full text when it fits MAX_LINES of its column, else the
    top blockers and +N more. table() sets it for the column's width (set_width)."""

    def __init__(self, full, reasons):
        super().__init__(full)
        self.full, self.tops = full, blockers([r for r in reasons if r])

    def set_width(self, width):
        text = self.full
        k = len(self.tops)
        while lines_at(text, width) > MAX_LINES and k > 0:
            k -= 1
            text = top(self.tops[:k], len(self.tops) - k)
        self.plain = text


def cap_cells(rows, ws):
    """Sets every Capped cell for its column's width; False when there is none."""
    found = False
    for r in rows:
        for c, w in zip(r, ws):
            if isinstance(c, Capped):
                c.set_width(w)
                found = True
    return found


def fold_done(packages):
    """(the done packages' names as one Work cell: 12 merged · 1 closed, their issues); None when
    fewer than two are done (a fold of one saves nothing)."""
    done = [p for p in packages if p.get("state") in ("merged", "closed")]
    if len(done) < 2:
        return None
    n = {s: sum(1 for p in done if p.get("state") == s) for s in ("merged", "closed")}
    word = " · ".join("%d %s" % (c, s) for s, c in n.items() if c)
    return word, done
