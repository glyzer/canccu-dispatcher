# SPDX-License-Identifier: AGPL-3.0-or-later
"""The self-test's checks of the keys (#37): the decoder, the keyboard on a fake tty, and the loop
with a fake stdin and a fake terminal (a view switch, wrap-around, the view kept over ticks and a
snapshot change, the help overlay, q, the tty attributes restored before the alternate screen is
left, also after an error; no key reading when stdin is not a tty)."""
import io
import os
import re

from rich.console import Console

from .keys import Keyboard, decode
from .screen import ALT_OFF, SHOW, Display
from .views import State, render_view, run

ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;[^\x1b]*\x1b\\")


def decoder_checks(check):
    single = {"1": "1", "4": "4", "\t": "next", "q": "q", "p": "p", "a": "a", "r": "r", "?": "?", "j": "down",
              "k": "up", "\x03": "q", "\r": None, "x": None}
    for ch, want in single.items():
        check(decode(ch, True) == ([want] if want else [], ""), "keys: %r decodes to %r, not %r" % (ch, want, decode(ch, True)))
    seqs = {"\x1b[A": "up", "\x1b[B": "down", "\x1b[C": "next", "\x1b[D": "prev", "\x1bOA": "up", "\x1bOB": "down",
            "\x1bOC": "next", "\x1bOD": "prev", "\x1b[Z": "prev", "\x1b[5~": "pgup", "\x1b[6~": "pgdn",
            "\x1b[H": "home", "\x1b[F": "end", "\x1bOH": "home", "\x1bOF": "end", "\x1b[1~": "home",
            "\x1b[4~": "end", "\x1b[7~": "home", "\x1b[8~": "end"}
    for s, want in seqs.items():
        check(decode(s, True) == ([want], ""), "keys: %r decodes to %r, not %r" % (s, want, decode(s, True)))
    check(decode("2\x1b[B\x1b[Zq", True) == (["2", "down", "prev", "q"], ""), "keys: several keys in one read")
    # a sequence split over two reads: the first part is kept for the next read, never a key
    check(decode("j\x1b[", False) == (["down"], "\x1b["), "keys: a split sequence is not kept: %r" % (decode("j\x1b[", False),))
    check(decode("\x1b[" + "6~", False) == (["pgdn"], ""), "keys: the split sequence's rest")
    check(decode("\x1b", False) == ([], "\x1b"), "keys: a lone ESC is not kept while more may come")
    check(decode("\x1b", True) == ([], ""), "keys: a lone ESC is not dropped")
    check(decode("\x1b[", True) == ([], ""), "keys: an unfinished sequence at the end is not dropped")
    check(decode("\x1b[15;2~1", True) == (["1"], ""), "keys: an unknown sequence is not dropped: %r" % (decode("\x1b[15;2~1", True),))
    check(decode("\x1bx2", True) == (["2"], ""), "keys: ESC and a letter (Alt) is not dropped")
    check(decode("\x00\xff\x7fé\x1b[999999", True) == ([], ""), "keys: garbage gives a key: %r" % (decode("\x00\xff\x7fé\x1b[999999", True),))


class FakeTermios:
    """termios on a pipe: records each call in the shared log."""
    ICANON, ECHO, ISIG, TCSANOW, TCSAFLUSH, VMIN, VTIME = 2, 8, 1, 0, 2, 6, 5
    error = OSError

    def __init__(self, log):
        self.log = log

    def tcgetattr(self, fd):
        return [0, 0, 0, self.ICANON | self.ECHO | self.ISIG, 0, 0, [b"\x00"] * 32]

    def tcsetattr(self, fd, when, attrs):
        self.log.append(("tty", "cbreak" if not attrs[3] & self.ICANON else "restored", bool(attrs[3] & self.ISIG)))


class Term(io.StringIO):
    def __init__(self, log):
        super().__init__()
        self.log = log

    def write(self, s):
        self.log.append(("write", s))
        return len(s)

    def flush(self):
        pass


def keyboard_checks(check):
    log = []
    r, w = os.pipe()
    try:
        kb = Keyboard(r, isatty=lambda fd: True, termios=FakeTermios(log))
        with kb:
            check(log == [("tty", "cbreak", True)], "keys: cbreak mode (ICANON and ECHO off, ISIG kept) %r" % log)
            os.write(w, b"2")
            check(kb.wait(0.01) == ["2"], "keys: the keyboard reads a key")
            os.write(w, b"j\x1b[")
            check(kb.wait(0.01) == ["down"] and kb.rest == "", "keys: an unfinished sequence is kept past its wait")
            reads = ["1\x1b[", "6", "~"]
            real, kb.read = kb.read, lambda t: reads.pop(0) if reads else ""
            check(kb.wait(0.01) == ["1", "pgdn"], "keys: the keyboard does not join a split sequence")
            kb.read = real
            os.write(w, b"\x1b")
            check(kb.wait(0.01) == [], "keys: a lone ESC gives a key")
            check(kb.wait(0.01) == [], "keys: nothing to read gives a key")
        check(log[-1] == ("tty", "restored", True), "keys: the attributes are not restored on exit")
        log.clear()
        kb = Keyboard(r, isatty=lambda fd: False, termios=FakeTermios(log))
        with kb:
            os.write(w, b"q")
            check(kb.wait(0.01) == [] and not kb.active, "keys: keys are read when stdin is not a tty")
        check(log == [], "keys: the tty attributes are touched when stdin is not a tty")
        os.close(w)
        log.clear()
        kb = Keyboard(r, isatty=lambda fd: True, termios=FakeTermios(log))
        with kb:
            check(kb.wait(0.01) == ["q"], "keys: the key left in the tty before it went is not read")
            check(kb.wait(0.01) == [] and not kb.active, "keys: a tty that is gone (end of file) is still read")
        check(log[-1] == ("tty", "restored", True), "keys: the attributes are not restored after the tty is gone")
    finally:
        for fd in (r, w):
            try:
                os.close(fd)
            except OSError:
                pass


