<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The run engine

Part of the reference; the index is [`README.md`](README.md).

## Run engine

`canccu-dispatch` does not run Claude itself. It calls `libexec/canccu-worker`, the run engine,
which runs one headless `claude -p` session in its own tmux window, with a budget, and records
how it ended. It refuses to run unless a `canccu-*` command started it (they set `CANCCU_HOME`,
`WORKERS_DIR` and `CODE_ROOT`).

```
canccu-worker [--key K] [--dir D] [--name N] [--model M] [--effort E] [--untrusted] [--keep-session]
              [--fresh] [--quiet] <repo> "<prompt>" turns=<n> cost=<usd> min=<n>
canccu-worker --unlock <repo> <key>
canccu-worker --kill <repo> <key>
```

- **The key**: `--key K`, else the issue number the prompt starts with. A numeric key (an issue)
  and `--keep-session` (a package) keep the session id in `workers/<repo>-<key>.id`, so every
  later run resumes it; any other key (a review, an answerer, a planner) starts fresh, so a
  reviewer never resumes the worker's session or an older review. `--fresh` starts a new session
  even for those (a follow-up run with a handoff, below).
- **`--effort E`**: passed to `claude` as `--effort` (`low`, `medium`, `high`, `xhigh`, `max`);
  without it, none: the account's.
- **Where**: an issue runs in its own worktree, `workers/worktrees/<repo>/issue-<n>`; `--dir D`
  runs in an existing worktree instead (the reviewer's at the PR head, a package's).
- **Worker**: `--name '#<n>' <repo> "<n> <prompt>"`. **Reviewer**: `--key review-<pr> --dir
  …/review-<pr> --name 'review#<pr>' --untrusted`. **Answerer**: `--key answer-<n> --untrusted`
  in the issue's worktree, or the main clone when there is none. **Planner**: `--key plan-<m> --untrusted` in a fresh worktree.
- **`--untrusted`**: `claude` runs with `--setting-sources user --strict-mcp-config`, so the
  checkout's `.claude/settings*.json` (hooks, `env`, `apiKeyHelper`) and `.mcp.json` servers
  never load: a PR cannot add a hook that runs during its own review. The flag reaches the run
  as an argument, never through the environment, so it cannot leak into later windows. Workers
  keep their project settings: they work on our own branch.
- **Budgets**: `turns=`, `cost=` (USD) and `min=` are required; the run is stopped at any of
  them. A run whose log is silent for `STALL_MIN` minutes, while no process its tools started
  (the tree below `claude`) is new or spends CPU, is killed as stalled: a long test run with
  short output is not a stall, a hung command waiting idle is. Claude's own CPU does not count.
- **Background work**: a headless run exits when its turn ends, so a command or subagent it
  left running in the background is lost. The stream reader counts each one started with
  `run_in_background` until a later event names its id as done; a run that ends with one still
  pending gets the status `error: ended with background work pending`, never `done`.
- **The exit report** is `workers/<repo>-<key>.last`; its first line carries the status (`done`,
  `error: …` (`error: ended with background work pending` among them), `blocked`, `stopped: <which budget>`, `stalled: …`, `crashed (exit N)`), and just
  before it `fresh` or `resume`: how the run's session started. Each finished or killed run adds one line to
  `workers/spend.log` (the format: [`state.md`](state.md#the-spend-log)). `WORKER_EFFORT` (the
  dispatcher sets it from `HEALTH_EFFORT` for the health pass) becomes `--effort`, as does the flag `--effort`.
- `ADD_DIRS` become `--add-dir` flags; the rules' `EXCLUSIVE_WORKER_RE` stops two matching issues
  from running at once in a repo.
- **No run holds a GitHub token**: `GH_TOKEN`, `GITHUB_TOKEN` and `REVIEWER_TOKEN_FILE` are removed
  before the engine starts, sent empty into every window (overriding what the tmux server
  inherited), and unset again before `claude` starts. Runs use the project's `gh` config dir
  ([`projects.md`](projects.md)).

## Follow-up runs

A resumed session reloads the whole earlier conversation and re-reads it on every turn: measured,
about 8× the cost per turn of a fresh run. So a worker's follow-up (a review fix round, a red-CI
fix, `needs-work`, a merge of main that conflicts, a comment, after a usage stop) starts a fresh
session (`--fresh`) in the same worktree and branch, unless `RESUME_ON` names its kind (default
`answer,plan`: the answer to its `Question:` and plan-ok, where the conversation itself matters).
The fresh session's prompt is the safety block (`SAFETY_BLOCK`: stop on a question with
`Question:`, never merge, rebase, force-push or touch `accepted`, no self-review, no subagents or
background commands, the 5-line report), then the task, then a short handoff: the PR's link and
body (`Decisions made:`, `Follow-up:`), `git log origin/main..HEAD --oneline`, uncommitted files,
the worker's last report (`.last`), and the unit and its branch, with the repo's AGENTS.md and
CLAUDE.md named as the full rules. The block comes first, so the prompt limit can only cut the end
of the handoff.

- **Merge of main**: by script, never an AI run, when git merges cleanly: `git merge --no-edit
  origin/main` in the worktree and a normal push to the PR's branch (never a rebase or a
  force-push). Only when the worktree has the PR's branch checked out and no uncommitted changes
  (untracked files do not count); else the fix run is told main is not in and to merge it first.
  A conflict aborts the merge, and a fresh session gets the conflicting paths: once per head, so
  a run that pushed no resolution leads to `needs-you`. A fetch or push that fails 3 passes in a
  row leads to `needs-you` with git's error.
- **Red CI**: main is merged in first and CI runs again (another merged PR may have caused it);
  still red with main in, a fresh fix session gets the failing GitHub Actions job's log tail
  (`gh run view --job <id> --log-failed`).
- **Cap**: at most `FIX_ATTEMPTS` (default 2) automatic fix runs per PR, review fix rounds and
  red-CI fixes together, then `needs-you`. `needs-work` rounds are yours and never count.
- **Per machine**: a fix run (review fix, red CI, `needs-work`) runs on `FIX_MODEL` and
  `FIX_EFFORT`. Their defaults are empty, as before (`MODEL`, no `--effort`); each machine sets
  its own in `~/.canccu/config`, so a release never changes another machine's models.

## Locks

A lock (`workers/<repo>-<key>.lock`) records the run's pid with its start time and its tmux window
id with the session and window name. It is alive only while that pid runs with the same start
time, or that window exists with the same session and name, so a pid or window id reused after a
reboot never counts. Processes and windows are only ever killed through `canccu-worker --kill`,
which kills a pid only if its command line is that run's, and a window only if it still matches:
the dispatcher never touches a process or window it did not create. When something lives but
nothing matched, the lock stays and `--kill` fails, so a second session never starts on the
issue. `--unlock` clears a stale lock (no process, no window); `canccu-dispatcher doctor` lists
them.

## Guards in the code

- Every `gh`, `jq` and `git` call runs under `timeout` (`guard`), so a hung call never hangs a
  pass.
- Never `pgrep -f` or `pkill -f` with the caller's own command line.
- Never kill a tmux session or window the dispatcher did not create.
