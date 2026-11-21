<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Config

Part of the reference; the index is [`README.md`](README.md). The rules keys (gating, review
and prompt text) are in [`rules.md`](rules.md); where the values come from and when a change
applies, in [`config-files.md`](config-files.md).

## Changing a setting

`canccu-dispatcher config set KEY=VALUE` is the checked way to change one
([`commands.md`](commands.md#config-set-and-config-unset)). It writes `KEY='VALUE'` in the place
of the file's old line for the key (every uncommented `KEY=` line goes; a `# KEY=…` comment
stays), or at the end when there was none, in the key's own file: a rules key in the project's
`rules`, any other in the project's `config`, and with `--global` in `~/.canccu/config` (created,
mode 600, when missing). The value is in single quotes: it never expands a variable. The file is
rewritten in a temporary file, checked with `bash -n` and moved over the old one, one writer at
a time (`flock` on `<file>.lock`), so the dispatcher never reads half a file. `config unset KEY`
removes the lines the same way. The change applies at the dispatcher's next pass, as an edit does.

Each change, and each refusal of a locked key, adds a line to `config.history` beside the file
(`~/.canccu/projects/<name>/config.history` for a project's two files,
`~/.canccu/config.history` for the global config), mode 600, tab-separated:
`<UTC time>	<actor>	<set|unset|refused>	<KEY>	<old>	<new>	<why>`. The actor is `po` (you),
`leader` or `run`; `<old>` is the value the file held (`-`: none), `<new>` the value written
(`-` for an unset), `<why>` the `--why` text (`-`: none).

## Keys

Budgets are three numbers: turns, USD and minutes for one run. A run that reaches any of them
is stopped and its issue goes to `needs-you`. The keys of steps, packages, reviews, usage and
pacing are in [`config-steps.md`](config-steps.md).

