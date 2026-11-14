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
is stopped and its issue goes to `needs-you`.

| Key | Default | Meaning |
|---|---|---|
| `REPO` | none | The only repo (`owner/repo`) the project's dispatcher works on. Project config only |
| `CLONE` | none | Its main clone; every worktree hangs off it. `canccu-init` writes `~/code/<repo>` or the path it was given |
| `HOST_PROFILE` | empty | The host profile, `hosts/<name>.conf` (`max` or `pro`); empty: none. Set it in `~/.canccu/config`, or `CANCCU_HOST_PROFILE` for one command. An unknown name is refused with the list |
| `CAP` | `3` | The project's workers, reviewers and answerers running at once |
| `TOTAL_CAP` | `3` | The same over all projects of this host together (they share one Claude account), shared by need ([`projects.md`](projects.md#fair-share-of-total_cap)). Up to `~/.canccu/config` only |
| `MODEL` | empty | Passed as `--model` to every run; empty: no `--model`, the account's default model |
| `USER_LOGIN` | empty | Your GitHub login: whose PRs are ours, who is assigned and pinged, whose comments resume a worker. Unset: the dispatcher does nothing |
| `REVIEWER_LOGIN` | empty | The reviewer bot's login: reviews and pings post as it, and only its verdicts count. The same login is the repo variable the `review-gate` check reads. Unset: no review starts |
| `REVIEWER_TOKEN_FILE` | `~/.canccu/reviewer-token` | The bot's token, mode 600, one for all projects. Only the dispatcher's own `gh` calls that post a review or a ping read it ([`../security.md`](../security.md)). Missing or another mode: no review starts, and `canccu-status` says so |
| `GH_CONFIG_DIR` | empty | The project's own `gh` config dir, logged in with its narrow token. Empty: `~/.canccu/projects/<name>/gh` when it exists, else the default `gh` login, with a warning in `canccu-status` ([`projects.md`](projects.md)) |
| `BUDGET_WORK` | `250 80 150` | A worker on a new issue |
| `BUDGET_RESUME` | `80 20 45` | A follow-up run of a worker: review fixes, a red-CI fix, a plan OK, an answer, your comment |
| `RESUME_ON` | `answer,plan` | The follow-up kinds that `--resume` the worker's session: `answer` (an answer to its `Question:`), `plan` (plan-ok), `fix` (a review fix round), `ci` (a red-CI fix), `needs-work`, `merge` (a merge of main the worker has to do: one that conflicts, or main after a contract PR merged), `limited` (after a usage stop), `blocked` (its blockers closed), `crash` (a crash retry), `user` (any other comment of yours, `canccu-run`), or `all`. Every other follow-up starts a fresh session with a short handoff ([`engine.md`](engine.md), "Follow-up runs") |
| `FIX_ATTEMPTS` | `2` | Automatic fix runs per PR, review fix rounds and red-CI fixes together; then `needs-you`. `0`: red CI goes to `needs-you` at once, as before; no whole number: 2 |
| `FIX_EXTRA_IF_FEWER` | `1` | `1`: when a review or fix-check would stop for you after the fix (its `changes` with no fix run left, or the fix-check's open items) and its blocking findings are fewer than the verdict before it (at least one left), one more automatic fix round and its fix-check run first, once per cycle, past `FIX_ATTEMPTS` ([`reviews.md`](reviews.md), "Fix-check"). `0`: stop as before |
| `CRASH_RETRY` | `1` | Fresh runs with the handoff (kind `crash`) after a worker crashed, stalled or was killed while starting; then `needs-you`. `0`: needs-you at once ([`pipeline.md`](pipeline.md)) |
| `FIX_MODEL` | empty | The fix run's model (a review fix round, a red-CI fix, `needs-work`); empty: `MODEL`. Set it per machine in `~/.canccu/config` |
| `FIX_EFFORT` | empty | The fix run's `--effort` (`low`, `medium`, `high`, `xhigh`, `max`); empty (or none of those, which is logged): no `--effort`, the account's. Set it per machine in `~/.canccu/config` |
| `BUDGET_REVIEW` | `60 15 40` | The independent reviewer |
| `BUDGET_FIXCHECK` | `30 6 20` | The fix-check after the worker fixed the review's findings |
| `BUDGET_ANSWER` | `40 10 20` | The answerer of a worker's question |
| `ANSWER_MAX` | `3` | Answerer rounds per issue; another question after that goes to `needs-you` |
| `STALL_MIN` | `10` | A run whose log has not grown, and whose tool processes spent no CPU, for this many minutes is killed as stalled ([`engine.md`](engine.md)) |
| `RUN_TMPDIR` | `disk` | `disk`: each run gets its own temp dir under the workers dir (`TMPDIR`, `TMP` and `TEMP`), removed when it ends ([`engine.md`](engine.md)); `system`: the inherited `TMPDIR` |
| `DIGEST_HOUR_UTC` | `6` | The daily digest is written on the first pass at or after this hour (UTC) |
| `DIGEST_ISSUE` | empty | The issue the digest is posted on as a comment; empty: the digest is only written to `digest/<date>.md` |
| `PING` | `on` | `on`: when something needs you, one comment as `REVIEWER_LOGIN` @mentions `USER_LOGIN` ([`pings.md`](pings.md)); `off`: never |
| `LEADER` | `off` | `on`: the owner rule gives a leader the waiting items that are not the product owner's ([`lead.md`](lead.md#the-owner-of-a-waiting-item)). Locked |
| `LEADER_ACCEPTS` | `none` | `technical`: the leader owns the accepts the rule does not give the product owner. Locked |
| `LEADER_ACCEPTS_HIGH_RISK` | `0` | `1`: … a high-risk one too. Locked |
| `INTERVAL` | `60` | Seconds between passes |
| `IDLE_ALARM_MIN` | `60` | A managed unit with no run, not waiting for a person, whose phase has not changed for this many minutes writes one `idle` line in the feed ([`lead.md`](lead.md#the-feed)) |
| `CI_WAIT_MIN` | `90` | A finished worker's PR whose CI is still pending after this many minutes goes to `needs-you` |
| `NO_CHECKS_MIN` | `10` | A finished worker's PR with no CI check reported at all after this many minutes goes to `needs-you` ("is CI set up for this repo, or did a path filter skip it?"; for a PR that conflicts with main, which GitHub runs no checks on: "it conflicts with main, so GitHub runs no checks; merge main into it or say how") |
| `MERGE_WAIT_MIN` | `240` | Auto-merge armed this long without a merge is disarmed, and the PR goes to `needs-you` |
| `MERGE_CLOSE_MIN` | `2` | An issue a merged PR names as closing that GitHub left open this many minutes is closed by the dispatcher |
| `MERGE_RETRY` | `3` | A merge that fails on an error that looks transient (a GitHub 5xx, a timeout, a dropped connection) is tried again on this many later passes before it goes to `needs-you`; `0`: never ([`merging.md`](merging.md#a-github-error-on-the-merge)) |
| `KEEP_ACCEPT_ON_MAIN_MERGE` | `0` | `1`: your `accepted` on the PR carries over a push that is only a clean merge of main, and the PR merges without a new accept; one more changed line drops it. Until the hardened setup (package S2) a run can forge it as easily as the label: keep it `0` |
| `MERGE_MAIN_ANY_PHASE` | `1` | `1`: a PR that conflicts with main gets main merged in by script in every phase (CI, a fix round, after its contract PR merged), not only at the accept and merge steps ([`merging.md`](merging.md#a-pr-that-conflicts-with-main)); `0`: only at the accept and merge steps |
| `POST_WAIT` | `600` | Seconds a posted review may take to show up on GitHub before it counts as missing |
| `STEP_BUDGET` | `400` | USD per step: its planner, package, review, fix-check, answerer and health runs ([`steps.md`](steps.md)) |
| `BUDGET_PLAN` | `60 10 30` | The planner of a step's wave |
| `BUDGET_HEALTH` | `250 60 150` | The health pass at the end of a step |
| `BUDGET_PACKAGE_MAX` | `600 200 360` | A package's work, resume and review budgets are the issue's times its issue count, each part capped by this |
| `PACKAGE_LINES` | `1500` | The planner's size guide: changed lines per package |
| `PACKAGE_MIN_ISSUES` | `3` | Above 1, the planner aims for at least this many issues per package, where they fit together (never unrelated ones); `1`: no nudge |
| `PACKAGE_HOLD_SMALL` | `0` | `1`: the planner may leave a lone small leftover (under about 300 changed lines) out of a wave while an earlier package of its area runs or other issues of its area wait, so it joins a later wave's package of its area ([`packages.md`](packages.md#the-planner)) |
| `PLAN_MODEL` | empty | The planner's model; empty: `MODEL` |
| `WAVE_ROLLING` | `0` | `1`: the next wave is planned while this one runs, once no package of it waits to start and a run slot is free (`CAP`); `0`: the planner waits for the wave to be over ([`packages.md`](packages.md#waves)). Locked |
| `REVIEW_MODEL` | empty | The full reviewer's model; empty: `MODEL` ([`reviews.md`](reviews.md), "Model by kind") |
| `REVIEW_MODEL_LIGHT` | empty | The full reviewer's model for a light PR: every path docs, a test (`TEST_PATHS`) or a `LIGHT_REVIEW_PATHS` match, none gated; empty: `REVIEW_MODEL` ([`reviews.md`](reviews.md), "Model by kind") |
| `FIXCHECK_MODEL` | empty | The fix-check's model, for example a cheaper one (`claude-sonnet-5-5`); empty: `MODEL` |
| `FIXCHECK_FULL_LINES` | `100` | A push after a passed review that changes more of the PR's own lines than this since the last full review gets a full review, not a fix-check |
| `FIXCHECK_COUNT_MAIN` | `0` | `0`: that count leaves out what a clean merge of main brought into the PR's files; `1`: those lines count too. A merge of main that conflicted counts in full: its resolution is the PR's own change ([`reviews.md`](reviews.md)) |
| `REVIEW_EFFORT_MAX` | empty | The highest effort of a full review and a fix-check on this machine: `low`, `medium` or `high`. It lowers, never raises, and has no exceptions: gated paths and agent configuration are capped too. `reviews/<pr>.effort` then says `(capped)`. Another value is said once in the log and ignored ([`reviews.md`](reviews.md), "Effort by risk") |
| `HEALTH_MODEL` | empty | The health pass's model (its resumes too), for example a cheaper one; empty: `MODEL` ([`steps.md`](steps.md)) |
| `HEALTH_EFFORT` | empty | The health pass's `--effort` (`low`, `medium`, `high`, `xhigh`, `max`); empty: none, the account's default effort, as for every other run. Another value is said once in the log and not passed |
| `USAGE_SLOW` | `60` | 5-hour usage share (%) from which one run at a time runs, over all projects ([`usage.md`](usage.md)) |
| `USAGE_STOP` | `90` | 5-hour usage share (%) from which no run starts and running workers are asked to stop at a safe point |
| `USAGE_WINDOW_DELTA` | `0` | `1`: each run's spend-log line records the 5-hour window's utilization before and after it ([`state.md`](state.md#the-spend-log)). Off by default: it means something only with one run at a time on a plan with a 5-hour window |
| `USAGE_WEEKLY_DRAIN` | `90` | Weekly usage share (%) from which nothing new starts; work already started finishes |
| `USAGE_MAX_AGE_MIN` | `360` | A usage reading older than this (minutes), or older than the dispatcher's start, counts as unknown: nothing is throttled until a run writes a fresh one ([`usage.md`](usage.md)); `0`: no age limit |
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
