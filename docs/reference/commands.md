<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Commands, labels and whose PRs

Part of the reference; the index is [`README.md`](README.md).

## Roles

| Who | Where | Does |
|---|---|---|
| You | a terminal (ssh into tmux) and GitHub | Decide scope and design, mark issues `ready`, accept the PRs that need you |
| Lead | window `main`, left pane: an interactive `claude` | Writes issues, epics, milestones and blocked-by links with you ([`lead.md`](lead.md)) |
| Monitor | window `main`, right pane: `canccu-monitor` | What needs you, what runs, the roadmap, recent events ([`monitor.md`](monitor.md)) |
| Dispatcher | window `dispatch`: `canccu-dispatch` | Polls GitHub every `INTERVAL`, starts runs, records outcomes as labels, merges. Plain bash: no AI runs in it |
| Workers | window `#<n>` each: headless `claude -p` | One issue (or one work package) each, in its own git worktree; stop at a green PR or a question |
| Reviewers | window `review#<pr>` or `fixcheck#<pr>` | A fresh session per PR head, without the PR's project settings and never with the bot's token; writes its review to a file the dispatcher posts as `REVIEWER_LOGIN` |
| Planner | window `plan#<m>` | Bundles a step's ready issues into work packages; writes a JSON plan, never code |
| Answerers | window `answer#<n>` | Answers a worker's question from the repo's docs, or escalates to you |

## Commands

Every command but `canccu-init` and `canccu-dispatcher` takes `--project <name>` first (or
`CANCCU_PROJECT`; [`projects.md`](projects.md)).