| Key | Default | Meaning |
|---|---|---|
| `REPO` | none | The only repo (`owner/repo`) the project's dispatcher works on. Project config only |
| `CLONE` | none | Its main clone; every worktree hangs off it. `canccu-init` writes `$CLONE_ROOT/<repo>` or the path it was given |
| `BASE_BRANCH` | `main` | The repo's base branch: worktrees and prompts start from `origin/<it>`, merges of it go into a PR, PRs merge into it, its CI is the one `canccu-status` shows, and the main clone pulls it after a merge. `canccu-init` writes the repo's default branch. Locked |
| `HOST_PROFILE` | empty | The host profile, `hosts/<name>.conf` (`max` or `pro`); empty: none. Set it in `~/.canccu/config`, or `CANCCU_HOST_PROFILE` for one command. An unknown name is refused with the list |
| `CAP` | `3` | The project's workers, reviewers and answerers running at once |
| `TOTAL_CAP` | `3` | The same over all projects of this host together (they share one Claude account), shared by need ([`projects.md`](projects.md#fair-share-of-total_cap)). Up to `~/.canccu/config` only |
| `CLONE_ROOT` | `$HOME/code` | Where `canccu-init` clones a new project, and where `canccu-up`'s panes start. A host key ([`../hosts.md`](../hosts.md)). The engine finds each project's repos from its own `CLONE` |
| `EXTRA_PATH` | empty | Dirs put first on `PATH` for every command and run, colon-separated: cron and a fresh tmux server start with a bare `PATH`. A host key |
| `GUARD_VMEM_KB` | `2000000` | The virtual-memory cap, in KB, of every `gh`, `jq` and `python3` call (`guard`): a runaway kills itself, not the host. A host key: raise it on a host with much memory and big repos |
| `WORKER_SKILLS` | empty | The skill sentence of the worker, package and health prompts, and of the plan-OK resume. Empty: the prompts name no skill. [`../hosts.md`](../hosts.md#skills) has the sentence for the superpowers plugin. Locked |
| `REVIEW_SKILLS` | `code-review security-review` | The reviewer's two skills: the first reviews the diff (the full review and the fix-check), the second is the security review its trigger asks for. Locked |
| `HEALTH_CHECKLIST` | the four points | The health pass's checklist, and nothing else on it: by default files over the size limit split, dead code removed, comments to the comment rule, duplicated logic merged. Locked |
| `MERGE_METHOD` | `squash` | How a PR merges when the repo has no merge queue: `squash`, `merge` or `rebase`. One the repo does not allow: the repo's own method, with a warning. With a merge queue the queue's method applies. Locked |
| `MODEL` | empty | Passed as `--model` to every run; empty: no `--model`, the account's default model |
| `USER_LOGIN` | empty | Your GitHub login: whose PRs are ours, who is assigned and pinged, whose comments resume a worker. Unset: the dispatcher does nothing |
| `REVIEWER_LOGIN` | empty | The reviewer bot's login: reviews and pings post as it, and only its verdicts count. The same login is the repo variable the `review-gate` check reads. Unset: no review starts |
| `REVIEWER_TOKEN_FILE` | `~/.canccu/reviewer-token` | The bot's token, mode 600, one for all projects. Only the dispatcher's own `gh` calls that post a review or a ping read it ([`../security.md`](../security.md)). Missing or another mode: no review starts, and `canccu-status` says so |
| `GH_CONFIG_DIR` | empty | The project's own `gh` config dir, logged in with its narrow token. Empty: `~/.canccu/projects/<name>/gh` when it exists, else no own login ([`projects.md`](projects.md)) |
| `ALLOW_DEFAULT_GH_LOGIN` | `0` | `1`: a project without its own `gh` login (`GH_CONFIG_DIR`) may run on the host's default login, with a warning in `canccu-status`. `0`: it starts no run, and the pass, `canccu-status` and `canccu-dispatcher doctor` say so ([`projects.md`](projects.md#a-narrow-token-per-project)). Locked |
| `BUDGET_WORK` | `250 80 150` | A worker on a new issue |
| `BUDGET_RESUME` | `80 20 45` | A follow-up run of a worker: review fixes, a red-CI fix, a plan OK, an answer, your comment |
| `RESUME_ON` | `answer,plan` | The follow-up kinds that `--resume` the worker's session: `answer` (an answer to its `Question:`), `plan` (plan-ok), `fix` (a review fix round), `ci` (a red-CI fix), `needs-work`, `merge` (a merge of main the worker has to do: one that conflicts, or main after a contract PR merged), `limited` (after a usage stop), `blocked` (its blockers closed), `crash` (a crash retry), `user` (any other comment of yours, `canccu-run`), or `all`. Every other follow-up starts a fresh session with a short handoff ([`engine.md`](engine.md), "Follow-up runs") |
| `FIX_ATTEMPTS` | `2` | Automatic fix runs per PR, review fix rounds and red-CI fixes together; then `needs-you`. `0`: red CI goes to `needs-you` at once, as before; no whole number: 2 |
| `FIX_EXTRA_IF_FEWER` | `1` | `1`: when a review or fix-check would stop for you after the fix (its `changes` with no fix run left, or the fix-check's open items) and its blocking findings are fewer than the verdict before it (at least one left), one more automatic fix round and its fix-check run first, once per cycle, past `FIX_ATTEMPTS` ([`reviews.md`](reviews.md), "Fix-check"). `0`: stop as before |
| `CRASH_RETRY` | `1` | Fresh runs with the handoff (kind `crash`) after a worker crashed, stalled or was killed while starting; then `needs-you`. `0`: needs-you at once ([`pipeline.md`](pipeline.md)) |
| `CONTINUE_MAX` | `3` | Fresh runs with the handoff (kind `continue`) after a worker stopped at its turn or time budget while its PR moved on (a new head, or out of draft), each with a run's turns and minutes and the USD left of `BUDGET_WORK`; then `needs-you`. `0`: needs-you at once ([`pipeline.md`](pipeline.md)) |
| `FIX_MODEL` | empty | The fix run's model (a review fix round, a red-CI fix, `needs-work`); empty: `MODEL`. Set it per machine in `~/.canccu/config` |
| `FIX_EFFORT` | empty | The fix run's `--effort` (`low`, `medium`, `high`, `xhigh`, `max`); empty (or none of those, which is logged): no `--effort`, the account's. Set it per machine in `~/.canccu/config` |
| `TEST_TIER` | `targeted` | The test rule every worker, package and health prompt, fix round and fix-check states ([`hosts.md`](hosts.md#the-test-tier)): `targeted`, only the test files of the areas the run touched plus the repo checks (`tests/run repo`), never the full suite; `full`, the full suite once before the PR is marked ready. Any other value: `targeted`. CI runs the full suite either way. Both host profiles set `targeted` |
| `BUDGET_REVIEW` | `60 15 40` | The independent reviewer |
| `BUDGET_FIXCHECK` | `30 6 20` | The fix-check after the worker fixed the review's findings |
| `BUDGET_ANSWER` | `40 10 20` | The answerer of a worker's question |
| `ANSWER_MAX` | `3` | Answerer rounds per issue; another question after that goes to `needs-you` |
| `STALL_MIN` | `10` | A run whose log has not grown, and whose tool processes spent no CPU, for this many minutes is killed as stalled ([`engine.md`](engine.md)) |
| `RUN_TMPDIR` | `disk` | `disk`: each run gets its own temp dir under the workers dir (`TMPDIR`, `TMP` and `TEMP`), removed when it ends ([`engine.md`](engine.md)); `system`: the inherited `TMPDIR` |
| `DIGEST_HOUR_UTC` | `6` | The daily digest is written on the first pass at or after this hour (UTC) |
| `DIGEST_ISSUE` | empty | The issue the digest is posted on as a comment; empty: the digest is only written to `digest/<date>.md` |
| `PING` | `on` | `on`: when something needs you, one comment as `REVIEWER_LOGIN` @mentions `USER_LOGIN` ([`pings.md`](pings.md)); `off`: never |
| `NOTIFY_CONTENT` | `full` | What an ask carries, the ping and the PR body block ([`pings.md`](pings.md#the-ask-form)): `full`, the whole form; `link`, its first line, its last line and the link. Locked |
| `NOTIFY` | `github` | Where an ask of the product owner goes ([`notify.md`](notify.md)): `github`, the ping (with `PING=on`); `telegram`, a Telegram message only; `both`; `off`, nowhere (no ping either). Locked |
| `TELEGRAM_CHAT_ID` | empty | The chat the bot writes to: a group with topics on (`-100…`), or a private chat (reply chains). Locked |
| `TELEGRAM_USER_ID` | empty | The product owner's Telegram user id: only their replies, in an open topic, reach the inbox; empty: no reply is read. Locked |
| `TELEGRAM_TOKEN_FILE` | `$HOME/.config/canccu/telegram-token` | The bot token, mode 600, outside every repo; only the dispatcher's `curl` reads it, on stdin. Not settable with `config set` |
| `LEADER` | `off` | `on`: the owner rule gives a leader the waiting items that are not the product owner's ([`leader.md`](leader.md#the-owner-of-a-waiting-item)); `canccu-init --leader` sets it with the kit. Locked |
| `LEADER_ACCEPTS` | `none` | `technical`: the leader owns the accepts the rule does not give the product owner. Locked |
| `LEADER_ACCEPTS_HIGH_RISK` | `0` | `1`: … a high-risk one too. Locked |
| `REVIEW_BRAKE` | `auto` | `auto`: the escaped-defect trigger engages the review brake ([`reviews.md`](review-depth.md#the-review-brake)); `off`: it never engages by itself. Locked |
| `BRAKE_WINDOW` | `20` | The merged PRs the brake's trigger, its baseline and `canccu-status --kpi-review` count. Locked |
| `INTERVAL` | `60` | Seconds between passes |
| `IDLE_ALARM_MIN` | `60` | A managed unit with no run, not waiting for a person, whose phase has not changed for this many minutes writes one `idle` line in the feed ([`leader.md`](leader.md#the-feed)) |
| `CI_WAIT_MIN` | `90` | A finished worker's PR whose CI is still pending after this many minutes goes to `needs-you` |
| `NO_CHECKS_MIN` | `10` | A finished worker's PR with no CI check reported at all after this many minutes goes to `needs-you` ("is CI set up for this repo, or did a path filter skip it?"; for a PR that conflicts with main, which GitHub runs no checks on: "it conflicts with main, so GitHub runs no checks; merge main into it or say how") |
| `MERGE_WAIT_MIN` | `240` | Auto-merge armed this long without a merge is disarmed, and the PR goes to `needs-you` |
| `MERGE_CLOSE_MIN` | `2` | An issue a merged PR names as closing that GitHub left open this many minutes is closed by the dispatcher |
| `MERGE_RETRY` | `3` | A merge that fails on an error that looks transient (a GitHub 5xx, a timeout, a dropped connection) is tried again on this many later passes before it goes to `needs-you`; `0`: never ([`merging.md`](merging.md#a-github-error-on-the-merge)) |
| `ACCEPT_CHANNELS` | `all` | The accepts that count, space-separated: `label` (the `accepted` label), `ship` (`canccu-ship`), `reply` (an answer comment), `leader` (the leader's `canccu-ship`), or `all`. Locked. `canccu-status` shows it ([`merging.md`](merging.md#the-accept-channels)) |
| `KEEP_ACCEPT_ON_MAIN_MERGE` | `1` | `1`: an accept (your `accepted` on the PR, or a `canccu-ship` record) carries over clean merges of main, and merges with conflicts resolved inside the PR's own files once their fix-check passes ([`merging.md`](merging.md#an-accept-over-merges-of-main)); `0`: every push asks again |
| `MERGE_MAIN_ANY_PHASE` | `1` | `1`: a PR that conflicts with main gets main merged in by script in every phase (CI, a fix round, after its contract PR merged), not only at the accept and merge steps ([`merging.md`](merging.md#a-pr-that-conflicts-with-main)); `0`: only at the accept and merge steps |
| `POST_WAIT` | `600` | Seconds a posted review may take to show up on GitHub before it counts as missing |
| `DISK_MIN_MB` | `200` | Free MB on the worktrees' file system (`workers/`) below which a pass starts nothing new; reaping, reviews and merges go on. Logged once; `canccu-status` shows `disk low` ([`pipeline.md`](pipeline.md)) |

## The settings table

`lib/canccu-settings.tsv` lists every setting once, in the order of `lib/canccu-config.default`:
`<KEY>`, `<type>`, `<file>` and `<locked>`, tab-separated; `#` lines are comments. `config show`
reads it, and so will `config set` and the monitor's Settings view.

- `<file>`: `project` (the project's `config`), `rules` (its `rules`), `global` (only
  `~/.canccu/config`) or `fixed` (never written by a command).
- `<locked>`: `locked` (a run or the leader may not change it) or `open`.
- `<type>`: `int:<min>:<max>`; `intopt:<min>:<max>` (the same, or empty); `enum:<a>|<b>|…` (an
  empty alternative is nothing between two bars or at the end); `budget` (three whole numbers
  ≥ 1, single spaces); `regex` (empty, or accepted by `grep -E`); `words:<a>|<b>|…` (zero or more
  of the words, by commas or spaces); `date` (empty or `YYYY-MM-DD`); `name` (empty or
  `[A-Za-z0-9._:/[]-]` characters); `text` (anything on one line).
