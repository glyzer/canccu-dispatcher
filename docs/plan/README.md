<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The plan to 1.0

This folder is the baseline for all work on canccu-dispatcher until release 1.0. The planner, the
workers and the reviewer read it; an issue that disagrees with it is wrong until the plan is changed.

| File | Holds |
|---|---|
| this file | the goal, the rules, the roles, the decisions, the releases in outline |
| [`0.2.md`](0.2.md) | release 0.2, package by package, in order |
| [`contracts.md`](contracts.md) | the formats several packages share: owners, classes, the feed line, the ask form, new settings, new state fields |
| [`issue-template.md`](issue-template.md) | the sections every work issue has |

## How the plan is used

- **Issues** follow `issue-template.md` and name their package. An issue is labelled `ready` only
  after its text was checked against the code at a named commit.
- **Workers** build what the issue says. A name, default, text or format that `contracts.md` fixes
  is used as written. When the code and the issue disagree, the worker stops with a `Question:`.
- **The planner** keeps the package order of the release file and does not move an issue to
  another package.
- **The reviewer** checks a PR against its issue and against the rules below. A PR that breaks a
  rule gets `changes`, whatever the issue says.
- **Changing the plan** is a PR to this folder that the product owner accepts. A worker never edits
  this folder as part of another issue; it writes a `Roadmap note:` in its PR body instead.
- Later releases are outlines. Each package is specified in full just before its issues are
  labelled `ready`, because the code will have moved by then.

## Goal

A dispatcher that other people can install and trust: reliable, automatic where that is safe, and
strict on quality. Cost and speed targets never override the rules below.

## Rules every change keeps

1. **No silent state.** Every managed unit is running, or waits on a named owner, or waits on a
   timer that ends in a needs-you. A unit that fits none of these for `IDLE_ALARM_MIN` minutes
   writes one feed line. A hold on all new starts (contracts §3, kind `hold`) is said the same way.
2. **No merge without a review of the exact head.** A cheaper check may replace a full review only
   inside stated limits (size, paths), and it always covers everything since the last full review.
3. **No new automatic accept on a signal a worker run can forge.** A feature that merges without
   the product owner stays off by default until package S2 is in.
4. **Works without the extras.** No leader, no Telegram and no systemd is a supported setup, and
   it is tested.
5. **A setting is done only with** its line in `lib/canccu-config.default`, its row in
   `docs/reference/config.md` (or `rules.md`), and a doctor line when a wrong value can stop work.
6. **Every fix of an incident ships its test** in the existing harness.
7. **Silence never means yes.** No timer, reminder or absence accepts, approves or merges
   anything. A wait that ends, ends in a needs-you.
8. **Settings that widen authority are the product owner's.** Accept, gating, security and
   notify-target keys are locked: the leader and the runs cannot change them.

## Roles

| Role | What it is | Decides |
|---|---|---|
| Product owner (`po`) | the person who owns the project | anything users see, checkpoints, product questions, rulesets, secrets, locked settings |
| Leader | an optional AI session that watches one project | from package L1: technical accepts inside `LEADER_ACCEPTS`; before it, nothing the dispatcher acts on |
| Worker | a headless run that builds one issue or one package | implementation details, listed under `Decisions made:` |
| Reviewer | a headless run that did not write the PR; posts as the reviewer bot | the verdict on one head |
| Dispatcher | the shell loop that starts runs, classifies, merges | nothing: it applies the rules |
| Monitor | the terminal view | nothing |
| Notifier | an optional service that pushes asks (from 0.3) | nothing |

"Leader" is the role's name everywhere. In code, `lead_of` keeps its other meaning: the issue that
stands for a unit on GitHub.

### What can be forged today

The product owner, the leader and every run share one Unix user and one GitHub login. A run can
therefore add the `accepted` label as the product owner, edit the project's rules, and read the
reviewer token through a subprocess. Rule 3 exists because of this. Packages S1 and S2 close it;
until then no leader accept is added or widened.

## Decisions (2026-11-11)

1. **Accept channels: all of them, none required.** The `accepted` label by `USER_LOGIN`,
   `canccu-ship` on the host, a reply through the notifier, and the product owner's word through the
   leader all work. `ACCEPT_CHANNELS` lets a user switch one off. At the hardened level, a
   channel an AI session can write does not count for gated and high-risk PRs.
2. **Two setup levels:** simple (one Unix user, limits stated honestly, every automatic-accept
   setting off until the product owner sets it) and hardened (separate users and identities).
3. **Steps:** the milestones `3 Release 0.2`, `4 Release 0.3`, `5 Release 1.0`, one checkpoint each.
4. **No deadline.** Packages run one after the other at full speed.
5. **Supported set:** Linux or WSL with tmux, Claude Code, GitHub.
6. **`NOTIFY_CONTENT`** is `full` or `link`, for users who want only a link to leave the host.
7. **During 0.2** the dispatcher's own merge, accept, review-posting and security files are gated
   in this project, so those PRs wait for the product owner. So will `docs/plan/` be: this project's
   rules are to add `^docs/plan/` to `GATED_PATHS` (a follow-up of #102); until then the leader
   holds plan PRs for the product owner by hand.
8. **Workers do not use subagents.** The limit is tokens, not time; the dispatcher is the parallel
   layer; a headless run loses its subagents when it ends.

## Targets

Measured per host and per release: cost per merged issue, lead time (with and without human
waits), share of follow-up runs, stuck incidents, manual leader actions, leader tokens and
product owner touches per merged issue. Added by this plan:

- **Escaped defects per merged issue.** A bug issue or a revert carries `Regression of: #<pr>`.
  Baseline in 0.2; 1.0 must be no worse while cost falls.
- **Stalls found by a person:** a unit that sat past `IDLE_ALARM_MIN` with no feed line. Target: 0.
- **Messages to the product owner per merged issue.** Baseline in 0.2; it must fall in 0.3.

## Release 0.2: stop the waste, close the holes

Twelve packages, in this order: P1, E1, C1, M1, R1, F1, N1, S1, S2, L1, P2, T1. See [`0.2.md`](0.2.md).

## Release 0.3: the product layout (outline)

- The notifier as its own optional service: batching, a daily digest for `info`, a daily cap, one
  reminder, quiet hours (empty = off; a dead dispatcher always gets through), captures as images,
  a reply `ok` that acts only on the head sha asked about and only for normal risk. It has a
  heartbeat; when it is silent the dispatcher says so and falls back to the GitHub mention.
- `canccu-up`: one tmux session per host, one window per project; workers in their own session.
- Dispatchers as `systemd --user` services, optional.
- The leader's own directory and memory per project, started and restarted by the tool.
- Monitor views, with a Settings view that writes only through `config set` and shows locked keys
  as locked.
- Host claim (one dispatcher per repo), host profiles, a model trial on routine packages,
  `status --kpi`.

## Release 1.0: reliable for others (outline)

- Every host-only behaviour is a setting; no third-party skills needed; the init check; one
  getting-started with two paths.
- `docs/roles.md`; one place owns the reviewer bot steps and the others link to it.
- `docs/install-with-ai.md`: numbered steps, each with a check command and its expected output,
  each marked "agent" or "you". The person-only steps come first and are few. An agent never sees
  a token. For it: `canccu-init --check --json`, `canccu-doctor --json`, `llms.txt`.
- The repo flow the prompts lean on ships as templates, and the init check verifies it.
- **Gate:** every target holds for 7 days; a stranger installs from the docs alone; a fresh AI
  session installs on a clean machine with only the "you" steps done by a person; the setup of
  rule 4 passes; no high finding is open.
