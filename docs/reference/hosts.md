<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Hosts

Part of the reference; the index is [`README.md`](README.md). Every config key is in
[`config.md`](config.md).

## Host profiles

A host profile pins only the values that depend on the Claude plan: the caps, the budgets, the
usage throttle, the run models, the review effort and the test tier. Every other key is the same
under both (`tests/canccu-hosts.sh` checks), so a later change to the defaults does not move a
running host.
`~/.canccu/config` overrides any of them. `install.sh --host-profile <name>` adds
`HOST_PROFILE=<name>` to a config without that key.

| Key | `max` | `pro` |
| --- | --- | --- |
| `CAP`, `TOTAL_CAP` | `2`, `2` | `1`, `1` |
| every `BUDGET_*` key, `STEP_BUDGET` | today's defaults | the same as `max` |
| `USAGE_SLOW`, `USAGE_STOP`, `USAGE_WEEKLY_DRAIN` | `60`, `90`, `90` | `80`, `95`, `90` |
| `MODEL` (workers) | `claude-opus-5-5` | `claude-sonnet-5-5` |
| `FIX_MODEL` | empty: `MODEL` | `claude-sonnet-5-5` |
| `PLAN_MODEL` | `claude-opus-5-5` | `claude-opus-5-5` |
| `REVIEW_MODEL` | `claude-opus-5-5` | `claude-opus-5-5` |
| `REVIEW_MODEL_LIGHT` | empty: `REVIEW_MODEL` | empty: `REVIEW_MODEL` |
| `FIXCHECK_MODEL` | empty: `MODEL` | `claude-opus-5-5` |
| `HEALTH_MODEL` | empty: `MODEL` | `claude-sonnet-5-5` |
| `REVIEW_EFFORT_MAX`, `DEEP_REVIEW_EFFORT` | `high`, `high` | `medium`, `medium` |
| `TEST_TIER` | `targeted` | `targeted` |

The Pro limit is parallelism, not run length: one run at a time, with the same budgets as
`max` (the product owner's decision in #168). Under v2 a Max host runs two at once. A Pro
review never runs above medium effort, a risky or gated path included (`medium capped` in the
review's log line).

### The test tier

`TEST_TIER` decides what a run tests locally, and the worker's prompt says so: `targeted` (both
profiles, and the default) runs only the test files of the areas the run touched plus the repo
checks (`tests/run repo`), never the full suite; `full` runs the full suite once before the PR is
marked ready, bounded with `timeout 9m` (a foreground command may run 10 minutes at most); it
overrides the "do not run the full suite locally" line of a repo's `AGENTS.md` for that run. A review fix round, a red-CI fix and the fix-check follow the same tier. CI runs the
full suite on every push either way, and it is required before merge. `canccu-dispatcher doctor`
prints the host's tier, and a project's own when its `config` sets another.

To use another value, set its key in `~/.canccu/config` (every project of the host) or in a
project's `config` (that project only); either wins over the profile, for example
`MODEL=claude-opus-5-5` on a Pro host. Without a profile every model key stays empty: the
account's default model.

## Host keys

Keys that differ between hosts but not between plans. A profile never sets them: put them in
`~/.canccu/config`. [`../hosts.md`](../hosts.md) has a Max and a Pro example.

- `CLONE_ROOT` (default `$HOME/code`): where `canccu-init` clones a new project, and where
  `canccu-up`'s panes start. The engine finds each project's repos from its own `CLONE`.
- `EXTRA_PATH` (default empty): dirs put first on `PATH` for every command and run, for the
  tools cron and a fresh tmux server do not find (`claude` in `~/.local/bin`, `bun`).
- `GUARD_VMEM_KB` (default `2000000`): the memory cap of every `gh`, `jq` and `python3` call.
- `WORKER_SKILLS`, `REVIEW_SKILLS`: the skills the prompts name
  ([`../hosts.md`](../hosts.md#skills)).
- `HEALTH_CHECKLIST`, `MERGE_METHOD`, `BASE_BRANCH`: per project as much as per host
  ([`config.md`](config.md)).

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
