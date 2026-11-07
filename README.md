<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# canccu-dispatcher

Run Claude Code workers, independent reviewers and planners against GitHub issues: work
packages, risk-based merges and a terminal monitor.

**Pre-release.** The commands, the run engine and the monitor are here, with their offline
tests; the installer and the documentation come next. Until then:

- `bin/canccu-*` are the commands; `libexec/canccu-worker` is the run engine they call.
- `bin/canccu-init [--profile <template>] <name> <owner/repo>` adds a project under
  `~/.canccu/projects/<name>/` from `profiles/default` (or your own template in
  `~/.canccu/profiles/<template>/`). Set `USER_LOGIN` and `REVIEWER_LOGIN` in `~/.canccu/config`:
  there are no defaults.
- `bin/canccu-monitor` needs Python 3 and `rich` (`lib/canccu-monitor.requirements.txt`) in the
  venv `CANCCU_VENV` (default `~/.local/share/canccu/venv`).
- `tests/run` runs the local check; `CLAUDE.md` and `AGENTS.md` hold the rules for changes.

Licence: AGPL-3.0-or-later (`LICENSE`).
