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
| `canccu-ship <n>` | Your accept: arms auto-merge for our PR that closes issue n, pinned to its head. Only where the repo allows auto-merge; otherwise label the PR `accepted` |
| `canccu-stop <n>` | Stops the worker, reviewer and answerer of issue n (or of its package): sets the phase to `stopped` first, then kills their process trees and windows. Keeps the worktree and the session; `canccu-run <n>` continues it |
| `canccu-pause` / `canccu-resume` | While paused nothing new starts; running runs continue; --usage clears the usage-limit wait after an early reset |
| `canccu-dispatcher --version`, `doctor`, `rollback`, `uninstall` | The installed tool itself ([`../install.md`](../install.md)) |

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
| `accepted` | PR | Your accept. Only yours counts: the newest such label event must be by `USER_LOGIN` |
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
