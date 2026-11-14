<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Changelog

Every release of canccu-dispatcher, newest first. The version is in `VERSION`;
`canccu-dispatcher --version` prints it.

## Unreleased

- Upgrade note: a project without its own `gh` login (`GH_CONFIG_DIR`, or
  `~/.canccu/projects/<name>/gh`) no longer runs on the host's default login: it starts no run
  until it gets its own login or its config sets `ALLOW_DEFAULT_GH_LOGIN=1` (new, default `0`,
  locked). `canccu-dispatcher doctor` names such projects with the steps. Issue, PR and milestone
  titles lose their control characters before they reach a terminal, the monitor or
  `dispatch.log`. `docs/security.md` states that the reviewer token's deny rule covers the
  session's own Read and Edit tools only (#173).

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
