# SPDX-License-Identifier: AGPL-3.0-or-later
"""Reading: the project, its status snapshot and the other projects' (no rich needed here).

The snapshot's schema is in docs/canccu-dispatch.md, "Status snapshot". Every getter returns a
default for a missing or mistyped field, so odd data never raises."""
import json
import os
import re

# C0, DEL and C1: a title from GitHub could otherwise retitle the terminal or clear the screen
_CONTROL = re.compile("[\x00-\x1f\x7f-\x9f]")


def safe_title(s):
    """The text without control characters, a tab as a space (as safe_title in canccu-common.sh)."""
    return _CONTROL.sub("", s.replace("\t", " "))


def canccu_root():
    return os.environ.get("CANCCU_ROOT") or os.path.expanduser("~/.canccu")


def profiles(root):
    d = os.path.join(root, "projects")
    try:
        return sorted(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, "config")))
    except OSError:
        return []


def check_project(root, name):
    """The name, when the project exists; else exit 1 with the list (as canccu-common.sh)."""
    if not os.path.isfile(os.path.join(root, "projects", name, "config")):
        raise SystemExit("canccu-monitor: no project '%s' (%s/projects/%s/config). Projects: %s"
                         % (name, root, name, " ".join(profiles(root)) or "none"))
    return name


def pick_project(root, arg):
    """--project, else CANCCU_PROJECT, else default-project, else the only project (as canccu-projects.sh)."""
    if arg:
        return check_project(root, arg)
    if os.environ.get("CANCCU_PROJECT"):
        return check_project(root, os.environ["CANCCU_PROJECT"])
    try:
        with open(os.path.join(root, "default-project"), encoding="utf-8") as f:
            name = f.read().strip()
        if name:
            return check_project(root, name)
    except OSError:
        pass
    names = profiles(root)
    if len(names) == 1:
        return names[0]
    raise SystemExit("canccu-monitor: which project? --project <name> (projects: %s)" % (" ".join(names) or "none"))


def load(path):
    """(snapshot dict, None) or (None, why it cannot be shown). Never raises."""
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return None, "no snapshot yet (%s): is canccu-dispatch running?" % path
    except OSError as e:
        return None, "cannot read %s: %s" % (path, e.strerror)
    except ValueError:
        return None, "the snapshot is not UTF-8 text"
    if not raw.strip():
        return None, "the snapshot is empty"
    try:
        snap = json.loads(raw)
    except ValueError:
        return None, "the snapshot is not valid JSON (partly written?)"
    if not isinstance(snap, dict):
        return None, "the snapshot is not a JSON object"
    return snap, None


def others(root, project):
    """[(name, snapshot or None)] of the other projects, in name order (one view of all)."""
    out = []
    for name in profiles(root):
        if name != project:
            out.append((name, load(os.path.join(root, "projects", name, "status.json"))[0]))
    return out


def obj(d, key):
    v = d.get(key) if isinstance(d, dict) else None
    return v if isinstance(v, dict) else {}


def lst(d, key):
    v = d.get(key) if isinstance(d, dict) else None
    return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []


def num(d, key):
    v = d.get(key) if isinstance(d, dict) else None
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def txt(d, key, default=""):
    """A text field through safe_title: every title the monitor shows is read here."""
    v = d.get(key) if isinstance(d, dict) else None
    return safe_title(v) if isinstance(v, str) else default


def nums(d, key):
    v = d.get(key) if isinstance(d, dict) else None
    return [x for x in v if isinstance(x, int) and not isinstance(x, bool)] if isinstance(v, list) else []


def local_repo(snap):
    """The clone's name, which a lock's repo= holds (the GitHub name for an older snapshot)."""
    return txt(snap, "repo_name") or txt(snap, "repo").split("/")[-1]


def other_keys(snap):
    """The run keys of this repo held by runs the dispatcher did not start (shown apart)."""
    repo = local_repo(snap)
    return {txt(r, "key") for r in lst(snap, "other_runs") if txt(r, "repo") in (repo, "")}
