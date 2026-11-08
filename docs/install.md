<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Installing canccu-dispatcher

The installer puts a release of the tool under a prefix, keeps the last few, and links its
commands into `PREFIX/bin`. It never changes a file a running dispatcher uses. It touches the
state dir only to write a missing config and to add a host profile.

## Requirements

Linux with:

| Tool | Minimum | How to get it |
|---|---|---|
| GNU coreutils (or a compatible one, such as uutils), `flock` (util-linux), procps | — | the distribution's packages |
| bash | bash 5.0 | `apt install bash` |
| git | git 2.30 | `apt install git` |
| gh, logged in | — | <https://cli.github.com>, then `gh auth login` (or a project's own login: `canccu-init` prints the steps) |
| jq | jq 1.6 | `apt install jq` |
| tmux | tmux 3.2 | `apt install tmux` |
| python3 | python3 3.10 | `apt install python3` (the monitor's pinned packages need 3.10) |
| claude | Claude Code 2.1.319 | `claude update` |

Claude Code 2.1.319 is the oldest version the run engine was tested with. The check looks for
every flag the engine passes to `claude` in `claude --help`, not for a version number.
`install.sh --check` runs the check on its own. When a tool is missing or too old, the
installer names it with how to get it, exits 2 and installs nothing.

## Install

From a release tarball or a checkout:

    ./install.sh [--prefix DIR] [--host-profile NAME] [--venv DIR] [--no-monitor] [--replace-links] [--dev]

- The prefix defaults to `~/.local`.
- The tree is copied to `PREFIX/lib/canccu-dispatcher/releases/<version>/`. From a git
  checkout only the tracked files are copied, and the release is named `<version>+<commit>`.
  With uncommitted changes it is `<version>+<commit>.dirty.<hash>`, so each edit makes a new
  release.
- `PREFIX/lib/canccu-dispatcher/current` is switched to the new release in one rename.
- Each command is linked as `PREFIX/bin/<command>` → `…/current/bin/<command>`.
- Installing the same tree again changes nothing.
- A release with the same name but other files (a tarball that reuses a version) is replaced
  only while it is not current and no process runs from it. Otherwise the install refuses:
  give the tree a new `VERSION`.

`--dev` points `current` at the checkout itself, for work on the tool. Live projects must not
run on it: a branch switch or an edit changes the dispatcher under them.

### Links

- A `canccu-*` link in `PREFIX/bin` that points into another directory (for example, an older
  install that linked a checkout's `bin/`) is named and kept. `--replace-links` replaces it.
- A regular file of a command's name is never replaced.
- Until the old links are replaced, the commands on `PATH` keep running the old install, so
  the dispatchers that run today keep working.

### The monitor venv

The monitor's pinned packages (`lib/canccu-monitor.requirements.txt`) go into a venv: `--venv
DIR`, else `CANCCU_VENV`, else `~/.local/share/canccu/venv`. It is built with `uv` when there is
one, else with `python3 -m venv` and pip. It is rebuilt only when the requirements change: the
venv keeps their hash in `.requirements.sha256`. A failed build warns and installs the rest.
The installer builds only into a dir it owns: a missing or empty one, one that holds its marker
or the trace of its own failed build (`.canccu-building`, removed once a build succeeds), or the
venv this install recorded. A failed build is retried by the next install. A dir with other files is left alone, with a warning, because
uninstall removes the venv it recorded. `--no-monitor` skips the venv. The monitor finds a venv in another place through `CANCCU_VENV`,
and runs the system `python3` while the venv holds the trace of a failed build.

### The state dir

The state dir is `~/.canccu`, or `CANCCU_ROOT`. The installer leaves it alone, with two
exceptions:

- a missing `config` is written with every default commented out;
- `--host-profile NAME` adds `HOST_PROFILE=NAME` to a config without that key. A config that
  names another profile keeps it, and the installer says so.

The installer never creates, moves or migrates a project: `canccu-init` adds one.

## Host profiles

A host profile holds the values that suit the Claude plan and the host: caps, budgets and the
usage throttle. `hosts/max.conf` pins today's defaults. The profile's name comes from
`CANCCU_HOST_PROFILE`, else from `HOST_PROFILE` in `~/.canccu/config`. The tools read that file
in a subshell for this, so nothing else in it applies before the profile. An unknown profile is
refused with the list.

The load order is:

1. `lib/canccu-config.default`;
2. `hosts/<profile>.conf`;
3. `~/.canccu/config`;
4. the project's `rules`;
5. the project's `config`.

A later file wins. A profile never sets `HOST_PROFILE`, and `TOTAL_CAP` is read only up to
`~/.canccu/config`.

Set the profile in `~/.canccu/config`, so every process reads it. `CANCCU_HOST_PROFILE` is
for one command. A tmux server that is already running keeps the environment it started with,
so a dispatcher that `canccu-up` starts there does not see a `CANCCU_HOST_PROFILE` exported
in your shell later. `CANCCU_ROOT` behaves the same way.

## Upgrade, rollback, uninstall

- **Upgrade**: run `install.sh` from the new tree. A running dispatcher keeps the release it
  started from, because every command finds its files through its real path. The installer
  names each process still on an older release; restart those to pick up the new one.
- **Pruning**: the last three releases are kept; a release a rollback switched away from counts
  last, so it goes before a good one. A release that a live dispatcher or run still uses is
  never removed. The installer finds those from the processes' paths: their arguments,
  their working dir, and the files they hold open (bash holds the script it runs).
- **`canccu-dispatcher rollback [--prefix DIR]`** points `current` at the release made
  current before it, passing any release a rollback switched away from (it is marked
  `.rolled-back` until it is made current again). Installing A, then B, then A again, a rollback
  goes back to B. A, B, C, rollback (to B), D, rollback goes back to B, never to C. From
  `--dev` it goes to the newest release. The links in `PREFIX/bin` follow: a command the newer
  release dropped is linked again, and one only it had goes.
- **`canccu-dispatcher uninstall [--prefix DIR] [--purge-state --yes] [--force]`** removes:
  - the links into its own tree;
  - the tree;
  - the monitor venv the installer built.

  It refuses while a dispatcher holds its lock, a run's lock is live, or any process runs from
  this prefix's releases (the monitor holds no lock), unless `--force`. It removes only the venv
  this install recorded, so a venv from an older install stays. Two
  prefixes that share one venv (both on the default) both record it: uninstalling one removes
  it, and the other's next install builds it again. The state dir goes only with
  `--purge-state --yes`, and never while any lock is held: a dispatcher's or a live run's. A
  dir that is no state dir (`/`, your home, or one with neither `config` nor `projects/`) is
  never removed.

`--prefix` defaults to the prefix of the release the command runs from. From a checkout
(`--dev`) it is the prefix of the `PREFIX/bin` link the command was run through, else
`~/.local`.

A release edited by hand is installed again from its tree. If it is current, make another
release current first (install one, or roll back), then install it again; `doctor` says so.

## Version and doctor

`canccu-dispatcher --version` prints the version, plus the commit when run from a checkout.
`canccu-status` shows the version in its first line, the status snapshot carries it in
`version`, and the monitor shows it in its header.

`canccu-dispatcher doctor [--project <name>]` checks:

- the dependencies above;
- the install: a complete release, the links, `PATH`, and processes left on an older release;
- the host profile, and `USER_LOGIN` and `REVIEWER_LOGIN`;
- the reviewer token file: present, mode 600, and covered by a `Read` deny rule in
  `~/.claude/settings.json` (it is never read);
- for each project: its config, rules, clone, gh credential and dispatcher lock;
- the snapshot's age (while the dispatcher runs) and `ok`;
- stale run locks.

It prints one line per problem and exits 0 when clean.
