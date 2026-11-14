<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# S2: the hardened level

The design of package S2's second Unix user. At the hardened level every Claude session (worker,
reviewer, fix-check, answerer, planner, the leader) runs as a second Unix user, the **run
user**, that cannot read the dispatcher's home. A fooled session then can neither read the
reviewer token nor accept as the product owner. The build issues of section 10 come from this
file. The names, paths and texts below are fixed here as `contracts.md` fixes its own: a build
issue uses them as written. Verified against main at 72b636e.

Words used below: **the dispatcher's user** is the Unix user that installed the tool and runs
`canccu-dispatch` (`<you>` in commands); **the run user** is the second one (`canccu-run` in
commands, the value of `RUN_USER`); **the run home** is the run user's home,
`/var/lib/canccu-run`; **the helpers** are the two root-owned scripts of section 2.

## 0. What changes, in one picture

| | Simple level (today) | Hardened level |
|---|---|---|
| `claude` runs as | the dispatcher's user | the run user |
| Worktrees, run temp dirs, review files the run writes | `~/.canccu/projects/<p>/workers/…`, `~/.canccu/projects/<p>/reviews/…` | `/var/lib/canccu-run/projects/<p>/…` |
| The clone runs work in | `CLONE` (the dispatcher's) | the run user's own clone of the repo |
| gh login of a run | the project's (`~/.canccu/projects/<p>/gh`) | the run user's own (`/var/lib/canccu-run/projects/<p>/gh`) |
| The dispatcher's home, state, tokens | readable by every run | mode 700, unreachable by the run user |
| The tmux window, the wrapper, the stream, `.last`, the spend log | the dispatcher's user | unchanged: still the dispatcher's user |
| Leader commands | any command, as the dispatcher's user | the gate's list only (section 4) |

The split: the shell parts (the engine's wrapper, the watchdog, the stream reader, every
GitHub write, the reviewer token) stay with the dispatcher's user. Only the `claude` process
and what it starts cross to the run user, through one fixed sudo rule.

## 1. The run user

**Setting.** `RUN_USER`, default empty, in `~/.canccu/config` only (one run user per host, for
every project), not settable through `config set` (file `fixed` in `lib/canccu-settings.tsv`),
locked. Empty: the simple level. Set: the hardened level, and every run of every project runs
as that user. Config comment:
`# the Unix user every Claude session runs as (the hardened level, docs/security.md); empty: the simple level, every session runs as you`.
A second setting, `RUN_LOGIN` (project, locked, default empty), names the GitHub login the run
user's token belongs to (section 6). Both are in `contracts.md` §5.

**Creation.** The root part is one idempotent script, `libexec/canccu-harden`:

```
canccu-harden --dispatcher-user <you> --run-user canccu-run
```

It refuses unless it runs as root, unless `<you>` exists and is not root, and unless the run
user's name is not `<you>`. Then, in this order, each step skipped when already in place:

1. `useradd --system --user-group --create-home --home-dir /var/lib/canccu-run --shell /bin/bash canccu-run`
   (bash: Claude's Bash tool needs a shell). No password: `passwd -l canccu-run`.
2. `chmod 700 /var/lib/canccu-run`; `install -d -o canccu-run -g canccu-run -m 700 /var/lib/canccu-run/projects`.
3. `chmod 700 ~<you>/.canccu`, and `chmod o-rwx ~<you>` (the home keeps its group bits; the
   run user is in no group of `<you>`, which doctor checks).
4. `install -d -o root -g root -m 755 /usr/local/libexec/canccu-dispatcher`, then
   `install -o root -g root -m 755 <tree>/libexec/canccu-runas <tree>/libexec/canccu-gate <tree>/libexec/canccu-nudge-hook /usr/local/libexec/canccu-dispatcher/`
   (`<tree>`: the current release). Root-owned, outside both homes: neither user can change
   what the other runs, and the run user can execute them although it cannot read `~<you>`.
5. The sudoers file of section 2, written to a temp file, checked with `visudo -cf`, then
   `install -o root -g root -m 440 <temp> /etc/sudoers.d/canccu-dispatcher`.

`install.sh --run-user canccu-run` (a new option; `install.sh` keeps running as the dispatcher's
user and never as root): after the install it runs
`sudo -n <tree>/libexec/canccu-harden --dispatcher-user "$(id -un)" --run-user canccu-run` when
`sudo -n true` succeeds, and otherwise prints that one line, prefixed
`the hardened level needs root once; run:`, and exits 0. It never sets `RUN_USER`: the product
owner does, after the logins below (section 8).

**Its logins**, both run by the dispatcher's user through the run helper, never with a token on
a command line:

- Claude: `sudo -u canccu-run /usr/local/libexec/canccu-dispatcher/canccu-runas login` starts
  `claude` in the run home; the product owner types `/login` there. Its credentials stay in
  `/var/lib/canccu-run/.claude/`. The same Claude account as the dispatcher's user may be used;
  usage is read from the run's stream as today, so `usage.json` does not change.
- gh, per project: `sudo -u canccu-run /usr/local/libexec/canccu-dispatcher/canccu-runas gh-login <p> < token-file`
  runs `GH_CONFIG_DIR=/var/lib/canccu-run/projects/<p>/gh gh auth login --with-token --insecure-storage`.
  The token is narrow as the project's own is today (one repo: Contents, Issues, Pull requests
  and Workflows write; no Administration, no Secrets). Whose token it is: section 6.
- The clone, per project: `… canccu-runas clone <p>` clones `https://github.com/<REPO>` into
  `/var/lib/canccu-run/projects/<p>/clone` with that login. `<REPO>` is passed by the dispatcher,
  which reads it from the project's config.

**Layout of the run home** (all `canccu-run:canccu-run`, dirs mode 700, files 600):

```
/var/lib/canccu-run/
  .claude/                      its Claude login and sessions (resume works: same user)
  projects/<p>/
    gh/                         its gh login for the project
    clone/                      its clone; worktrees hang off it
    worktrees/<repo>/issue-<n>, <pkg-key>, review-<pr>, plan-<m>
    reviews/<pr>/<sha>.md       the review file a reviewer writes
    tmp/<repo>-<key>.<pid>      a run's TMPDIR (pid: the wrapper's, as today)
    nudge/<repo>-<key>          the nudge marker the hook reads
    leader/                     the leader session's working dir
```

**Why a clone of its own.** A worktree of `CLONE` shares `CLONE/.git` (objects, refs,
`.git/config`, hooks). A run that can write `.git/config` can set `core.fsmonitor` or
`core.hooksPath`, which the dispatcher's next `git -C "$CLONE"` would run as `<you>`. So the
run user never writes `CLONE`, and the dispatcher never runs git inside the run home itself
(git's `safe.directory` check refuses another user's repo anyway): every such call goes
through `canccu-runas git` (section 2), so it runs as the run user.

## 2. How the engine starts a run

**sudo with a fixed rule**, not a second tmux server: the wrapper, its window, its lock and its
stream stay exactly where they are, and only `claude` changes user. A second tmux server would
move the wrapper too, and the dispatcher could no longer read the window's state without the
same sudo rule.

`/etc/sudoers.d/canccu-dispatcher`, as `canccu-harden` writes it (`<you>` filled in):

```
# canccu-dispatcher: the hardened level (docs/plan/s2-hardened.md). Written by canccu-harden.
Defaults!/usr/local/libexec/canccu-dispatcher/canccu-runas !use_pty, !requiretty, !lecture, env_reset
Defaults!/usr/local/libexec/canccu-dispatcher/canccu-gate !use_pty, !requiretty, !lecture, env_reset
<you> ALL=(canccu-run) NOPASSWD: /usr/local/libexec/canccu-dispatcher/canccu-runas
canccu-run ALL=(<you>) NOPASSWD: /usr/local/libexec/canccu-dispatcher/canccu-gate
```

`!use_pty`: claude's stdout must stay the pipe the stream reader reads; `env_reset`: nothing of
either user's environment crosses, so no token can. The first rule may take any arguments: the
dispatcher's user is the trusted side, and the helper checks them against its own mistakes. The
second rule is the only way back, and section 4 bounds it.

**The run helper**, `/usr/local/libexec/canccu-dispatcher/canccu-runas <command> …`, runs as the
run user. Every path argument must resolve (`realpath -e`) under `/var/lib/canccu-run/projects/<p>/`,
else it exits 2 with `canccu-runas: <path> is outside the run area`. Its commands:

| Command | Does |
|---|---|
| `exec <p> <dir> <mins> <repo>-<key> <pid> -- claude <args…>` | `cd <dir>`; a clean environment: `HOME`, `PATH` (the run home's `.local/bin`, `.bun/bin`, then the system's), `TMPDIR`/`TMP`/`TEMP` = `tmp/<repo>-<key>.<pid>` (`<pid>`: the wrapper's; made mode 700), `GH_CONFIG_DIR` = the project's `gh/`, git's credential entries for it (as `canccu_git_via_gh`), `CANCCU_ACTOR=run`, `WORKER_NUDGE_FILE` = `nudge/<repo>-<key>`; then `exec timeout -k 10 <mins>m claude <args…>`. Only `claude` may follow `--`. The nudge hook in claude's `--settings` is the copy in `/usr/local/libexec/canccu-dispatcher/`. |
| `kill <pid>…` | TERM to each pid that belongs to the run user, KILL to what is left after 3 s; a pid of another user is skipped with a line on stderr |
| `cat <p> <file>` | prints a regular file (not a symlink) of the run area |
| `git <p> <dir> <git args…>` | `git -C <dir> <args…>` with the project's credential entries |
| `rm <p> <path>` | `rm_tree` of a worktree or temp dir (`git worktree prune` after a worktree) |
| `nudge <p> <repo>-<key> on\|off` | creates or removes `nudge/<repo>-<key>` |
| `clone <p> <owner/repo>` · `gh-login <p>` · `login` | section 1 |
| `leader <p>` | section 4 |
| `status <p>` | `claude=yes\|no`, `gh=<login>\|none`, `clone=<origin url>\|none`, one per line, for doctor |
| `probe <path>…` | `readable <path>` for each path the run user can open or list; nothing else |

**The engine at the hardened level** (`libexec/canccu-worker`, `lib/canccu-engine.sh`), with
`RUN_USER` set:

- `RUNAS=(sudo -n -u "$RUN_USER" /usr/local/libexec/canccu-dispatcher/canccu-runas)`, set once in
  `lib/canccu-engine.sh`; empty at the simple level, where every call below is today's.
- `attempt` starts `"${RUNAS[@]}" exec "$CANCCU_PROJECT" "$dir" "$mins" "$repo-$key" "$$" -- claude "${args[@]}" -- "$prompt"`
  with stdin `/dev/null`, stdout the pipe to `canccu-stream.py`, stderr `$errf` (both opened by
  the wrapper, so they stay the dispatcher's files). The outer `timed_exec` goes: the inner
  `timeout` is the time budget, and it exits 124 or 137 as today, which sudo passes on.
- The run's worktree is `/var/lib/canccu-run/projects/<p>/worktrees/<repo>/issue-<n>` (and the
  package's, the reviewer's, the planner's beside it). `unit_wt`, `review_wt` and `plan_wt` give
  that path when the unit's state has `run_as` (contracts §6); every `git -C` on such a path,
  and the worktree adds of `canccu-worker`, `ensure_unit_wt`, `start_reviewer` and the planner,
  go through one function, `run_git <dir> <args…>` (`lib/canccu-engine.sh`), which is
  `"${RUNAS[@]}" git "$CANCCU_PROJECT" …` at the hardened level and `git -C …` at the simple one.
  Worktrees are added from the run user's clone, never from `CLONE`; `CLONE` stays the
  dispatcher's own, for its own reads and the scripted merge of main.
- Files the run writes are read back only through `"${RUNAS[@]}" cat`: the review file is copied
  to today's `~/.canccu/projects/<p>/reviews/<pr>/<sha>.md` before any check, so every check
  after it is today's. A symlink the run planted to the reviewer token cannot leak it: the run
  user opens the file, and the run user cannot read the token.
- The nudge: `usage_tick` calls `"${RUNAS[@]}" nudge <p> <repo>-<key> on`, the run's start `… off`.
- The temp dir sweep (`run_tmp_sweep`) lists and removes the run area's `tmp/` through the
  helper, with the same lock rule as today.
- `--setting-sources user` still applies to untrusted runs: the user settings it loads are the
  run user's (`/var/lib/canccu-run/.claude/settings.json`), which `canccu-harden` does not write
  and the product owner keeps free of hooks.

**What the dispatcher still reads, unchanged:** the stream (a pipe), `.err`, `.sum`, `.last`,
`.log`, `.id`, the lock and the spend log are all written by the wrapper, which stays
`<you>`'s process in `<you>`'s tmux server. The session id in `.id` resumes the run user's
session, since every run of the unit is the run user's.

**Stopping.** The tree is wrapper (`<you>`) → sudo (root) → `timeout` → `claude` → tools (the
run user). `<you>` cannot signal root's sudo nor the run user's processes, but can read their
`/proc/<pid>/stat` (doctor checks `/proc` has no `hidepid`). So:

- `kill_tree <pid>` walks the tree as today, kills the pids of `<you>` directly and passes the
  pids of the run user to `"${RUNAS[@]}" kill`. Sudo exits when its child does.
- The stall kill (`watchdog`) and `tool_ticks` work unchanged on top of it: `tool_ticks` still
  finds the `timeout` process in the tree and reads the tools' ticks from `/proc`.
- `canccu-stop` and `canccu-worker --kill` are unchanged above `kill_tree`: `owns_pid` checks
  the wrapper, which is still `<you>`'s. `tmux kill-window` hangs up the wrapper, whose TERM/HUP
  trap runs `kill_tree`.
- `canccu-stop --forget` removes the worktree with `"${RUNAS[@]}" rm`.

## 3. Where the reviewer runs

As the run user, like every Claude session. The reviewer reads untrusted code and runs its
tests: it is the session most likely to be fooled. It needs the reviewer token only to post,
and the shell posts (`as_reviewer`), so the reviewer never needs the dispatcher's user.

What the reviewer and fix-check may write: their worktree `worktrees/<repo>/review-<pr>`, the
review dir `reviews/<pr>/` (passed with `--add-dir`, as `extra_dirs` is today), their `TMPDIR`
and the run user's `~/.claude`. Nothing of the dispatcher's home. The dispatcher copies
`reviews/<pr>/<sha>.md` out with `canccu-runas cat` (section 2) and then checks it exactly as
today: written after the review started, last line `Review verdict: pass|changes <full sha>`.
The answerer and the planner are the same: run user, their worktree, their temp dir; the
planner's plan is still its final message, read from the stream.

## 4. The leader

The same run user. `canccu-up` at the hardened level types
`sudo -n -u canccu-run /usr/local/libexec/canccu-dispatcher/canccu-runas leader <p>` in the
leader's pane instead of `claude`: the helper starts `claude` in
`/var/lib/canccu-run/projects/<p>/leader` with `CANCCU_ACTOR=leader` and the run user's gh login
for the project. The leader therefore holds neither the reviewer token nor the dispatcher's login.

It reaches the dispatcher only through **the gate**,
`sudo -n -u <you> /usr/local/libexec/canccu-dispatcher/canccu-gate <p> <command> [args]`, which
runs as `<you>` and allows only:

| Gate command | Runs as `<you>` |
|---|---|
| `wait [--owner leader] [--ack <id>]` | `canccu-dispatcher wait --project <p> …` |
| `brief` | `canccu-dispatcher leader brief --project <p>` (L1, #186) |
| `status` | `canccu-status --project <p>` |
| `ship <n>` | `canccu-ship --project <p> <n>` (L1's leader checks apply: technical PRs only, inside `LEADER_ACCEPTS`) |
| `stop <n>` · `run <n>` · `pause` · `resume` | the commands of the same name, `--project <p>` |
| `config show` · `config set <KEY> <value>` · `config unset <KEY>` | `canccu-dispatcher config …` (locked keys refused) |

The gate checks `<p>` with `canccu_valid_name` and against the projects, each argument against
a fixed pattern (`<n>`, `<id>`: digits; `<KEY>`: `[A-Z][A-Z0-9_]*`; a value: one line, at most
200 characters), runs the command with a fixed `PATH`, `HOME` from `getent passwd <you>` and
`CANCCU_ACTOR=leader`, and refuses everything else with
`canccu-gate: refused: <command> is not a leader command`. Since sudo resets the environment and
the run user can reach `<you>` no other way, `CANCCU_ACTOR=leader` becomes a boundary at this
level: the leader cannot set a locked key, release the brake, or accept as `po`. `canccu-ship`
also takes the actor as `leader` whenever `SUDO_USER` is `RUN_USER`, whatever the environment.

The limit, stated: the gate cannot tell the leader from a worker, since both are the run user. A
fooled worker can therefore call the leader's commands. That is bounded by what the leader may
do: its `ship` counts only inside `LEADER_ACCEPTS` and never for gated and high-risk PRs at this
level (section 6), and every call is in the actions log (contracts §7) with actor `leader`.
A separate leader user is a later step, not this package.

## 5. doctor at the hardened level

`canccu-dispatcher doctor` prints one level line first, always, not counted as a problem (the
exit code ignores it):

- `level: simple (RUN_USER is empty: every session runs as you; known limits: docs/security.md)`
- `level: hardened (sessions run as <u>)`

With `RUN_USER` set, these checks run; each prints its fixed line, with `<u>` the run user,
`<you>` the dispatcher's user, `<tree>` the current release, `<p>` the project:

| # | Check | Line |
|---|---|---|
| 1 | the user exists | `RUN_USER <u>: no such user (sudo <tree>/libexec/canccu-harden --dispatcher-user <you> --run-user <u>)` |
| 2 | it is not `<you>` and not root | `RUN_USER <u> is you or root: name a second user, or leave RUN_USER empty for the simple level` |
| 3 | it is in no group of `<you>` | `RUN_USER <u> is in your group <g>: it could read what that group reads (gpasswd -d <u> <g>)` |
| 4 | the helpers exist, root's, mode 755 | `the run helpers are missing or not root's in /usr/local/libexec/canccu-dispatcher (sudo <tree>/libexec/canccu-harden …)` |
| 5 | the helpers equal the current release's (`cmp`) | `the run helpers are not release <id>'s (sudo <tree>/libexec/canccu-harden …)` |
| 6 | `sudo -n -u <u> …/canccu-runas status <p>` works | `sudo cannot start the run helper as <u> without a password (/etc/sudoers.d/canccu-dispatcher; sudo <tree>/libexec/canccu-harden …)` |
| 7 | the run user's sudo rights are the gate only (`canccu-runas` runs `sudo -n -l`) | `<u> may run more with sudo than the gate: <line> (only /usr/local/libexec/canccu-dispatcher/canccu-gate as <you>)` |
| 8 | `probe` finds none of: `~/.canccu`, the reviewer token, each project's `gh/hosts.yml`, `~/.config/gh/hosts.yml`, `~/.claude/.credentials.json`, each `CLONE/.git/config` | `<u> can read <path>: chmod go-rwx <path>` (one line per path, `~/…` form) |
| 9 | `/proc` has no `hidepid` | `/proc is mounted with hidepid: the stall check cannot see <u>'s processes (remount /proc without hidepid)` |
| 10 | `fs.protected_symlinks` and `fs.protected_hardlinks` are 1 | `fs.protected_symlinks or fs.protected_hardlinks is 0: a run could plant links (sysctl -w fs.protected_symlinks=1 fs.protected_hardlinks=1)` |
| 11 | `status` says `claude=yes` | `<u> has no Claude login (sudo -u <u> /usr/local/libexec/canccu-dispatcher/canccu-runas login, then /login)` |
| 12 | per project: `gh=` is not `none` | `project <p>: <u> has no gh login (sudo -u <u> /usr/local/libexec/canccu-dispatcher/canccu-runas gh-login <p> < token-file)` |
| 13 | per project: the login is `RUN_LOGIN` when set, else `USER_LOGIN` | `project <p>: <u>'s gh login is <login>, not <RUN_LOGIN or USER_LOGIN>` |
| 14 | per project: `clone=` is `REPO`'s | `project <p>: <u> has no clone of <REPO> (sudo -u <u> /usr/local/libexec/canccu-dispatcher/canccu-runas clone <p> <REPO>)` |
| 15 | per project: no unit with a worktree but without `run_as` | `project <p>: #<n> still works in ~/.canccu (canccu-dispatcher harden migrate --project <p>)` |

At both levels, two lines for the settings of section 9:

- `KEEP_ACCEPT_ON_MAIN_MERGE=1 at the simple level: a run can forge the accept it keeps (docs/security.md); set 0, or set up the hardened level`
- `LEADER_ACCEPTS_HIGH_RISK=1 is ignored at the simple level (docs/security.md)`

The reviewer token check of today stays at both levels; the Claude deny rule stays recommended,
but at the hardened level the boundary is the file mode, which check 8 tests for real.

## 6. The accept at the hardened level

`ACCEPT_CHANNELS` and `accepts.log` are built by #185; this section fixes how strong each
channel is. A channel is **strong** when no AI session can write it.

| Channel | Who can write it | Simple | Hardened, `RUN_LOGIN` empty | Hardened, `RUN_LOGIN` set |
|---|---|---|---|---|
| `label`: `accepted` by `USER_LOGIN` | any session holding `USER_LOGIN`'s token | weak | weak (the run user's token is `USER_LOGIN`'s) | strong |
| `reply`: a comment by `USER_LOGIN` | the same | weak | weak | strong |
| `ship`: `canccu-ship` run by `<you>` at the host | `<you>`'s processes | weak (a run is `<you>`) | strong | strong |
| `leader`: `canccu-ship` through the gate | the run user | AI | AI | AI |

- **Gated and high-risk PRs at the hardened level** need a strong channel listed in
  `ACCEPT_CHANNELS`. A weak or AI accept on such a PR is logged once and ignored:
  `#<n> PR #<pr>: <channel> accept ignored: a gated or high-risk PR needs canccu-ship${RUN_LOGIN:+ or the label}`.
  Normal-risk PRs keep today's rules (the owner rule of contracts §1 and `LEADER_ACCEPTS`).
- **The accept record** is #185's line in `~/.canccu/projects/<p>/accepts.log`:
  `<time>	<n>	<pr>	<head sha>	<actor>`. At the hardened level the actor is `po` only when
  `canccu-ship` runs as `<you>` without `SUDO_USER` and without `CANCCU_ACTOR`; it is `leader`
  through the gate, and `run` never occurs (the run user cannot reach `canccu-ship` but through
  the gate). The run user cannot write the file: it is under the dispatcher's home.
- **`RUN_LOGIN`.** With a second GitHub login for the runs, a collaborator with write access on
  the project's repo only, the run user's token is that login's, so no AI session holds
  `USER_LOGIN`'s and the label and the reply are the product owner's again. Its PRs are then
  authored by `RUN_LOGIN`: "ours" (`pr_not_ours`) accepts `USER_LOGIN` and `RUN_LOGIN` as the
  author, and only `USER_LOGIN`'s comments are the product owner's. On a personal repo GitHub
  may not let a fine-grained token of another account reach it; a classic token of that login
  with the `repo` and `workflow` scopes is then the narrow one, since the login reaches no other
  repo.
- **Comments during a live run** (#185) still apply at every level.

## 7. The simple level stays

`RUN_USER` empty is today's setup and stays supported and tested (rule 4 of the plan): every
session runs as `<you>`, worktrees stay under `~/.canccu`, no sudo, no helper. It keeps every
known limit `docs/security.md` lists, with `ship` weak too. At this level
`LEADER_ACCEPTS_HIGH_RISK=1` is ignored (logged once:
`LEADER_ACCEPTS_HIGH_RISK=1 is ignored at the simple level`) and `KEEP_ACCEPT_ON_MAIN_MERGE=1`
works as today with doctor's warning. Doctor tells the two apart by `RUN_USER` alone and says
which on its first line (section 5); `canccu-status` adds `level: simple` or
`level: hardened (<u>)` to its header.

## 8. The upgrade, with units in flight, and the rollback

**Upgrade**, as the product owner, per host:

1. `canccu-pause --project <p>` for every project, then wait until `canccu-status` shows no run.
2. `install.sh --run-user canccu-run` (section 1), or the printed `sudo` line.
3. The logins and clones: `canccu-runas login`, then `gh-login <p>` and `clone <p> <REPO>` per
   project (section 1).
4. `RUN_USER=canccu-run` (and any `RUN_LOGIN`) in `~/.canccu/config` by hand; restart each
   `canccu-dispatch`.
5. `canccu-dispatcher harden migrate`: for each project and each unit with a worktree under
   `~/.canccu`, it refuses while a run of the unit is alive and lists units whose worktree has
   uncommitted or unpushed work:
   `#<n>: uncommitted or unpushed work in <wt>; push it, or canccu-stop --forget <n>, then run harden migrate again`.
   Otherwise it adds the run-area worktree at the unit's branch (`origin/<branch>`; a unit with
   no branch yet gets a fresh worktree on its next run as today) and sets `run_as=<u>` in the
   unit's state. The old worktrees stay until `canccu-dispatcher harden migrate --prune`.
   Session ids stay: the run user has no such session, so the first run of the unit says
   "No conversation found" and the engine already starts a fresh one with the handoff (the
   fallback in `attempt`).
6. `canccu-dispatcher doctor` shows `level: hardened` and no problem.
7. `canccu-resume --project <p>`; restart the leader: in its pane, exit `claude` and type the
   line `canccu-up` would (section 4).

Because R1 versions the state format, `run_as` comes with its migration step (empty for every
unit: the simple level) and a test that upgrades with units in flight (contracts §6).

**Rollback:** `canccu-pause`, wait for no run, `RUN_USER=` in `~/.canccu/config`, then
`canccu-dispatcher harden rollback`, which clears `run_as` of every unit whose old worktree is
still there (and lists those without one: their next run starts in a fresh worktree from their
pushed branch), restart the dispatchers, `canccu-resume`. The run user, its home and the sudoers
file stay until removed by hand (`userdel -r canccu-run`, `rm /etc/sudoers.d/canccu-dispatcher`,
`rm -r /usr/local/libexec/canccu-dispatcher`). The mode 700 of `~/.canccu` stays: it harms
nothing at the simple level.

## 9. After the build: the docs of two settings

Only once build issues 1 to 7 are merged, issue 8 writes:

- `docs/reference/config.md`, `KEEP_ACCEPT_ON_MAIN_MERGE`: "1 is safe at the hardened level with
  a strong accept (canccu-ship, or the label with `RUN_LOGIN`): a merge of main only is checked
  by redoing it (M1), and the accept itself cannot be forged. At the simple level a run can forge
  the accept it keeps." `keep_accept` then also carries a `ship` accept: an `accepts.log` record
  for the old head counts as the label does today.
- `docs/reference/config.md`, `LEADER_ACCEPTS_HIGH_RISK`: "hardened level only; ignored when
  `RUN_USER` is empty."
- `docs/security.md`: a section "The hardened level" (who runs as whom, the two sudo rules, the
  gate, what the run user can and cannot read), "Who holds which credential" with the run user's
  row, and "Known limits" rewritten per level; the line "Running the reviewer as its own OS user
  would close this" is replaced by a link to that section.
- `docs/install.md`: the hardened setup, section 8's steps 2 to 6; `docs/upgrading.md`: the
  migration and the rollback.

## 10. The build issues, in order, one PR each

1. **The run helper and the root setup.** `libexec/canccu-runas`, `libexec/canccu-harden`,
   `install.sh --run-user`, `RUN_USER` (config default, settings table, `docs/reference/config.md`).
   Tests use a fake `sudo` on `PATH` that drops `-n -u <user>` and runs the helper with
   `HOME` pointing at a test run home, so CI needs no second user; the path checks, `exec`'s
   environment (no token variable survives) and `kill`'s owner check are tested there.
2. **The engine runs as the run user.** `RUNAS`, `run_git`, the run-area paths, `kill_tree`'s
   split, the review file copy, the nudge and the sweep through the helper, state field `run_as`
   with its migration. Tests: the fake sudo of 1; a stalled run is still killed, `canccu-stop`
   still stops one, a review file that is a symlink is refused.
3. **doctor's hardened checks**, section 5, each line tested with the fake sudo and fixtures.
4. **The gate and the leader.** `libexec/canccu-gate`, `canccu-runas leader`, `canccu-up`'s
   pane line, `canccu-ship`'s `SUDO_USER` rule. After L1's #186 (`leader brief`). Tests: every
   refused form, actor `leader` in the actions log, a locked key refused through the gate.
5. **`RUN_LOGIN`.** The setting, "ours" for its PRs, the product owner's comments are
   `USER_LOGIN`'s only, doctor check 13.
6. **The accept at the hardened level.** Section 6's strength rule on top of #185's
   `ACCEPT_CHANNELS`; the ignored-accept log line. After #185.
7. **The migration and the rollback.** `canccu-dispatcher harden migrate [--prune]` and
   `harden rollback`, with a test that migrates a project with units in flight (one clean, one
   with unpushed work, one running).
8. **The docs.** Section 9, then `KEEP_ACCEPT_ON_MAIN_MERGE=1` and `LEADER_ACCEPTS_HIGH_RISK=1`
   may be described. Before it, rule 3 holds: no doc recommends either.

Every build issue is high risk (it is the security boundary) and waits for the product owner's
accept. A manual check on a real host with a real second user (section 8's steps, then one
issue run end to end, one `canccu-stop`, one stall) is part of issue 7's acceptance; T1 later
keeps it as a release-gate test.
