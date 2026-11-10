<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The run engine

Part of the reference; the index is [`README.md`](README.md).

## Run engine

`canccu-dispatch` does not run Claude itself. It calls `libexec/canccu-worker`, the run engine,
which runs one headless `claude -p` session in its own tmux window, with a budget, and records
how it ended. It refuses to run unless a `canccu-*` command started it (they set `CANCCU_HOME`,
`WORKERS_DIR` and `CODE_ROOT`).

```
canccu-worker [--key K] [--dir D] [--name N] [--model M] [--untrusted] [--keep-session] [--quiet]
              <repo> "<prompt>" turns=<n> cost=<usd> min=<n>
canccu-worker --unlock <repo> <key>
canccu-worker --kill <repo> <key>
```

- **The key**: `--key K`, else the issue number the prompt starts with. A numeric key (an issue)
  and `--keep-session` (a package) keep the session id in `workers/<repo>-<key>.id`, so every
  later run resumes it; any other key (a review, an answerer, a planner) starts fresh, so a
  reviewer never resumes the worker's session or an older review.
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
  them. A run whose log is silent for `STALL_MIN` minutes is killed as stalled.
- **The exit report** is `workers/<repo>-<key>.last`; its first line carries the status (`done`,
  `error: …`, `blocked`, `stopped: <which budget>`, `stalled: …`, `crashed (exit N)`). Each finished or killed run adds one line to
  `workers/spend.log` (the format: [`state.md`](state.md#the-spend-log)). `WORKER_EFFORT` (the
  dispatcher sets it from `HEALTH_EFFORT` for the health pass) becomes `--effort`.
- `ADD_DIRS` become `--add-dir` flags; the rules' `EXCLUSIVE_WORKER_RE` stops two matching issues
  from running at once in a repo.
- **No run holds a GitHub token**: `GH_TOKEN`, `GITHUB_TOKEN` and `REVIEWER_TOKEN_FILE` are removed
  before the engine starts, sent empty into every window (overriding what the tmux server
  inherited), and unset again before `claude` starts. Runs use the project's `gh` config dir
  ([`projects.md`](projects.md)).

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