def loop(snaps, keys, width=100, height=30, error_at=None, state=None):
    """Runs the loop on a fake terminal, one batch of keys per tick ([] for a tick with none);
    (log of tty calls and writes, the screens as plain lines after each write, the state)."""
    log = []
    con = Console(file=io.StringIO(), width=width, height=height, force_terminal=True, color_system="256")
    term = Term(log)
    r, w = os.pipe()
    batches = list(keys)
    state = state or State()
    clock = [1920232860.0]
    screen = [""] * height
    frames = []

    def frame(st):
        snap = snaps[min(len(frames), len(snaps) - 1)]
        if error_at is not None and len(frames) == error_at:
            raise RuntimeError("boom")
        frames.append(st.view)
        return render_view(st, [("tools", snap)], clock[0], con.width, con.height)

    class Kb(Keyboard):
        def wait(self, timeout):
            clock[0] += timeout
            if not batches:
                raise KeyboardInterrupt
            b = batches.pop(0)
            if b:
                os.write(w, b.encode())
            return Keyboard.wait(self, 0.001)
    try:
        try:
            run(Display(con, term), Kb(r, isatty=lambda fd: True, termios=FakeTermios(log)), state, frame,
                clock=lambda: clock[0])
        except (KeyboardInterrupt, RuntimeError):
            pass
    finally:
        os.close(r)
        os.close(w)
    shots = []
    for entry in log:
        if entry[0] != "write":
            continue
        s = entry[1]
        for m in re.finditer(r"\x1b\[(\d+);1H(.*?)(?=\x1b\[\d+;1H|\x1b\[\?2026l|$)", s, re.S):
            screen[int(m.group(1)) - 1] = ANSI.sub("", m.group(2))
        shots.append(list(screen))
    return log, shots, state


def loop_checks(snap, check):
    log, shots, st = loop([snap], ["2", "", "\t\t\t", "\x1b[Z", "?", "x", "q"])
    bars = [s[-1] for s in shots if s[-1].strip()]
    check(any("[2 Projects]" in b for b in bars), "loop: 2 does not switch to Projects")
    first = next((i for i, b in enumerate(bars) if "[2 Projects]" in b), len(bars))
    check(any("[1 Summary" in b for b in bars[first:]), "loop: Tab ×3 from Projects does not wrap to the Summary")
    check(st.view == 3 and any("[4 Activity]" in b for b in bars), "loop: Shift-Tab from the Summary does not wrap to Activity")
    writes = [e[1] for e in log if e[0] == "write"]
    check(len(writes) == len(shots), "loop: a write per screen")
    log2, shots2, st2 = loop([snap, dict(snap, events=[])], ["3", "", "", ""])
    check(st2.view == 2 and all("[3 Roadmap]" in s[-1] for s in shots2[2:-1]),
          "loop: the view is not kept over ticks and a new snapshot")
    check(any("any key closes it" in " ".join(s) for s in shots), "loop: no help overlay")
    tty = [k for k in log if k[0] == "tty"]
    check(tty[0] == ("tty", "cbreak", True) and tty[-1] == ("tty", "restored", True), "loop: the tty is not restored on q")
    last_tty = max(i for i, k in enumerate(log) if k[0] == "tty")
    leave = max(i for i, k in enumerate(log) if k[0] == "write" and ALT_OFF in k[1])
    check(last_tty < leave, "loop: the tty is restored after the alternate screen is left")
    check(log[-1][0] == "write" and log[-1][1].endswith(SHOW + ALT_OFF), "loop: q does not show the cursor and leave")
    log, _, _ = loop([snap], ["2", ""], error_at=1)
    last_tty = max(i for i, k in enumerate(log) if k[0] == "tty")
    check(log[last_tty] == ("tty", "restored", True) and log[-1][1].endswith(SHOW + ALT_OFF) and last_tty < len(log) - 1,
          "loop: an error does not restore the tty before leaving the alternate screen")
    # a key that changes nothing writes nothing: Summary, then 1 again
    log, _, _ = loop([snap], ["1", ""])
    writes = [e[1] for e in log if e[0] == "write"]
    check(len(writes) == 3, "loop: a key that changes nothing is written (%d writes, not 3)" % len(writes))
    # rotation: a over a few ticks switches the view, a key stops it
    st = State(rotate=1)
    log, shots, st = loop([snap], ["", "", "", "j"], state=st)
    check(st.rotate is None and any("[2 Projects]" in s[-1] for s in shots),
          "loop: rotation does not switch, or a key does not stop it")


def key_checks(snap, check):
    decoder_checks(check)
    keyboard_checks(check)
    loop_checks(snap, check)
