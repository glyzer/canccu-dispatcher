<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Changelog

Every release of canccu-dispatcher, newest first. The version is in `VERSION`;
`canccu-dispatcher --version` prints it.

## Unreleased

- The superpowers plugin is optional (#43). With `WORKER_SKILLS` empty (the default), the
  worker and package prompts and the plan-OK resume carry the method in plain words (test first,
  find the cause, read the checks, keep to the issue); a set `WORKER_SKILLS` replaces it. No run
  prompt names a superpowers skill unless `WORKER_SKILLS` does: the skills a worker must not use
  are described, not named. `canccu-dispatcher doctor` prints a `host: skills:` line. A host that
  sets the old Max preset can append the new sentence from [`docs/hosts.md`](docs/hosts.md#a-max-host).

## [0.5.0] — 2026-11-27

Release 0.5: step 7's token cost work, the rest (CI digest, cheaper narrow runs, review checklist).

**Upgrade:**

- Narrow runs default to the cheaper model (#329): your comment on a `needs-you` from CI, a
  review or a fix-check now resumes the worker on `FIX_MODEL` and `FIX_EFFORT` (was `MODEL` and
  its effort); a plan, a question or a refused accept stay on `MODEL`. A line `opus` or
  `model: <id>` in the comment picks the model. Merge runs (main merged into a PR, a contract
  merged) use the new `MERGE_MODEL` (default empty: `FIX_MODEL`, then `MODEL`; was `MODEL`), the
  answerer the new `ANSWER_MODEL` (default empty: `MODEL`, as before). To keep 0.4.0's models,
  set `MERGE_MODEL` to your `MODEL` and answer with `opus` or `model: <id>`.
- A release-red issue is rerun before it is work (#332): `RELEASE_RED_LABEL` (new, default
  `release-red`; empty turns it off), `FLAKY_FILE_AFTER` (`2`) and `CI_INFRA_PATTERN`. A project
  whose release workflow files such issues gets the rerun with the update.
- The fix-check or full review count after a merge of main (#336): a merge of main counts no line
  toward `FIXCHECK_FULL_LINES`, its conflicts resolved by hand or not, so fewer full reviews.
  `FIXCHECK_COUNT_RESOLVED` now sets only the fix-check's effort.
- Other new settings, all project keys: `CI_DIGEST_PATTERN`, `CI_DIGEST_LINES` (`120`, #327);
  `CONTEXT_PACK_MODEL` (empty: off) and `BUDGET_PACK` (`30 1 15`, #333); `PRE_PUSH_CMD` (empty:
  off) and `PRE_PUSH_MAX_SEC` (`600`, #328). Review effort defaults are unchanged.
- The state format stays `5`: no migration.
- Going back to 0.4.0: run `canccu-dispatcher rollback` in
  [the sequence](docs/upgrading.md#going-back); the state needs no change. 0.4.0 ignores the new
  keys, so its comment resumes and merge runs use `MODEL` again. If you set `PRE_PUSH_CMD`, unset
  it and let each open worker run once first: a 0.4.0 run leaves a worktree's pre-push hook in
  place.

**New:**

- The full review gets a numbered acceptance checklist built by script (#330): the items under an
  Acceptance heading and every `- [ ]` line of the issue, and for a package its plan's tasks. The
  reviewer answers each in a `Criteria:` block (met with evidence, not met, or not this part); a
  `pass` with an item not met or unanswered becomes `changes`, with that item as a blocking
  `[criterion]` finding. No criteria: no change.
- A red-CI fix run gets a failure digest of every failing job, built by script, instead of the
  last 60 lines of the first one's log (#327): the lines `CI_DIGEST_PATTERN` matches with their
  next 8 lines, and the test and lint summaries, each job under its name; no ANSI codes,
  timestamps, compose output or teardown; at most `CI_DIGEST_LINES` (default `120`) lines. A log
  with no match still gives its tail (`CI_LOG_LINES`).
- A release-red issue (`RELEASE_RED_LABEL`, default `release-red`) is not work until the
  dispatcher reran the failed jobs at its commit once (#332). Green closes it: each failed check
  gets one `flaky: <check>` issue that counts its failures and is `ready`, last in the queue, from
  `FLAKY_FILE_AFTER` (default `2`); an infrastructure error (`CI_INFRA_PATTERN`) files nothing. Red
  leaves it as work, with the failure digest. `RELEASE_RED_LABEL=` turns it off.
- After a contract PR merges, a draft whose worker reported `Package work: done` gets main merged
  in by script and is marked ready, with no run (#331). Unfinished work, no such line or a merge
  conflict resumes the worker on `MERGE_MODEL`. The contract rule asks for the line.
- An experiment, off by default: `CONTEXT_PACK_MODEL` (#333). Set, a package's first build starts
  with a short run on that model (`BUDGET_PACK`, default `30 1 15`) that writes
  `.canccu/context.md` in the worktree (never committed); the build prompt says to read it before
  exploring. spend.log type `pack`; once per package; a failed pack is logged and the build goes on
  without it.
- A pre-push check in worker worktrees, off by default: `PRE_PUSH_CMD` (#328), under
  `PRE_PUSH_MAX_SEC` (600). Set, each worker worktree gets a `pre-push` hook that runs it on the
  changed files; a failure refuses the push with the last 80 lines of its output, and a tool
  guard refuses `--no-verify` (logged as a warning). The doctor shows the command and flags one
  it cannot find.

**Fixed:**

- A CI digest of a job whose failure prints only under a compose prefix falls back to the log's
  tail again; a flaky check's failing lines are its own job's block only; a `needs-work`
  comment's model line holds on an owed or extra fix round (#348).

## [0.4.0] — 2026-11-26

Release 0.4: step 5's fixes after 0.3 and step 6's token cost work (the review fix loop).

**Upgrade:**

- Review fixes have their own budget, and a full review runs once per PR cycle (#325, #326):
  - the new `REVIEW_FIX_ATTEMPTS` (default `1`, `0`–`10`, project setting) counts the automatic
    review fix runs per PR (state key `rfixes`, the extra round of `FIX_EXTRA_IF_FEWER` too);
  - review fix rounds no longer use `FIX_ATTEMPTS`: it now counts only red-CI fixes, so red CI
    before the review never takes the review's fix round;
  - a full review's `changes` with no review fix run left now keeps its round open for your
    comment (`fix_owed`, a `needs-you`) instead of ending it. Set `REVIEW_FIX_ATTEMPTS` in the
    project's `config` to give a PR more automatic review fix runs;
  - the extra round of `FIX_EXTRA_IF_FEWER` runs past both caps, even with `FIX_ATTEMPTS=0` and
    `REVIEW_FIX_ATTEMPTS=0`; `FIX_EXTRA_IF_FEWER=0` is its only off switch (#340).
- The state format is now `5` (#277). The upgrade marks each step that may be finished (idle or
  health-due, no deep review or health pass yet, no cadence round, no unit of its own) with
  `pre5=1`. On its next pass, a marked step that is current with its work done is not owed a deep
  review or health pass (`deep=skipped health=skipped`): it goes on to its checkpoint, or ends,
  and the next step starts. A marked step with open work loses the marker and keeps its end
  passes, so a step between waves is not cut short. The weekly drain holds a deep
  review like a health pass, but a usage reading older than the dispatcher's start counts as
  unknown, so right after an upgrade restart nothing is draining until a run reports usage
  again.
- An ended step is never asked about its budget (#307): a step with no open work that is at its
  checkpoint, done, or past its health pass opens no `hold-budget-<m>` and gets no `needs-you`,
  so a step finished before the upgrade with its spend over `STEP_BUDGET` just ends. A hold
  already open stays. `canccu-dispatch --dry-run` now applies the migrations in memory (it still
  writes nothing), so it shows what the first real pass after an upgrade would do.
- Run tags keep a project's `_` (#317): before, `web_x` and `web--x` shared a tag and each
  one's sweep removed the other's containers, networks and volumes, and `web`'s sweep could reach
  `web_x`'s. A unit open since before the change still has objects under the old tag
  (`canccu_web-x_<key>` for `web_x`): its end removes them too, unless a project `web-x` exists.
  A run resumed after the change gets the new `COMPOSE_PROJECT_NAME`, so its Compose stack
  starts again beside the old one, which goes at the unit's end.
- `MERGE_TRIES` is no longer read (#313, #323): the scripted merge of main gives up after 3
  errors in a row, fixed.
- Going back to 0.3.0: stop the dispatcher, write `4` to the project's `state.format`, then roll
  back ([`docs/upgrading.md`](docs/upgrading.md#going-back)). 0.3.0 does not read
  `REVIEW_FIX_ATTEMPTS`: its review fixes count in `FIX_ATTEMPTS` again.

**New:**

- One full review per PR cycle (#325): your comment on a kept round, or `needs-work`, resumes
  the worker as that fix run (`FIX_MODEL`) on the saved findings plus your comment's items, and
  its push gets a fix-check of `<reviewed head>..<new head>`. A new full review only with a
  `full review` line, on a refused accept, or when the PR's own files changed more than
  `FIXCHECK_FULL_LINES` (lines merged from main never count). That run counts in no fix budget.
  `canccu-status` lists `fix runs:` (`#5 · PR #50 · fixes: ci 2/2 · review 0/1`); the
  snapshot's `running[]` items get `fixes` (#326).
- Cost report (#270): `canccu-status --costs [--since DATE] [--top N]` shows the cost by run
  type, the most expensive issues with their fix rounds, and the cost by kind. The daily digest
  gets a `Cost today` line and a line for each issue with more fix runs than
  `COST_ROUNDS_ALERT` (rules, default `5`, `0` off). The rules key `COST_KINDS`
  (`<name>=<regex>;…`) groups costs into kinds by the merged PR's title; the rest is `other`.
- The monitor's Queue view (#293): key `5` or `--view queue` lists a project's open issues once
  each in take order under Running, Needs you, Queue. The snapshot gets `unscheduled[]` (issues
  waiting for the ready label), and `step_overview[].issues[]` is filled for later steps too.
- Runs clean up their containers (#238): a run's tag (`canccu_<project>_<key>`) reaches it as
  `CANCCU_RUN` and `COMPOSE_PROJECT_NAME`, and its rules say to label containers with it and to
  use `$TMPDIR`, not `/tmp`. The tagged containers, networks and volumes of a unit go when it
  merges, closes or is forgotten; each pass sweeps those no unit or live run holds, and the stale
  run temp dirs (before: only at the dispatcher's start). `doctor` warns when `/tmp` or memory
  has under 10% free, and names untagged containers running for over 2 days
  ([`engine.md`](docs/reference/engine.md)).
- CI (#301): `CI (oldstable)` runs `tests/run --short` (a fixed set of 29 parts, every shell file
  linted) within 20 minutes. The whole suite runs on Debian 12 in the new `Nightly` workflow (a
  red night opens or updates the issue "Nightly: the full check on Debian 12 failed") and before
  `release.yml` publishes.

**Fixed:**

- Pipeline and monitor fixes (#296, #298): a review budget stop retries instead of parking; a
  `ci_rerun` that never starts is given up after a bound; a recurring finding is recorded once per
  PR and its `@` is defanged; `merge_method` answers are validated; the merge waits for the PR's
  head not to move; the monitor keeps its last view-bar hint at 81 to 84 columns, `a` closes the
  help overlay, and `--rotate 0` is refused with a reason. `TEST_TIER` is named in the repo
  snippets and the reviews reference.
- Messages and engine fixes (#295, #297): an accept is kept after a refused merge; a timed-out
  ping adopts only its own comment; a permanent Telegram refusal is given up, not retried; the
  ask form shows the summary of the last verdict that passed; Telegram replies read by a killed
  pass do not reach the inbox twice; a failed claim issue create makes its label and retries.
- Telegram and review fixes (#317): a refused Closed: edit or topic close no longer holds up the
  lines behind it (only Telegram not reached ends the loop), and "message can't be edited" is
  given up; an SVG whose fetch fails with a 404 in its path or error text is tried again (only
  gh's `(HTTP 404)` skips it); a finding written `* Change: …` counts as a finding.
- Review effort (#269, #280): a docs-only diff (`^docs/` or `.md`) is reviewed at `medium` even
  when a path matches `RISKY_PATHS`, and `EFFORT_DOCS_PATHS` filters on the path, so a
  `$`-anchored pattern works.
- A refused CI rerun (the workflow is still running) waits for a later pass instead of spending a
  fix run (#246).
- A step without a checkpoint issue gets its deep review and health pass (#278); before, the
  next step was planned.
- `canccu-status --findings` counts a finding, not its leading `[class]` tag (#284).
- `canccu-run` starts and resumes a worker by hand again (#309): `lib/canccu-continue.sh` is now
  sourced by `lib/canccu-runs.sh`, so the budget and the progress mark exist outside the dispatcher.

## [0.3.0] — 2026-11-22

Release 0.3: step 4's packages and the follow-ups of the 0.2 and 0.3 reviews.

**Upgrade:**

- The state format is now `4` and is upgraded at start; the upgrade changes no field (the step
  field `round_from` starts empty, #218). 0.2.0 refuses the upgraded state: to go back, stop the
  dispatcher and write `3` to the project's `state.format` before the rollback
  ([`docs/upgrading.md`](docs/upgrading.md#going-back)).
- A 0.2.0 dispatcher does not watch for a new release: upgrade to 0.3.0 with
  [the sequence](docs/upgrading.md#the-sequence). From 0.3.0 on, the loop moves to a newly
  installed release by itself between passes (#20): `UPGRADE` (`auto`, or `manual` to only show
  it) ([`docs/upgrading.md`](docs/upgrading.md#between-passes)).
- The v2 workflow is on by default (#242): light package reviews, the step deep review at
  `medium` effort (capped by `REVIEW_EFFORT_MAX` now, like every review), step tags, budgets by
  size, weekly pacing and cadence rounds. A project that sets none of these keys changes with the
  update. To keep the old value, set it in the project's `config` (rules key: its `rules`):
  - `REVIEW_LIGHT=0` (rules; was `0`, now `1`);
  - `STEP_DEEP_REVIEW=0` (now `1`);
  - `DEEP_REVIEW_EFFORT=high` (now `medium`; the `max` host profile keeps `high`);
  - `STEP_TAG=''` (now `step-{n}`);
  - `BUDGET_LINES=0` (now `300`);
  - `PACE=off` (now `cap`);
  - `CADENCE_DAYS=0` (now `14`; a round runs only in a milestone marked `Cadence: on`);
  - `FIXCHECK_COUNT_RESOLVED=0` (now `1`).
- A worker's test runs stay small by default (#209, #250): the new `TEST_TIER` (`targeted` by
  default and in both host profiles) tells every worker, fix round and fix-check to run only the
  test files of the areas it touched plus `tests/run repo`; `full` has it run the full suite once
  before the PR is ready. CI runs the full suite either way; `doctor` prints the tier
  ([`hosts.md`](docs/reference/hosts.md#the-test-tier)).
- The dispatcher claim (#15, #271): one dispatcher per repo across hosts. A pinned issue labelled
  `dispatcher-claim` names the host that runs the repo; the first pass that finds none creates it,
  and keeps it while GitHub does not list it yet. Another host's dispatcher does nothing while the
  claim is fresh, and `canccu-dispatch --take-over` takes it
  ([`docs/hosts.md`](docs/hosts.md#the-dispatcher-claim)). Leave the claim issue open. New keys:
  `HOST_LABEL`, `CLAIM_RENEW_MIN`, `CLAIM_EXPIRY_MIN`. New file: `~/.canccu/host-id`.
- An accept survives the dispatcher's merges of main (#244): `KEEP_ACCEPT_ON_MAIN_MERGE` now
  defaults to `1`. An accept by the label or by `canccu-ship` carries over clean merges of main,
  and merges whose conflicts were resolved inside the PR's own files once their fix-check passes.
  Set it to `0` in the project's config to be asked after every push, as before. `canccu-ship` on
  a head with no review pass records the accept and arms nothing: the head gets its fix-check
  first.
- Host settings (#14), for a 0.2.0 host:
  - the `max` profile's `CAP` is now `2` (was `3`); set `CAP=3` in `~/.canccu/config` to keep it;
  - the prompts name no superpowers skill unless the host sets it: to keep today's sentence, set
    `WORKER_SKILLS` as the Max example in `docs/hosts.md` does;
  - `~/.local/bin` and `~/.bun/bin` are no longer put on `PATH` by themselves: set
    `EXTRA_PATH=$HOME/.local/bin:$HOME/.bun/bin` to keep them;
  - `BASE_BRANCH` defaults to `main` and `MERGE_METHOD` to `squash`, as before.
- The review brake is on by default (`REVIEW_BRAKE=auto`, #195): when escaped defects rise above
  the baseline, reviews block as before Q1 until the product owner runs
  `canccu-dispatcher brake release`. Set `REVIEW_BRAKE=off` to never engage it by itself.
- One follow-up ticket per step (#223): the per-wave follow-up issues get nothing new; close them
  when they are triaged. An open fast-lane issue recorded before gets the new sections in its body.
- **Contract:** each `reviews.log` line gets an 11th field, `<kept>`: the pre-existing items the
  review brake kept. Lines written before read as `0` (#222).
- A managed PR (not a plan or contract PR) needs the lines `Testing:` and `Revert:` in its body
  (#192): one without them sends its worker back once to add them before the review.

**New:**

- Host settings (#14): one release runs on a Max and a Pro host, and what differs is a setting
  ([`docs/hosts.md`](docs/hosts.md#what-a-host-decides)). New keys: `BASE_BRANCH`, `CLONE_ROOT`,
  `EXTRA_PATH`, `GUARD_VMEM_KB`, `WORKER_SKILLS`, `REVIEW_SKILLS`, `HEALTH_CHECKLIST` and
  `MERGE_METHOD`. A merge queue is optional: without one an accepted PR merges with
  `MERGE_METHOD`. `canccu-init` writes `USER_LOGIN` (from gh's login; it refuses without one)
  and `BASE_BRANCH` (the repo's default branch). `canccu-dispatcher doctor` adds the host report:
  the profile, the keys the host's config overrides, and the last day's runs per issue with their
  cost. The profiles: v2 models, and review effort by plan (Max high, Pro medium); Pro keeps the
  budgets and usage thresholds of #168.
- Notifications on Telegram (#39): `NOTIFY` (`github`, the default, `telegram`, `both`, `off`)
  sends each ask of the product owner, a step done, a hold and a polish issue as one Telegram
  message at the change of state, in a forum topic per item (a reply chain in a private chat).
  The product owner's replies in an open topic land in `$CANCCU_HOME/inbox` for the leader;
  `canccu-notify` answers, notes, closes topics and sends images; `canccu-init --check <project>`
  checks the setup. New settings `TELEGRAM_CHAT_ID`, `TELEGRAM_USER_ID`, `TELEGRAM_TOKEN_FILE`;
  new feed kind `polish` ([`docs/reference/notify.md`](docs/reference/notify.md)).
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
- One ask form for every ask (#181): a ping is one comment per issue, edited in place, and an
  accept's PR body carries the same form, with three change lines from the reviewer's `Change:`
  section ([`pings.md`](docs/reference/pings.md#the-ask-form)). `NOTIFY_CONTENT=link` (default
  `full`) cuts an ask to its first line, last line and link; under it a passed PR's SVGs are not
  sent to Telegram (#264).
- The leader (#187, #186): `canccu-init --leader <project>` writes a leader kit (`CLAUDE.md` and
  `.claude/settings.json`) to `~/.canccu/projects/<project>/leader/` and sets `LEADER=on`; with
  `LEADER=on`, `canccu-up` starts the left pane's `claude` there, titled `leader`, with
  `CANCCU_ACTOR=leader`. The reference topic of the role is now `leader.md`, and the docs call it
  the leader. `canccu-dispatcher leader brief` is its first command, read only. `canccu-ship`,
  `canccu-pause`, `canccu-resume`, `canccu-stop`, `canccu-run`, `canccu-notify` and
  `config set`/`unset` write one line per call to the project's `actions.log`.
- The monitor has four views (#37): Summary (the default), Projects, Roadmap and Activity, with a
  one-line strip on top, a view bar at the bottom and keys (`1`–`4`, `Tab`, the arrows, `j`/`k`,
  `PgUp`/`PgDn`, `Home`/`End`, `p`, `a`, `r`, `?`, `q`) read in cbreak mode when stdin is a
  terminal. `--view <name>` picks the start view, also with `--once`; `--rotate [secs]` cycles
  them.
- A worker that stops at its turn or time budget while its PR moves on continues on its own
  (#127): up to `CONTINUE_MAX` (default `3`, `0` turns it off) fresh runs with its handoff, each
  with a run's turns and minutes and the USD the unit's work budget has left; `needs-you` only
  without progress (no PR, no new pushed commits) or once those are used. A resume after the
  usage limit gets the rest of the work budget, never less than `BUDGET_RESUME`
  ([`usage.md`](docs/reference/usage.md#continuations)).
- A worker that pushed its branch but could not open the PR (its `gh pr create` denied, or a
  finish run spent) no longer ends in `needs-you` (#237): the dispatcher opens the PR itself, from
  the worker's body file inside its worktree or a body built from the issue and the run's
  Testing:/Revert: lines, as a draft if the worker asked for one, and says so in the PR and the
  log. `needs-you` stays without a pushed branch of the issue with commits ahead of main.
- The review brake (#195): an escaped defect is an issue or PR with a `Regression of: #<pr>`
  line. Above the baseline, or on a red run of the reviewer's test set, the brake engages: no
  demotions, no no-repeat rules, no light reviews, the full review one effort step higher
  ([`review-depth.md`](docs/reference/review-depth.md#the-review-brake)). New keys:
  `REVIEW_BRAKE`, `BRAKE_WINDOW`; `canccu-status --kpi-review` lists the last merged PRs.
- Recurring findings (#194): findings of the same class and file on `FINDINGS_RECUR` (3) merged
  PRs within `FINDINGS_RECUR_DAYS` (30) days file one issue `Recurring finding: <class> in
  <file>`, not `ready`; a later PR comments on it
  ([`findings.md`](docs/reference/findings.md#recurring-findings)).
- An optional `REVIEW.md` at the repo root, read from `origin/main` (#193): its sections
  `Also check`, `Never blocks` and `Known false positives` (4000 characters at most) go into the
  review and fix-check prompts; it can add checks, never make a blocking class non-blocking.
  The file is a gated path ([`docs/repo-contract.md`](docs/repo-contract.md)).
- One follow-up ticket per step (#223): non-blocking findings go into the body of
  `Follow-ups: step <title>` (in the step's milestone) or `Follow-ups: fast lane`, one
  `### PR #<pr> (…)` section per verdict, one `- [ ]` line per finding; a body past 60000
  characters opens `(part 2)`. A pre-existing security finding gets an issue of its own, labelled
  `security`, instead of labelling the ticket.
- Fix-check by number (#229): the fix run and the fix-check get the blocking findings as
  `Finding 1:` to `Finding <c>:`, and the fix-check answers each on its own line. A `pass` that
  leaves one out, or calls one not fixed or broken, is `needs-you`, not a pass.
- A ready step issue outside the running wave no longer waits unseen (#236): `canccu-status`, the
  brief and the monitor list it as `waiting for the next wave of step <n> (label fast to run it
  now)`. It is not added to the running wave; the next wave plans it
  ([`packages.md`](docs/reference/packages.md#the-planner)).
- The scenario suite (#189, #271): `tests/scenarios/run --repo <owner/sandbox>` runs the real
  dispatcher against a sandbox repo with a fake engine (no model tokens); `tests/scenarios/setup
  --repo <owner/sandbox>` gives a sandbox its standing setup (safe to run again). `queue-removal`
  is skipped on a sandbox without a merge queue ([`scenarios.md`](docs/reference/scenarios.md)).
  A release PR (one that changes `VERSION`) needs the body line `Scenarios: pass at <short sha>`.
- The reviewer's test set (#196): `tests/review-set/run [--model m] [--effort e] [--light]` runs
  the real review prompt on 12 fixed cases and logs the result to `review-set.log`. A red run
  against its baseline engages the review brake. A release PR whose diff since the last tag
  touches the review prompt or the verdict handling needs `Review set: pass at <short sha>`.

**Fixed:**

- A step whose last work issue closes after its wave ended (a polish PR still merging) keeps its
  turn (#239): it gets its health pass and checkpoint pause before the next step starts, with or
  without a checkpoint issue.
- A step at its checkpoint with new open work in its milestone goes back to planning (#243): the
  work no longer waits for the `checkpoint-ok` it is meant to earn; the health pass and a fresh
  summary follow once it is closed.
- CI red (#256): a job cancelled at its own time limit is rerun once and named `CI (timed out)`;
  a check green on its newest run is no longer named red.
- Merge (#213): GitHub's "clean status" refusal of auto-merge merges the PR directly at the same
  head; with auto-merge off, a PR that conflicts with main gets the merge of main, not `needs-you`.
- `canccu-review` on a PR that closes several issues takes the issue its branch names (#220).
- Workflow v2's leftovers (#218): an `&` in `HIGH_RISK_TEXT` stays an `&` in the light prompt; a
  cadence round whose checkpoint is gone ends; a round keeps its base unless the last round's
  report merged; the package names `deep` and `deep-r<n>` are reserved.
- The follow-ups of the 0.2 reviews (#222, with #226, #233 and #235):
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
- This repo's CI: the `CI` job's time limit is 20 minutes, not 12 (the suite takes about 12
  minutes on `ubuntu-latest`); `CLAUDE.md`'s finish runs `tests/run repo`, not the full suite.

## 0.2

The 0.2.0 release is in [`docs/changelog-0.2.md`](docs/changelog-0.2.md).

## 0.1

The 0.1 releases (0.1.0 to 0.1.4) are in [`docs/changelog-0.1.md`](docs/changelog-0.1.md).
