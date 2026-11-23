# SPDX-License-Identifier: AGPL-3.0-or-later
"""The keys: a pure decoder of what the terminal sends, and the keyboard that reads it.

The keyboard reads only when stdin is a tty (--once, a pipe and the self-test read none). It puts
the tty in cbreak mode: ICANON and ECHO off, ISIG kept, so Ctrl-C still raises KeyboardInterrupt
as before. Its exit restores the old attributes; the loop enters it inside the Display, so the
attributes are back before the alternate screen is left, on every exit path (q, Ctrl-C, an
error, SIGTERM, which the program turns into SystemExit). It writes nothing to the terminal."""
import os
import select
import termios as _termios

SINGLE = {"1": "1", "2": "2", "3": "3", "4": "4", "5": "5", "\t": "next", "q": "q", "\x03": "q", "p": "p", "a": "a",
          "r": "r", "?": "?", "j": "down", "k": "up"}
# CSI and SS3 sequences; xterm, tmux, the Linux console and rxvt send Home/End differently
SEQ = {"[A": "up", "[B": "down", "[C": "next", "[D": "prev", "OA": "up", "OB": "down", "OC": "next", "OD": "prev",
       "[Z": "prev", "[5~": "pgup", "[6~": "pgdn", "[H": "home", "[F": "end", "OH": "home", "OF": "end",
       "[1~": "home", "[4~": "end", "[7~": "home", "[8~": "end"}
MAX_SEQ = 16  # a CSI longer than this is garbage, not a key: dropped
SPLIT_WAIT = 0.05  # how long the rest of a split sequence may take before its start is dropped


def decode(buf, final):
    """(keys, rest): the keys in buf and what may be the start of a sequence whose rest has not
    come yet (kept for the next read). final: nothing more is coming, so an unfinished start is
    dropped. A lone ESC, an unknown sequence and any other byte give no key."""
    keys, i = [], 0
    while i < len(buf):
        c = buf[i]
        if c != "\x1b":
            if c in SINGLE:
                keys.append(SINGLE[c])
            i += 1
            continue
        if i + 1 >= len(buf):
            return keys, ("" if final else buf[i:])
        intro = buf[i + 1]
        if intro == "O":
            if i + 2 >= len(buf):
                return keys, ("" if final else buf[i:])
            k = SEQ.get("O" + buf[i + 2])
            keys += [k] if k else []
            i += 3
            continue
        if intro != "[":
            i += 1  # ESC and another key (Alt-x): the ESC is dropped, the key stays
            continue
        j = i + 2
        # parameters and intermediates (0x20-0x3f), then the final byte (0x40-0x7e)
        while j < len(buf) and "\x20" <= buf[j] <= "\x3f" and j - i < MAX_SEQ:
            j += 1
        if j >= len(buf):
            return keys, ("" if final or j - i >= MAX_SEQ else buf[i:])
        if j - i >= MAX_SEQ or not "\x40" <= buf[j] <= "\x7e":
            i = j  # garbage: dropped up to here
            continue
        k = SEQ.get(buf[i + 1:j + 1])
        keys += [k] if k else []
        i = j + 1
    return keys, ""


class Keyboard:
    """The keys of stdin in cbreak mode, while in its with block. wait() is the loop's tick: the
    keys that came within timeout seconds ([] at once when stdin is no tty, after sleeping)."""

    def __init__(self, fd, isatty=os.isatty, termios=_termios):
        self.fd, self.termios, self.old, self.rest = fd, termios, None, ""
        try:
            self.active = bool(isatty(fd))
        except (OSError, ValueError):
            self.active = False

    def __enter__(self):
        if self.active:
            t = self.termios
            try:
                self.old = t.tcgetattr(self.fd)
                new = list(self.old)
                new[3] = new[3] & ~(t.ICANON | t.ECHO)
                new[6] = list(new[6])
                new[6][t.VMIN], new[6][t.VTIME] = 1, 0
                t.tcsetattr(self.fd, t.TCSANOW, new)
            except (t.error, OSError):
                self.active, self.old = False, None
        return self

    def __exit__(self, *_):
        if self.old is not None:
            try:
                self.termios.tcsetattr(self.fd, self.termios.TCSANOW, self.old)
            except (self.termios.error, OSError):  # the tty is gone: nothing to restore
                pass
            self.old = None

    def read(self, timeout):
        """The bytes that came within timeout as text; None when the tty is gone."""
        try:
            ready, _, _ = select.select([self.fd], [], [], max(0.0, timeout))
            if not ready:
                return ""
            data = os.read(self.fd, 256)
        except (OSError, ValueError):
            return None
        return data.decode("latin-1") if data else None

    def wait(self, timeout):
        if not self.active:
            if timeout > 0:
                select.select([], [], [], timeout)
            return []
        data = self.read(timeout)
        if data is None:
            self.active = False  # end of file: no more keys, the frames go on
            return []
        keys, self.rest = decode(self.rest + data, False)
        while self.rest:
            more = self.read(SPLIT_WAIT)
            more_keys, self.rest = decode(self.rest + (more or ""), not more)
            keys += more_keys
        return keys
