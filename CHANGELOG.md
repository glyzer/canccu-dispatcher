<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Changelog

Every release of canccu-dispatcher, newest first. The version is in `VERSION`;
`canccu-dispatcher --version` prints it.

## Unreleased

- The dispatcher claim: a pass that creates the claim issue keeps it when GitHub does not list
  it yet (a new issue shows a few seconds late). It closed its own claim, and every pass after
  it did nothing on a repo with no claim yet (#271).
- The scenario suite (#271): preflight creates the label `scenario`; each scenario's project
  sets `ALLOW_DEFAULT_GH_LOGIN=1` (the default-login refusal of #173 stopped every pass); the
  reset closes the dispatcher claims of earlier scenarios; the end-state check reads 40 PRs, not
  100 (GitHub's GraphQL node limit); a setup that fails names the failing command
  ([`scenarios.md`](docs/reference/scenarios.md#what-a-fail-prints)).
- Telegram stays quiet (#252): only the kinds in `NOTIFY_KINDS` are sent (`idle` and `hold` are
  off by default, and an `idle` never goes while its unit has an open item); items within
  `NOTIFY_BATCH_MIN` minutes go as one message with one line each and the reply that settles them
  all; nothing but an interrupt goes in `QUIET_HOURS`; `NOTIFY_MAX_PER_DAY` caps the messages that
  ring; `NOTIFY_DIGEST_HOUR` sends a daily digest in a topic of its own, where `NOTIFY_REMIND_H`
  lists the items open too long. `canccu-notify listen` reads replies as they come (`canccu-up`
  starts it in the window `listen`); the doctor and `canccu-status` say when it is down
  ([`docs/reference/notify.md`](docs/reference/notify.md#when-it-is-sent)). New keys:
  `NOTIFY_KINDS`, `NOTIFY_BATCH_MIN`, `QUIET_HOURS`, `QUIET_TZ`, `NOTIFY_MAX_PER_DAY`,
  `NOTIFY_DIGEST_HOUR`, `NOTIFY_REMIND_H`.
- A worker's test runs stay small by default (#250): the new `TEST_TIER` (`targeted` by
  default and in both host profiles) tells every worker, fix round and fix-check to run only the
  test files of the areas it touched plus `tests/run repo`; `full` has it run the full suite once
  before the PR is ready. CI runs the full suite either way; `doctor` prints the tier
  ([`hosts.md`](docs/reference/hosts.md#the-test-tier)).
- CI: the `CI` job's time limit is 20 minutes, not 12: the suite now takes about 12 minutes on
  `ubuntu-latest`, and the job was cancelled at its limit.
- The dispatcher claim (#15): one dispatcher per repo across hosts. A pinned issue labelled
  `dispatcher-claim` names the host that runs the repo; another host's dispatcher does nothing
  while the claim is fresh, and `canccu-dispatch --take-over` takes it
  ([`docs/hosts.md`](docs/hosts.md#the-dispatcher-claim)). New keys: `HOST_LABEL`,
  `CLAIM_RENEW_MIN`, `CLAIM_EXPIRY_MIN`. New file: `~/.canccu/host-id`.
- The upgrade between passes (#20): once `current` points at a new release, the loop starts
  nothing new and, with no run live, runs the new release in its place
  ([`docs/upgrading.md`](docs/upgrading.md#between-passes)). New key: `UPGRADE` (`auto`, or
  `manual` to only show it).
- A worker that pushed its branch but could not open the PR (its `gh pr create` denied, or a
  finish run spent) no longer ends in `needs-you` (#237): the dispatcher opens the PR itself, from
  the worker's body file inside its worktree or a body built from the issue and the run's
  Testing:/Revert: lines, as a draft if the worker asked for one, and says so in the PR and the
  log. `needs-you` stays without a pushed branch of the issue with commits ahead of main.
- A ready step issue outside the running wave no longer waits unseen (#236): `canccu-status`, the
  brief and the monitor list it as `waiting for the next wave of step <n> (label fast to run it
  now)`. It is not added to the running wave; the next wave plans it
  ([`packages.md`](docs/reference/packages.md#the-planner)).
- A step whose last work issue closes after its wave ended (a polish PR still merging) keeps its
  turn (#239): it gets its health pass and checkpoint pause before the next step starts, with or
  without a checkpoint issue.
- A step at its checkpoint with new open work in its milestone goes back to planning (#243): the
  work no longer waits for the `checkpoint-ok` it is meant to earn; the health pass and a fresh
  summary follow once it is closed.
- A worker that stops at its turn or time budget while its PR moves on continues on its own
  (#127): up to `CONTINUE_MAX` (default `3`, `0` turns it off) fresh runs with its handoff, each
  with a run's turns and minutes and the USD the unit's work budget has left; `needs-you` only
  without progress (no PR, no new pushed commits) or once those are used. A resume after the
  usage limit gets the rest of the work budget, never less than `BUDGET_RESUME`
  ([`usage.md`](docs/reference/usage.md#continuations)).
- The v2 workflow is on by default (#242): light package reviews, the step deep review at
  `medium` effort (capped by `REVIEW_EFFORT_MAX` now, like every review), step tags, budgets by
  size, weekly pacing and cadence rounds. **Upgrade:** a project that sets none of these keys
  changes with the update. To keep the old value, set it in the project's `config` (rules key:
  its `rules`):
  - `REVIEW_LIGHT=0` (rules; was `0`, now `1`);
  - `STEP_DEEP_REVIEW=0` (now `1`);
  - `DEEP_REVIEW_EFFORT=high` (now `medium`; the `max` host profile keeps `high`);
  - `STEP_TAG=''` (now `step-{n}`);
  - `BUDGET_LINES=0` (now `300`);
  - `PACE=off` (now `cap`);
  - `CADENCE_DAYS=0` (now `14`; a round runs only in a milestone marked `Cadence: on`);
  - `FIXCHECK_COUNT_RESOLVED=0` (now `1`).
- One follow-up ticket per step (#223): non-blocking findings go into the body of
  `Follow-ups: step <title>` (in the step's milestone) or `Follow-ups: fast lane`, one
  `### PR #<pr> (…)` section per verdict, one `- [ ]` line per finding; a body past 60000
  characters opens `(part 2)`. A pre-existing security finding gets an issue of its own, labelled
  `security`, instead of labelling the ticket. **Upgrade:** the per-wave issues get nothing new;
  close them when they are triaged. An open fast-lane issue recorded before gets the new sections
  in its body.
- Fix-check by number (#229): the fix run and the fix-check get the blocking findings as
  `Finding 1:` to `Finding <c>:`, and the fix-check answers each on its own line. A `pass` that
  leaves one out, or calls one not fixed or broken, is `needs-you`, not a pass.
- Notifications on Telegram: `NOTIFY` (`github`, the default, `telegram`, `both`, `off`) sends
  each ask of the product owner, a step done, a hold and a polish issue as one Telegram message at
  the change of state, in a forum topic per item (a reply chain in a private chat). The product
  owner's replies in an open topic land in `$CANCCU_HOME/inbox` for the leader; `canccu-notify`
  answers, notes, closes topics and sends images; `canccu-init --check <project>` checks the
  setup. New settings `TELEGRAM_CHAT_ID`, `TELEGRAM_USER_ID`, `TELEGRAM_TOKEN_FILE`; new feed kind
  `polish` ([`docs/reference/notify.md`](docs/reference/notify.md), #39).
- Host settings (#14): one release runs on a Max and a Pro host, and what differs is a setting
  ([`docs/hosts.md`](docs/hosts.md#what-a-host-decides)). New keys: `BASE_BRANCH`, `CLONE_ROOT`,
  `EXTRA_PATH`, `GUARD_VMEM_KB`, `WORKER_SKILLS`, `REVIEW_SKILLS`, `HEALTH_CHECKLIST` and
  `MERGE_METHOD`. A merge queue is optional: without one an accepted PR merges with
  `MERGE_METHOD`. `canccu-init` writes `USER_LOGIN` (from gh's login; it refuses without one)
  and `BASE_BRANCH` (the repo's default branch). `canccu-dispatcher doctor` adds the host report:
  the profile, the keys the host's config overrides, and the last day's runs per issue with their
  cost. The profiles: v2 models, and review effort by plan (Max high, Pro medium); Pro keeps the
  budgets and usage thresholds of #168. **Upgrade:**
  - the `max` profile's `CAP` is now `2` (was `3`); set `CAP=3` in `~/.canccu/config` to keep it;
  - the prompts name no superpowers skill unless the host sets it: to keep today's sentence, set
    `WORKER_SKILLS` as the Max example in `docs/hosts.md` does;
  - `~/.local/bin` and `~/.bun/bin` are no longer put on `PATH` by themselves: set
    `EXTRA_PATH=$HOME/.local/bin:$HOME/.bun/bin` to keep them;
  - `BASE_BRANCH` defaults to `main` and `MERGE_METHOD` to `squash`, as before.
- An accept survives the dispatcher's merges of main (#244). **Upgrade:** `KEEP_ACCEPT_ON_MAIN_MERGE`
  now defaults to `1`: an accept by the label or by `canccu-ship` carries over clean merges of
  main, and merges whose conflicts were resolved inside the PR's own files once their fix-check
  passes. Set it to `0` in the project's config to be asked after every push, as before.
  `canccu-ship` on a head with no review pass records the accept and arms nothing: the head gets
  its fix-check first.
- The monitor has four views: Summary (the default), Projects, Roadmap and Activity, with a
  one-line strip on top, a view bar at the bottom and keys (`1`–`4`, `Tab`, the arrows, `j`/`k`,
  `PgUp`/`PgDn`, `Home`/`End`, `p`, `a`, `r`, `?`, `q`) read in cbreak mode when stdin is a
  terminal. `--view <name>` picks the start view, also with `--once`; `--rotate [secs]` cycles
  them (#37).
- `canccu-init --leader <project>` writes a leader kit (`CLAUDE.md` and `.claude/settings.json`)
  to `~/.canccu/projects/<project>/leader/` and sets `LEADER=on`; with `LEADER=on`, `canccu-up`
  starts the left pane's `claude` there, titled `leader`, with `CANCCU_ACTOR=leader`. The
  reference topic of the role is now `leader.md`, and the docs call it the leader (#187).
- The scenario suite: `tests/scenarios/run --repo <owner/sandbox>` runs the real dispatcher
  against a sandbox repo with a fake engine (no model tokens). A release PR (one that changes
  `VERSION`) needs the body line `Scenarios: pass at <short sha>` (#189).
- The reviewer's test set: `tests/review-set/run [--model m] [--effort e] [--light]` runs the
  real review prompt on 12 fixed cases and logs the result to `review-set.log`. A red run against
  its baseline engages the review brake. A release PR whose diff since the last tag touches the
  review prompt or the verdict handling needs `Review set: pass at <short sha>` (#196).
- The follow-ups of the 0.2 reviews (#222, with #226, #233 and #235):
  - **Contract:** each `reviews.log` line gets an 11th field, `<kept>`: the pre-existing items the
    review brake kept. Lines written before read as `0`. `--kpi-review` no longer counts them as
    demoted.
  - Merge and accept: gh timeouts are retried, an armed merge is seen as one, and an issue's accept
    is kept until the merge. A merge by script that is skipped (a dirty worktree) is needs-you at
    once; only git errors are retried. `canccu-ship` refuses the leader with `LEADER=off`.
  - Gating and retries: any pass leaves the fix round; review checks are no CI failure; a rerun
    waits for running jobs; a refused close is not waited out.
  - Holds: a low disk and `PACE=pause` hold new work only, so resumes of started work go on. Body
    send-backs wait out the back-off and the pause, and read a plan PR by its body.
  - A needs-you lifted from a red CI goes back to check once CI is green.
  - `canccu-status` shows a unit in check whose PR conflicts with main while auto-merge is off.
  - `REVIEW.md` skips fenced blocks, CRLF and HTML comment lines. A git error reading it is logged.
  - Steps read open and closed checkpoints separately, so an old open checkpoint behind 200 closed
    ones is never lost.
  - The review brake's release holds until the window moves. The baseline's rounds skip runs with
    no verdict.
  - `tests/review-set/run`: without `--model`, it uses the project's review model. An engine
    failure is `error` (exit 2) and writes no log line, baseline or brake. The release gate fails
    when a name it lists is gone. CI's tag fetch works in a repo with no tag yet.
  - Config: `PING_KINDS` reads commas; a config change in the same second reloads; a broken layer
    is named; `USAGE_MAX_AGE_MIN` takes `0`.
  - `canccu-resume --usage` clears the nudge reset and exits 0. Every command answers `--help`.
  - The leader's wait without `--ack` goes on from its stored ack. `canccu-up` starts no leader
    without its kit.
  - A worker stopped by TERM, HUP or INT stops `claude` and its tools first.
  - The planner checks carried packages and the root area for overlaps, and a rejected next-wave
    plan holds no started wave.
  - A deep review's polish issue that prints no link is looked up by its title.
  - `CLAUDE.md` finish: run `tests/run repo` before a push, not the full suite (#209).

## [0.2.0] — 2026-11-16

Release 0.2 ends here; its remaining packages move to 0.3 (#105).

**Upgrade:**

- The state format is now `3` and is upgraded at start. The upgrade changes no field, so a release
  older than this one refuses the upgraded state rather than drop the new fields (#216).
- `canccu-pause` now holds every new run, resumes, reviews, fixes and answers included; running
  runs finish and a passed review still merges. `canccu-pause --finish` keeps the old meaning: only
  new issues, packages, planners and health passes wait, work in flight goes on (#215).
- A project without its own `gh` login (`GH_CONFIG_DIR`, or `~/.canccu/projects/<name>/gh`) no
  longer runs on the host's default login: it starts no run until it gets its own login or its
  config sets `ALLOW_DEFAULT_GH_LOGIN=1` (new, default `0`, locked). `canccu-dispatcher doctor`
  names such projects with the steps (#173).

**New:**

- A head that passed review is never reviewed again: a `needs-work` answered with no push, or a
  pass read again, reuses the verdict; a `full review` line asks for a new one (#214).
- Workflow v2, every feature opt-in (off with the defaults) (#216):
  - `REVIEW_LIGHT` (rules, locked, default `0`): a package of class low or normal gets a light
    review, a checklist at low effort; a light verdict rated `Risk: high` gets a full review of
    the same head before it merges or starts a fix run.
  - `FIXCHECK_COUNT_RESOLVED` (locked, default `0`; with `FIXCHECK_COUNT_MAIN=0`): after a merge
    of main that conflicted, the fix-check counts only the hand-resolved lines and later commits.
  - `BUDGET_LINES` (default `0`: the issue count only): above 0, a package's budgets scale with its
    planned changed lines over this, still capped by `BUDGET_PACKAGE_MAX`.
  - `PACE` (default `off`; `notify`, `cap` or `pause`), `PACE_MARGIN` (default `10` points) and
    `PACE_CAP` (default `1` run): weekly pacing against the share of the week gone; while ahead,
    `pause` drains: no new issue or package starts and stopped runs wait, fix runs of started work
    go on. `canccu-status --pace` shows the reading, the mode and the spend of the last 7 days.
  - `STEP_DEEP_REVIEW` (default `0`): a step whose work is done gets a deep review of its whole
    change before the health pass; its blocking findings become one polish issue. Its model,
    effort and budget: `DEEP_REVIEW_MODEL` (default empty: `REVIEW_MODEL`, else `MODEL`),
    `DEEP_REVIEW_EFFORT` (default `high`), `BUDGET_DEEP_REVIEW` (default `150 40 120`).
  - `STEP_TAG` (locked, default empty: no tag): the checkpoint OK tags `origin/main`, `{n}` for
    the step title's leading number, else the milestone's (for example `step-{n}`); the next deep review starts from that tag.
  - `CADENCE_DAYS` (default `0`: no rounds): a step whose milestone description has the line
    `Cadence: on` gets a round every this many days while it runs: its deep review, polish and
    checkpoint summary.
  - The lead's toolkit: `canccu-dispatcher watch` waits for the next `dispatch.log` event, a new
    line of a `--file` or a stall, and `canccu-dispatcher stall` names stuck items
    (`docs/reference/lead-tools.md`). New guides
    `docs/kickoff.md` (a new project's planning session) and `docs/gates.md` (what proves a step
    done).
- The dispatcher decides what blocks a merge: the reviewer marks each finding with a class and
  `Evidence:`, and an item with a never-blocking class, no class or no `Evidence:` no longer
  blocks; a changed verdict says why in a `Dispatcher:` line. `reviews.log` gets one line per
  posted verdict, and a pre-existing `security` finding's follow-up issue gets the `security`
  label (`docs/reference/findings.md`) (#190).
- No repeats: a finding already fixed or answered on the PR, and one on lines unchanged since the
  PR's last pass (never `security`), no longer blocks. The history is in `reviews/<pr>/history`,
  and both review prompts carry it (#191).
- Issue, PR and milestone titles lose their control characters before they reach a terminal, the
  monitor or `dispatch.log`. `docs/security.md` states that the reviewer token's deny rule covers
  the session's own Read and Edit tools only (#173).
- `ACCEPT_CHANNELS` (locked, default `all`): the accepts that count, of `label` (the `accepted`
  label), `ship` (`canccu-ship`), `reply` (an answer comment, none yet) and `leader` (the leader's
  `canccu-ship`). `canccu-ship` writes an accept record before it merges, `canccu-status` shows the
  setting, and a comment made while the unit's run was live is no answer of the product owner's
  (#185).
- With `LEADER=on`, an item of the leader's not acknowledged within 60 minutes of its feed line
  passes to the product owner, with a feed line that says so; the leader acknowledges with
  `canccu-dispatcher wait --owner leader --ack <id>` (#183).
- `canccu-status --kpi`: per day of the last 7, the leader's tokens, the runs' test runs, the pings
  and the feed lines by owner. `TEST_CMD` (rules, default `tests/run`; empty: not measured) names
  the command whose calls a run counts and times, in the spend log's `tests=` and `test_secs=`
  (#188).
- The planner bundles at least `PACKAGE_MIN_ISSUES` issues per package where they fit together
  (default now `3`, was `1`) and puts the high-risk issues of one area together, apart from normal
  work. `PACKAGE_HOLD_SMALL` (rules, default `0`): `1` lets it hold a lone small leftover for a
  later wave's package of its area (#79).
- The monitor's ROADMAP keeps its package table with many blocked issues: the waiting cell names
  the main blockers then `+N more`, and done packages fold into one row (#76).

## [0.1.4] — 2026-11-14

**Upgrade:** the host profiles now set the run models. With `HOST_PROFILE=max`, the work and plan
runs and the full review use `claude-opus-5-5`; the light review and the fix-check use
`claude-sonnet-5-5`. With `HOST_PROFILE=pro`, work, fix and health runs use `claude-sonnet-5-5`,
plan runs and the full review `claude-opus-5-5`. A host that wants other models sets them in
`~/.canccu/config` (or the project's config), which overrides the profile (#170).

- Every waiting item (an accept, a `needs-you`) has an owner, the product owner or the leader,
  set from `LEADER` (default `off`: every item is the product owner's), `LEADER_ACCEPTS` and
  `LEADER_ACCEPTS_HIGH_RISK`; status, monitor and pings split by it. The state format is now `2`
  and is upgraded at start (#70).
- The event feed: one line per event a person must act on, a heartbeat, and one `idle` line for a
  unit nothing moved for `IDLE_ALARM_MIN` (default 60) minutes with nothing running.
  `canccu-dispatcher wait [--owner po|leader] [--ack <id>]` blocks until the next line (#83).
- `USER_VISIBLE_PATHS` (rules, locked, empty = off): a PR that changes one of these paths waits
  for the product owner (`manual: users see it: <path>`). `TEST_PATHS` (rules, open; default
  `tests/`, `__tests__/`, `spec/`, `*.test.*`, `*.spec.*`) names the test files, never user-visible
  (#78).
- A merged PR whose named issue GitHub leaves open: after `MERGE_CLOSE_MIN` (default 2) minutes
  the dispatcher closes it and removes its dispatcher labels; a close that keeps failing still
  gets `needs-you` after `MERGE_WAIT_MIN` (#139).
- A PR that conflicts with main gets main merged in by script in every phase, not only at the
  accept and merge steps: `MERGE_MAIN_ANY_PHASE` (default `1`; `0`: as before). A no-checks
  `needs-you` names the conflict, and a contract-first unit's resume merges main first (#149).
- The fix-check counts only the PR's own lines, not main's merged into it:
  `FIXCHECK_COUNT_MAIN` (locked, default `0`; `1`: main's lines count too). A conflicting merge
  falls back to the old count (#150).
- A lighter reviewer model for a PR that changes only docs, tests or `LIGHT_REVIEW_PATHS` (rules,
  locked, default empty): `REVIEW_MODEL_LIGHT` (default empty: `REVIEW_MODEL`), at effort
  `medium` at most. Gated paths and agent configuration are never light (#151).
- `needs-work` on a PR is honoured: the dispatcher moves it to the unit's issue and the fix run
  starts on the same pass (#154).
- Each run gets its own temp dir under the workers dir (`TMPDIR`, `TMP`, `TEMP`), removed when
  the run ends; the dirs of dead runs are swept at start and `doctor` warns over 5 GB:
  `RUN_TMPDIR` (default `disk`; `system`: the inherited `TMPDIR`) (#155).
- One more automatic fix round, past `FIX_ATTEMPTS`, when the last verdict has fewer blocking
  findings than the one before and at least one: `FIX_EXTRA_IF_FEWER` (default `1`; `0`: stop as
  before) (#156).
- The spend log's column 16 is the run's wall seconds (`-` when no run started), and every `ci=`
  note carries `ci_wait=<seconds>`; logs without them read as before (#157).
- Rolling waves: `WAVE_ROLLING` (locked, default `0`) plans the next wave while one runs, once
  nothing waits to start and a slot is free. A plan whose new package overlaps a running one's
  areas without depending on it is invalid, whatever the setting (#166).
- `HOST_PROFILE=pro` takes the max profile's budgets (every `BUDGET_*` and `STEP_BUDGET`) and
  runs one worker at a time (`CAP=1`, `TOTAL_CAP=1`) (#168).
- Tests and plans: the engine-stall test outlasts a slow watchdog and `tests/run` shows a failing
  check's value (#147); a single PR with an additive contract change flows normally (#152);
  `docs/reference/config.md`'s "Where the values come from" moved to `config-files.md`; the plan
  for package Q1 and the T1 and L1 changes (#125).

## [0.1.3] — 2026-11-13

- Log times are UTC with a `Z` (`2026-11-12T19:35:14Z`) wherever a time is written for people
  or files; readers accept both that and the old local form. `$CANCCU_HOME/state.format` holds
  the state format (`1`); `state_migrate` upgrades it at start, and a newer format than the
  release knows stops the dispatcher (#135).
- A pass holds on low disk: below `DISK_MIN_MB` (default 200) free under `WORKERS_DIR` nothing
  new starts. A GitHub rate limit pauses the project's passes until its reset. Both show in
  `canccu-status`. `canccu-stop --forget <n>` stops a unit and removes its worktree, state, run
  files and dispatcher labels (#134).
- A run's permission denials no longer turn it `blocked`: they are information, and a `done` run
  with denials is checked against its PR (same head, clean worktree) before it counts. A crashed,
  stalled or silent run gets `CRASH_RETRY` (default 1) fresh runs with its handoff before it needs
  you. A run is recorded as `starting` before the engine is called, so a kill in between loses
  nothing (#133).

- A merge that fails on a GitHub server error (a 5xx, a timeout, a dropped connection) is tried
  again on later passes, up to `MERGE_RETRY` (default 3), before it needs you; a refusal still
  needs you at once. Removing `needs-you` from an accepted PR stopped at the merge, with no
  comment, tries the merge again (#130).
- Worker and reviewer prompts and `CLAUDE.md` call the person who accepts the product owner (#131).
- `canccu-dispatcher config set KEY=VALUE` and `config unset KEY` check a setting, write only its
  line (atomically, checked with `bash -n`), keep a `config.history` line, and refuse a locked
  setting to the leader and to runs, which now carry `CANCCU_ACTOR=run` (#109).
- `canccu-dispatcher config show [--project <name>] [--global] [--origin] [KEY…]` prints every
  setting with its value, its default and the file it comes from; `lib/canccu-settings.tsv` lists
  every setting's type, file and whether it is locked (#108).
- A host profile for a Claude Pro plan: `HOST_PROFILE=pro` (`hosts/pro.conf`) runs one thing at a
  time with small budgets and `REVIEW_EFFORT_MAX=medium`; it sets no model. The getting-started
  guide's paste block for a small plan is now that one line (#101).
- A merged PR that leaves an issue of its unit open no longer parks the unit for good: the issue
  gets `needs-you` and a comment, and the unit is released; `ready` builds it again from main. An
  issue its `Closes` names gets `MERGE_WAIT_MIN` to be closed by GitHub first. A finished
  package's issue that is open again no longer stops its step (#86).
- Contract-first PRs work for single issues: the issue's branch is kept in its state, and its
  prompt has the same contract rule as a package's. A PR that names no issue (no `Closes`, no
  `Plan for`) is never merged automatically, whatever its branch (#87).
- A contract-first PR that GitHub would treat as closing an issue never reaches a review or an
  accept: the worker is resumed once to correct its body, then `needs-you` (#98).
- A fresh follow-up run always keeps its safety rules: they come first in its prompt, and the
  handoff no longer repeats the whole first prompt. A fix round's long findings are read from the
  findings file. Workers use no subagents, packages included (#88).
- `REVIEW_EFFORT_MAX` (`low`, `medium` or `high`) caps the effort of every review and fix-check on
  the machine, gated paths and agent configuration included; empty, the default, changes nothing
  (#84).
- A running dispatcher reads its config files again at the next pass when one changed: a raised
  `STEP_BUDGET` applies without a restart. A syntax error keeps the old values; `REPO`, `CLONE`
  and `GH_CONFIG_DIR` still need a restart. A step at `STEP_BUDGET` still reviews, fix-checks
  and merges its open PRs; only new workers, resumes and answers wait (#65).
- A `plan-ok` or `needs-work` issue whose blocker is open no longer reserves a run slot: with one
  slot, a runnable issue starts instead (#69).
- An old usage reading no longer throttles: one older than `USAGE_MAX_AGE_MIN` (6 hours) or than
  the dispatcher's start counts as unknown, so a restart after an account switch ends a drain. The
  usage text shows the reading's age (#64).
- A failed GitHub read of a passed PR is tried again next pass (`retry:` from `canccu-classify`)
  instead of asking for an accept. A review's fix round and the resume after a merged contract PR
  wait for the end of a back-off without changing any state. A passed review's list of what it
  checked no longer counts as blocking findings in the spend log; the reviewer lists its blocking
  findings under `Blocking:`, and a `changes` review without that heading still counts its items
  before `Non-blocking:` (#94).
- A reviewer that ends `done` without a valid review file is asked once per head, in its own
  session, to write it; only a second miss goes to `needs-you` (#93).

## [0.1.2] — 2026-11-10

Fewer false alarms and wasted runs, plan-only PRs, and the repo's own merge method (PR #60).

- `blocked` is a hold: a labelled issue is never started or resumed. The dispatcher removes only
  a `blocked` it set itself. To wait on a dependency, use a `ready` issue with a blocked-by link
  instead. **Breaking:** a `blocked` that someone else set is no longer swapped for `ready` when
  its links close (#59).
- A worker that ends with no PR and a `Status: blocked` or `not started` line waits quietly
  (phase `waiting`, the dispatcher's own `blocked`), with no needs-you and no answerer. A run that
  ended with no PR starts a fresh session instead of resuming the old one (#59).
- Plan-only PRs: a PR is matched by its `Closes` lines, a `Plan for #n` line or its `<n>-…`
  branch. After a plan PR merges, its issues get `ready` and `plan-ok`, and the next start builds
  the merged plan (#46).
- Merges pass the repo's allowed method when it has no merge queue (squash, else merge, else
  rebase). A PR that has already merged counts as merged, not as a rejection (#45).

## [0.1.1] — 2026-11-09

Ports from the original dispatcher, and one new fix.

- An extra fix round now ends in a fix-check, not a new full review (#28, PR #48).
- Review effort follows the risk class (`EFFORT_DOCS_PATHS` adds paths that count as docs), and
  the review and fix-check models can be set per kind (`REVIEW_MODEL`, `FIXCHECK_MODEL`) (#30,
  PR #51).
- A fair share of `TOTAL_CAP` across projects: a project over its share yields at the next phase
  boundary (#16, PR #53).
- Large JSON values (issues, PRs, milestones, plans) reach jq as files, not arguments. Step logic
  no longer stops when a repo's open issues pass Linux's 128 KiB argument limit (#54, PR #55).

## [0.1.0] — 2026-11-09

The first public version.

- Import: the dispatcher, run engine, monitor and tests, with neutral defaults; host profiles
  (`HOST_PROFILE`, `hosts/<profile>.conf`) and the version in `canccu-status`, its snapshot and
  the monitor's header.
- Installer: `install.sh` installs versioned releases under a `PREFIX` and switches between them
  atomically (docs/install.md); `canccu-dispatcher --version`, `doctor`, `rollback` and
  `uninstall`.
- CI and release: the local check on the newest runner and on Debian 12, an install test of the
  release tarball, `release.yml` publishing a release from a `v*` tag, the review gate as
  templates for a target repo (`templates/repo/`), issue and PR templates, and Dependabot.
- Docs: a README to a first merged PR, guides in `docs/`, the reference in short per-topic files
  under `docs/reference/` (checked by `tests/canccu-docs.sh`), the repo-contract snippets,
  `CONTRIBUTING.md` and `SECURITY.md`.
