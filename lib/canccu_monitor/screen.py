# SPDX-License-Identifier: AGPL-3.0-or-later
"""The terminal: the alternate screen, the hidden cursor, redraws of the changed lines only."""
import io
import re
import time

from rich.console import Console
from rich.screen import Screen

HIDE, SHOW = "\x1b[?25l", "\x1b[?25h"
ALT_ON, ALT_OFF = "\x1b[?1049h", "\x1b[?1049l"
SYNC_ON, SYNC_OFF = "\x1b[?2026h", "\x1b[?2026l"  # synchronized output; ignored where unknown
# rich gives each OSC 8 link a new id at every frame; the same frame must be the same bytes
LINK_ID = re.compile(r"\x1b\]8;id=[^;\x1b]*;")


class Display:
    """The alternate screen with the cursor hidden from start to exit.

    rich's Live(screen=True) rewrote every cell of the screen at each redraw. Its cursor stayed
    hidden, but in tmux the monitor pane is usually not the active one (canccu-up), and tmux
    draws an inactive pane's output with the active pane's cursor showing, so the cursor swept
    across the monitor every 2 s. Here a redraw writes only the lines that changed (nothing at
    all when the frame is the same), each write inside synchronized output and re-hiding the
    cursor; a new terminal size rewrites every line in place, without clearing. Ages are shown
    to the minute (ago), so between snapshots a redraw writes nothing for up to a minute. The
    links (OSC 8) lose rich's per-frame id, so they do not count as a change either."""

    def __init__(self, con, out):
        self.con, self.out, self.size, self.prev = con, out, None, []

    def write(self, s):
        self.out.write(s)
        self.out.flush()

    def __enter__(self):
        self.write(ALT_ON + HIDE + "\x1b[H\x1b[2J")
        return self

    def __exit__(self, *_):
        try:
            self.write(SYNC_OFF + SHOW + ALT_OFF)  # also on Ctrl-C and on an error
        except OSError:  # the terminal is gone (a killed tmux window): keep the first error
            pass

    def lines(self, renderable, width, height):
        """The frame as `height` lines of exactly `width` cells, each with its own colour codes."""
        cap = Console(file=io.StringIO(), width=width, height=height, force_terminal=True,
                      color_system=self.con.color_system, no_color=self.con.no_color)
        cap.print(Screen(renderable), end="")
        return LINK_ID.sub("\x1b]8;;", cap.file.getvalue()).split("\n")

    def draw(self, renderable):
        width, height = self.con.size
        lines = self.lines(renderable, width, height)
        if (width, height) != self.size:
            self.size, self.prev = (width, height), []
        changed = [(n, line) for n, line in enumerate(lines)
                   if n >= len(self.prev) or self.prev[n] != line]
        self.prev = lines
        if changed:
            self.write(SYNC_ON + HIDE + "".join("\x1b[%d;1H%s" % (n + 1, line) for n, line in changed)
                       + SYNC_OFF)


def live(display, frame, pause=2, count=None):
    """Draws frame() every `pause` seconds until Ctrl-C (or `count` frames, for the self-test)."""
    with display:
        while count is None or count > 0:
            display.draw(frame())
            count = None if count is None else count - 1
            if count != 0:
                time.sleep(pause)
