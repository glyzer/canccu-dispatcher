<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# canccu-dispatcher

Run Claude Code workers, independent reviewers and planners against GitHub issues: work
packages, risk-based merges and a terminal monitor.

**Pre-release.** The commands, the run engine, the monitor and the installer are here, with
their offline tests; more documentation comes next.

- `./install.sh` installs a release under `~/.local` (`--check` checks the dependencies first);
  `canccu-dispatcher doctor`, `rollback` and `uninstall` look after it. See `docs/install.md`.
- `bin/canccu-*` are the commands; `libexec/canccu-worker` is the run engine they call.
- `bin/canccu-init [--profile <template>] <name> <owner/repo>` adds a project under
  `~/.canccu/projects/<name>/` from `profiles/default` (or your own template in
  `~/.canccu/profiles/<template>/`). Set `USER_LOGIN` and `REVIEWER_LOGIN` in `~/.canccu/config`:
  there are no defaults.
- `bin/canccu-monitor` needs Python 3 and `rich` (`lib/canccu-monitor.requirements.txt`) in the
  venv `CANCCU_VENV` (default `~/.local/share/canccu/venv`).
- `templates/repo/` holds the review gate a target repo adds (`templates/README.md`).
- `tests/run` runs the local check; `CLAUDE.md` and `AGENTS.md` hold the rules for changes.

Licence: AGPL-3.0-or-later (`LICENSE`).
