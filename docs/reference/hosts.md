<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Hosts

Part of the reference; the index is [`README.md`](README.md). Every config key is in
[`config.md`](config.md).

## Host profiles

A host profile pins the values that depend on the Claude plan and the host, so a later change to
the defaults does not move a running host. `hosts/max.conf` (a Claude Max plan) sets today's
defaults of `CAP`, `TOTAL_CAP`, every `BUDGET_*` key, `STEP_BUDGET`, `USAGE_SLOW`, `USAGE_STOP`
and `USAGE_WEEKLY_DRAIN`. `hosts/pro.conf` (a Claude Pro plan) sets the same keys for one run
at a time with the same budgets as max (the Pro limit is parallelism, not run length), its own
usage throttle, and `REVIEW_EFFORT_MAX=medium`. Neither sets a model.
`~/.canccu/config` overrides any of them. `install.sh --host-profile
<name>` adds `HOST_PROFILE=<name>` to a config without that key.

The tools read `HOST_PROFILE` from `~/.canccu/config` in a subshell, so nothing else in that
file applies before the profile. A tmux server keeps the environment it started with: a
dispatcher that `canccu-up` starts there does not see a `CANCCU_HOST_PROFILE` you export later,
so set the profile in the config file.

## Environment variables

- `CANCCU_ROOT`: the state dir (default `~/.canccu`). The same tmux caveat as above applies.
- `CANCCU_PROJECT`: the project, instead of `--project <name>`; `canccu-up` sets it in every
  pane of a project's session.
- `CANCCU_HOST_PROFILE`: the host profile for one command.
- `CANCCU_VENV`: the monitor's venv (default `~/.local/share/canccu/venv`).
- `CANCCU_TMUX_SESSION`: the default project's tmux session name (default `canccu`).
- `NO_COLOR`: no colour in the dispatcher's pane and the monitor.

Two values are constants in the code, not keys: a usage-limit back-off adds a margin of 120 s
to the reset time (`USAGE_MARGIN`), and a fix-check runs at medium effort above 300 changed lines
(`FIXCHECK_BIG`).
