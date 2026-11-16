# SPDX-License-Identifier: AGPL-3.0-or-later
"""canccu-status --kpi: what the leader and the product owner cost the project, per day.

Usage: python3 canccu-kpi.py <now epoch> <repo> <transcripts dir> <spend.log> <dispatch.log> <events>
Reads only what exists (contracts: no run is started to measure); a missing file is an empty one.
Four blocks, the last 7 UTC days, newest first:
- the leader's tokens: the `usage` of its Claude transcripts (<dir>/*.jsonl); no transcript:
  `leader: none`;
- the test runs: the `tests=` and `test_secs=` outcome fields of the repo's spend.log lines;
- the pings: dispatch.log's `#<n> pinged @…` lines;
- the feed lines by owner and class (po ask, po interrupt, leader ask, info).
"""
import datetime
import glob
import json
import os
import re
import sys

now, repo, tdir, spend, dlog, events = int(sys.argv[1]), *sys.argv[2:7]
today = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date()
DAYS = [(today - datetime.timedelta(days=i)).isoformat() for i in range(7)]
# a transcript untouched since before the first day holds nothing of the window
oldest = now - 8 * 86400
PING = re.compile(r"^(\d{4}-\d\d-\d\d)[T ]\S+ #\d+ pinged @")


def lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            yield from f
    except OSError:
        return


def leader():
    files = sorted(glob.glob(os.path.join(tdir, "*.jsonl")))
    if not files:
        return ["leader: none"]
    sums, seen = {}, set()
    for path in files:
        try:
            if os.path.getmtime(path) < oldest:
                continue
        except OSError:
            continue
        for raw in lines(path):
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            msg = ev.get("message") if isinstance(ev, dict) else None
            usage = msg.get("usage") if isinstance(msg, dict) else None
            day = str(ev.get("timestamp") or "")[:10]
            if not isinstance(usage, dict) or day not in DAYS:
                continue
            # claude writes one line per content block of a message, each with the message's usage
            mid = msg.get("id")
            if mid:
                if mid in seen:
                    continue
                seen.add(mid)
            s = sums.setdefault(day, [0, 0, 0, 0])
            for i, k in enumerate(("input_tokens", "output_tokens", "cache_read_input_tokens",
                                   "cache_creation_input_tokens")):
                if isinstance(usage.get(k), int):
                    s[i] += usage[k]
    out = ["leader tokens per day (input · output · cache read · cache write):"]
    for d in DAYS:
        out.append(f"  {d}  " + (" · ".join(map(str, sums[d])) if d in sums else "none"))
    return out


def test_runs():
    # a run's line holds only the sum and the count: each of its calls counts as the run's mean,
    # so the median is over calls and the longest is the longest run's mean
    calls = {}
    for raw in lines(spend):
        c = raw.rstrip("\n").split("\t")
        if len(c) < 15 or c[1] != repo or not c[0].isdigit():
            continue
        f = dict(kv.split("=", 1) for kv in c[14].split(",") if "=" in kv)
        if not (f.get("tests", "").isdigit() and f.get("test_secs", "").isdigit()) or int(f["tests"]) == 0:
            continue
        day = datetime.datetime.fromtimestamp(int(c[0]), datetime.timezone.utc).date().isoformat()
        n = int(f["tests"])
        calls.setdefault(day, []).extend([int(f["test_secs"]) / n] * n)
    out = ["test runs per day (TEST_CMD calls in runs: count · median · longest):"]
    for d in DAYS:
        v = sorted(calls.get(d, []))
        if not v:
            out.append(f"  {d}  none")
            continue
        m = len(v) // 2
        med = v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2
        out.append(f"  {d}  {len(v)} · median {round(med)}s · longest {round(v[-1])}s")
    return out


def pings():
    n = dict.fromkeys(DAYS, 0)
    for raw in lines(dlog):
        m = PING.match(raw)
        if m and m.group(1) in n:
            n[m.group(1)] += 1
    return ["pings per day:"] + [f"  {d}  {n[d]}" for d in DAYS]


def feed():
    cols = ("po ask", "po interrupt", "leader ask", "info")
    n = {d: dict.fromkeys(cols, 0) for d in DAYS}
    for raw in lines(events):
        c = raw.rstrip("\n").split("\t")
        if len(c) < 4 or c[0][:10] not in n:
            continue
        # info has no owner (contracts §3: `-`), whoever it concerns
        k = "info" if c[3] == "info" else f"{c[2]} {c[3]}"
        if k in cols:
            n[c[0][:10]][k] += 1
    return [f"feed lines per day ({' · '.join(cols)}):"] + \
        [f"  {d}  " + " · ".join(str(n[d][k]) for k in cols) for d in DAYS]


print("\n".join(leader() + test_runs() + pings() + feed()))