| Command | What it does |
|---|---|
| `canccu-init [--profile <t>] <name> <owner/repo> [clone]` | Adds a project ([`projects.md`](projects.md)) |
| `canccu-up` | Creates the project's tmux session if it is missing: window `main` with the lead and the monitor, window `dispatch` with `canccu-dispatch`, window `shell`; then attaches. Never kills or rearranges a session that exists |
| `canccu-dispatch` | The loop: one pass every `INTERVAL` seconds, one instance per project ([`pipeline.md`](pipeline.md)) |
| `canccu-dispatch --once` | One pass |
| `canccu-dispatch --dry-run` | The runnable queue, every open PR's classification and what one pass would do. Writes nothing: no labels, comments, merges, state, log or snapshot |
| `canccu-status` | The credential, paused or back-off state, the usage, running runs (a review with its effort and model), runs it did not start, PRs awaiting accept, issues that need you, open PRs that are not ours (with the reason), the next runnable issues, each current step and the latest digest. `--spend`: the cost of every merged PR, grouped by model and run type ([`state.md`](state.md#the-spend-log)). `--findings`: the most common review findings and the files cited most ([`reviews.md`](reviews.md)) |
| `canccu-monitor` | The live view, from the status snapshots only ([`monitor.md`](monitor.md)) |
| `canccu-run <n> [message]` | Starts or resumes the worker for issue n by hand (for an issue of a work package: the package). On a resume the message is the follow-up (default `continue`). Refuses while the issue's worker, reviewer or answerer runs |
| `canccu-review <pr>` | Starts the independent reviewer for a PR of ours at its current head. Refuses without the reviewer token and for a PR that is not ours |
| `canccu-classify <pr>` | Prints `auto` or `manual: <first reason>` ([`merging.md`](merging.md)) |
| `canccu-ship <n>` | Your accept: arms auto-merge for our PR that closes issue n, pinned to its head, with the repo's merge method (as the dispatcher's own merge). Where the repo does not allow auto-merge it merges directly once CI is green |
| `canccu-stop <n>` | Stops the worker, reviewer and answerer of issue n (or of its package): sets the phase to `stopped` first, then kills their process trees and windows. Keeps the worktree and the session; `canccu-run <n>` continues it |
| `canccu-stop --forget <n>` | Does what `canccu-stop <n>` does, then the dispatcher lets go of the unit (issue n's package, if it has one): removes its worktree, its run locks, `.id` and `.nudge` files and its state, and removes `in-progress`, `needs-you`, `awaiting-accept` and (only when the dispatcher set it) `blocked` from each of its issues. The PR, the branch and `ready` stay. No confirmation; without state it says `nothing to forget for #<n>` |
| `canccu-pause` / `canccu-resume` | While paused nothing new starts; running runs continue; --usage clears the usage-limit wait after an early reset |
| `canccu-dispatcher --version`, `doctor`, `rollback`, `uninstall` | The installed tool itself ([`../install.md`](../install.md)) |
| `canccu-dispatcher config show [--project <name>] [--global] [--origin] [KEY…]` | Every setting, its default and where it comes from (below) |
| `canccu-dispatcher config set [--project <name> \| --global] KEY=VALUE [--why <text>]` | Checks one setting and writes it to the file it belongs in, with a history line (below) |
| `canccu-dispatcher config unset [--project <name> \| --global] KEY [--why <text>]` | Removes that file's line for one setting, with a history line (below) |
| `canccu-dispatcher wait [--project <name>] [--owner po\|leader] [--ack <id>]` | Blocks until the feed has a line with an id above `--ack` (default: its last id at start) for that owner, prints it and exits 0; exits 3 with `heartbeat stale: <n> min; the dispatcher may be down` when the heartbeat is 10 minutes old ([`lead.md`](lead.md#the-feed)) |

### config show

`canccu-dispatcher config show` prints every setting of a project as the commands read it, one
`KEY=value` line each, in the order of `lib/canccu-config.default`. Without `--project` it shows
the only project; with several it asks for one (status 2). `--global` shows the defaults, the
host profile and `~/.canccu/config` only, and needs no project. `--origin` prints a
tab-separated table with a header: the value, the default, the layer it comes from (`default`,
`host:<profile>`, `global`, `rules` or `project`) and `locked` for a setting a run or the leader
cannot change ([`config.md`](config.md#the-settings-table)). Keys after the options show only
those; an unknown key ends with status 2. The reviewer token and the gh login are shown as paths:
their files are never opened.

```
canccu-dispatcher config show                          # every setting of the only project
canccu-dispatcher config show --project web CAP MODEL  # two settings of project web
canccu-dispatcher config show --global                 # what every project starts from
canccu-dispatcher config show --origin GATED_PATHS     # KEY VALUE DEFAULT ORIGIN LOCKED
```

### config set and config unset

`canccu-dispatcher config set KEY=VALUE` checks the key, its type and its range
([`config.md`](config.md#the-settings-table)) and writes `KEY='VALUE'` to the file the key belongs
in: the project's `rules` or `config`, or with `--global` `~/.canccu/config` (the default for
every project). `config unset KEY` removes that file's line for the key, so the layer before it
applies again. The project is chosen as in `config show`. Both write one line to
`config.history` ([`config.md`](config.md#changing-a-setting)); `--why` puts a reason in it. The
output names the file and ends with `now: <value> (from <origin>)`: what the commands read after
the write, where a later layer may still win. A set to the value the file already has, or an
unset of a key the file does not set, changes nothing and records nothing (status 0).

- Status 2: an unknown key, a value that fails the check (the message says what fits), a key
  the command does not change (`REPO`, `CLONE`, `HOST_PROFILE`, `REVIEWER_TOKEN_FILE`,
  `GH_CONFIG_DIR`: edit the file and restart the dispatcher), or `TOTAL_CAP` without `--global`.
- Status 3: a locked key, when the leader or a run calls (`CANCCU_ACTOR=leader` or `run`): it is
  refused, nothing is written, and the history records the refusal
  ([`../security.md`](../security.md#known-limits)).
- Status 1: the file would not be valid shell after the change; nothing is changed.

```
canccu-dispatcher config set CAP=2 --why "less load"   # the project's config
canccu-dispatcher config unset --project web CAP       # back to the global or default value
```

## Labels

The dispatcher creates any that are missing (`canccu-init` does too):

| Label | On | Means |
|---|---|---|
| `ready` | issue | You agreed the spec: the dispatcher may start it |
| `blocked` | issue | Never started or resumed while it is on. Yours: you remove it. Set by the dispatcher (a worker that stopped blocked): it goes once the issue's blocked-by issues are all closed |
| `in-progress` | issue | The dispatcher manages it |
| `epic` | issue | A roadmap step's umbrella issue; never started |
| `needs-you` | issue, PR | Waits for you: the latest comments say why |
| `plan-ok` | issue | Your OK of a plan-tier plan: the worker resumes and executes it |
| `needs-work` | issue | Resume the worker with your comments since the verdict or accept request |
| `awaiting-accept` | issue | Its PR passed review but waits for your accept |
| `accepted` | PR | Your accept. Only yours counts: the newest such label event must be by `USER_LOGIN`. On the PR's issue it is taken as well, by the same checks |
| `manual-accept` | issue | Forces manual accept for this issue's PR |
| `checkpoint` | issue | A step's checkpoint issue |
| `checkpoint-ok` | issue | Your OK to end a step's checkpoint pause |
| `fast` | issue | An issue of a step that runs alone, in the fast lane |

Every comment the dispatcher posts as you carries `<!-- canccu-dispatch -->`, so it never takes
its own comments for yours. Reviews posted as `REVIEWER_LOGIN` do not: their verdict must stay the
last line.

## Whose PRs

The dispatcher acts only on **our** PRs: from a branch in `REPO` (not a fork), authored by
`USER_LOGIN`, on the branch the worker prompt names (`<n>-<slug>`; `issue-<n>-…` counts too),
closing an issue the dispatcher manages. An open PR of ours that closes an `in-progress` issue
it does not manage yet is adopted. Every other open PR is listed by `canccu-status` and
`--dry-run` as "not ours" with the reason, and is never reviewed, merged or commented on:
`canccu-review` and `canccu-ship` refuse it, and `canccu-classify` prints `manual: not ours: …`.
When several of our PRs close an issue, the newest counts.
