<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# canccu-dispatcher

Run Claude Code against your GitHub issues with as little human input as possible: **a worker
implements, an independent reviewer reviews, and the PR merges when the review passes and CI is
green.** Roadmap steps run as work packages, risky changes wait for your accept, and a terminal
monitor shows what needs you.

**Pre-release.** The commands, the run engine, the monitor, the installer and these docs are
here; interfaces may still change between releases ([`CHANGELOG.md`](CHANGELOG.md)).

## What it does

- Polls each repo you add (a *project*) every minute. An issue you label `ready` gets a worker: a
  headless `claude -p` session in its own git worktree, which opens a PR and stops once CI is
  green, or stops with a question.
- Reviews every PR with a fresh, independent Claude session that never sees the worker's session
  or the repo's agent settings. A second GitHub account, the reviewer bot, posts the review; only
  its verdict for the PR's current head counts.
- Merges a passing PR (auto-merge, or a merge queue) pinned to the reviewed commit. A review that
  asks for changes gets one fix and one narrow fix-check, never a loop.
- Leaves to you what should be yours: plans, escalated questions, PRs that touch gated paths or
  agent configuration, high-risk work, step checkpoints. It @mentions you on the issue.
- Bundles a milestone's issues into work packages, ends each step with a health pass and a
  checkpoint, throttles itself on your Claude usage, and stays inside step budgets.

## What it does not do

- It runs no AI itself: the dispatcher is bash, `gh` and `jq`. It never merges without a passing
  review on the current head and green CI, and never touches a PR that is not its own.
- It never changes rulesets, secrets, repo variables or collaborators, and never creates a token.
- It does not write your issues or decide scope: you (with the lead, an interactive Claude
  session) do. It does not deploy, and it is no hosted service: it runs on your Linux host.

## Prerequisites

- **Linux** with bash ≥ 5.0, git ≥ 2.30, jq ≥ 1.6, tmux ≥ 3.2, python3 ≥ 3.10 (the monitor), GNU
  coreutils, `flock` and procps.
- **gh**, the GitHub CLI.
- **Claude Code** 2.1.319 or newer, logged in to a Claude subscription, with the superpowers
  plugin (the worker prompts name its skills).
- **A second GitHub account** for the reviewer bot, with a token (mode 600 in
  `~/.canccu/reviewer-token`). It must accept each repo's collaborator invitation.

`./install.sh --check` checks the tools.

## Each repo needs

Details and the review gate's contract: [`docs/repo-contract.md`](docs/repo-contract.md).

1. The reviewer bot as a **collaborator** with write access (the bot accepts the invitation).
2. The repo variable **`REVIEWER_LOGIN`** set to the bot's login.
3. A **CI check** that runs on every pull request (and on `merge_group` with a merge queue).
4. The **review-gate workflow** and its script, copied from `templates/repo/.github/` (0BSD), and
   the `CLAUDE.md` and `AGENTS.md` sections from `templates/repo/*.snippet.md`.
5. A **ruleset** on the default branch requiring CI and `review-gate`. A merge queue is optional.

## Set up and run

Step by step, with examples: [`docs/getting-started.md`](docs/getting-started.md).

```sh
./install.sh --host-profile max          # a release under ~/.local; commands in ~/.local/bin
$EDITOR ~/.canccu/config                 # USER_LOGIN=<you>, REVIEWER_LOGIN=<the bot>
canccu-init web example-org/web          # a project: config, rules, labels, and a checklist
canccu-dispatcher doctor --project web   # one line per problem; "no problems found"
canccu-dispatch --project web --dry-run  # what one pass would do; changes nothing
canccu-up --project web                  # the tmux session: lead, monitor, dispatcher
```

`canccu-init` prints what is left by hand: the repo's side above, the clone, and a narrow
fine-grained token for the project ([`docs/reference/projects.md`](docs/reference/projects.md)).

**A first issue to a merged PR.** Write an issue with a Goal, Acceptance criteria, Out of scope
and a `Risk:` line, and label it `ready`. The dispatcher starts a worker in window `#<n>`, the
worker opens a PR on `<n>-<slug>`, the reviewer posts `Review verdict: pass <sha>` as the bot,
`review-gate` turns green, and the PR merges. Anything that needs you appears in the monitor's
NEEDS YOU box; `canccu-status` says the same in text.

## Upgrade, uninstall, state

- **Upgrade**: `canccu-pause`, stop the dispatcher between passes, wait for the runs to end,
  `./install.sh` from the new release, restart the dispatcher, `canccu-resume`
  ([`docs/upgrading.md`](docs/upgrading.md)). `canccu-dispatcher rollback` goes back.
- **Uninstall**: `canccu-dispatcher uninstall` removes the links, the release tree and the
  monitor's venv, and keeps your state; `--purge-state --yes` removes the state too
  ([`docs/install.md`](docs/install.md)).
- **State** lives in `~/.canccu` (or `CANCCU_ROOT`): the global `config`, the reviewer token, and
  one dir per project under `~/.canccu/projects/<name>/` with its config, rules, worktrees, logs
  and status snapshot ([`docs/reference/state.md`](docs/reference/state.md)). The code lives
  under `~/.local/lib/canccu-dispatcher/`.

## Docs

[`docs/README.md`](docs/README.md) lists the guides and the reference: every setting and
behaviour, one short file per topic. The security model is in
[`docs/security.md`](docs/security.md); reporting a problem in [`SECURITY.md`](SECURITY.md);
working on the tool itself in [`CONTRIBUTING.md`](CONTRIBUTING.md).

Licence: AGPL-3.0-or-later ([`LICENSE`](LICENSE)); the files under `templates/` are 0BSD
([`templates/LICENSE`](templates/LICENSE)).
