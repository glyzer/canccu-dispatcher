# SPDX-License-Identifier: AGPL-3.0-or-later
"""canccu-monitor [--project <name>] — the live command center of the dispatchers.

Run through bin/canccu-monitor, which picks the venv's Python (rich). Reads only the status
snapshots canccu-dispatch writes after every pass (~/.canccu/projects/<name>/status.json; schema
in docs/canccu-dispatch.md, "Status snapshot"): the project's, and the other projects' for the
one view of all. It never calls GitHub, git or tmux and never changes anything. Redraws
every 2 s and reads no keys (Ctrl-C ends it). The cursor stays hidden the whole run: a redraw
writes only the lines that changed. The layout is "Inbox First", top to bottom: the header,
the NEEDS YOU box, NOW, ROADMAP (one column per project), RECENT; it fits the terminal's height,
dropping the less important parts first (never the NEEDS YOU box). Up to 80 columns it uses the
phone form. NO_COLOR turns colour off. The parts are in lib/canccu_monitor/.

  canccu-monitor --self-test   renders the #62 mockup (tests/fixtures/monitor/inbox/) at 120x55,
                               140x65, 100x40, 80x30 and 60x30 and every fixture in
                               tests/fixtures/monitor/, offline; exit 0 when every check passes
  canccu-monitor --file <snapshot> --once [--width N] [--height N] [--now EPOCH]
                               one frame of that file to stdout (for tests and a quick look;
                               no --height: no limit)

--project <name> picks the project (else CANCCU_PROJECT, ~/.canccu/default-project, the only one).
"""
import os
import signal
import sys
import time

# python -I puts no script dir on the path: the parts live beside this file; no __pycache__ in
# the tool's checkout
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from canccu_monitor.data import canccu_root, check_project, load, others, pick_project  # noqa: E402


def load_rich():
    """rich and the parts that draw, imported once the arguments are checked (an unknown project
    is refused without rich)."""
    try:
        import rich  # noqa: F401
    except ImportError:
        req = os.path.join(os.path.dirname(os.path.realpath(__file__)), "canccu-monitor.requirements.txt")
        sys.exit("canccu-monitor: needs the Python package rich: install %s into the venv %s "
                 "(see README.md)" % (req.replace(os.path.expanduser("~"), "~", 1),
                                      os.environ.get("CANCCU_VENV") or "~/.local/share/canccu/venv"))
    from rich.console import Console
    from canccu_monitor import draw, screen, selftest
    return Console, draw, screen, selftest


def main(argv):
    args, project, path, once, width, height, now = list(argv), None, None, False, None, None, None
    while args:
        a = args.pop(0)
        if a == "--project" and args:
            project = check_project(canccu_root(), args.pop(0))
        elif a.startswith("--project="):
            project = check_project(canccu_root(), a.split("=", 1)[1])
        elif a == "--self-test":
            return load_rich()[3].self_test()
        elif a == "--file" and args:
            path = args.pop(0)
        elif a == "--once":
            once = True
        elif a == "--width" and args:
            width = int(args.pop(0))
        elif a == "--height" and args:
            height = int(args.pop(0))
        elif a == "--now" and args:
            now = float(args.pop(0))
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    root = canccu_root()
    if path is None:
        project = pick_project(root, project)
        path = os.path.join(root, "projects", project, "status.json")
    Console, draw, screen, _ = load_rich()
    if once:
        con = Console(width=width) if width else Console()
        snap, err = load(path)
        con.print(draw.render(snap, err, now or time.time(), con.width, others(root, project) if project else [], project,
                              height))
        return 0
    con = Console()

    def frame():
        snap, err = load(path)
        return draw.render(snap, err, time.time(), con.width, others(root, project) if project else [], project,
                           con.height)

    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)  # so a kill shows the cursor again too
    try:
        screen.live(screen.Display(con, con.file), frame)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
