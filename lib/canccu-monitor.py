# SPDX-License-Identifier: AGPL-3.0-or-later
"""canccu-monitor [--project <name>] [--view <name>] [--rotate [secs]] — the live command center
of the dispatchers.

Run through bin/canccu-monitor, which picks the venv's Python (rich). Reads only the status
snapshots canccu-dispatch writes after every pass (~/.canccu/projects/<name>/status.json; schema
in docs/reference/snapshot.md): the project's, and the other projects' for the one view of all.
It never calls GitHub, git or tmux and never changes anything. Five views (lib/canccu_monitor/
views.py): Summary (the default), Projects, Roadmap, Activity and Queue; keys 1-5, Tab and the arrows
switch, the arrows, j/k, PgUp/PgDn and Home/End scroll, p cycles the Projects focus, a rotates
the views, r redraws, ? shows the keys, q or Ctrl-C quits. Keys are read only when stdin is a
tty. Redraws every 2 s and at once after a key; the cursor stays hidden the whole run and a
redraw writes only the lines that changed. Up to 80 columns every view has its phone form.
NO_COLOR turns colour off.

  --view <name>                the start view: summary, projects, roadmap, activity, queue (or 1-5)
  --rotate [secs]              cycle the views (default 30 s, the Summary twice as long); any
                               key but a stops it
  canccu-monitor --self-test   renders the mockup (tests/fixtures/monitor/inbox/) and every
                               fixture in tests/fixtures/monitor/ in every view at several
                               sizes, and drives the keys on a fake terminal, offline; exit 0
                               when every check passes
  canccu-monitor --file <snapshot> --once [--view <name>] [--width N] [--height N] [--now EPOCH]
                               one frame of that file to stdout (for tests and a quick look;
                               no --height: no limit; reads no keys)

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
from canccu_monitor.data import canccu_root, check_project, load, others, pick_project, txt  # noqa: E402


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
    from canccu_monitor import keys, screen, selftest, views
    return Console, keys, screen, selftest, views


def main(argv):
    args, project, path, once, width, height, now = list(argv), None, None, False, None, None, None
    view, rotate = "summary", None
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
        elif a == "--view" and args:
            view = args.pop(0)
        elif a.startswith("--view="):
            view = a.split("=", 1)[1]
        elif a == "--rotate":
            rotate = 30
            if args and args[0].isdigit():
                # 0 would switch views every tick: refuse it rather than fall into the usage text
                rotate = int(args.pop(0))
                if rotate < 1:
                    sys.exit("canccu-monitor: --rotate needs at least 1 second (or no number for 30)")
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    root = canccu_root()
    if path is None:
        project = pick_project(root, project)
        path = os.path.join(root, "projects", project, "status.json")
    Console, keys, screen, _, views = load_rich()
    start = views.view_index(view)
    if start is None:
        sys.exit("canccu-monitor: no view '%s' (views: %s)" % (view, ", ".join(n.lower() for n in views.NAMES)))
    state = views.State(start, rotate)

    def frame(st, width_, height_, now_):
        snap, err = load(path)
        projects = [(project or txt(snap, "project", "?"), snap)] + (others(root, project) if project else [])
        return views.render_view(st, projects, now_, width_, height_, err)
    if once:
        con = Console(width=width) if width else Console()
        con.print(frame(state, con.width, height, now or time.time()))
        return 0
    con = Console()

    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)  # so a kill restores the tty and shows the cursor too
    try:
        views.run(screen.Display(con, con.file), keys.Keyboard(sys.stdin.fileno()), state,
                  lambda st: frame(st, con.width, con.height, time.time()))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
