<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Getting started

From nothing to a first merged PR. The examples use the invented project `web` for the repo
`example-org/web`, your login `octo` and the reviewer bot `review-bot`; use your own.

## 1. The host

A Linux host (a VM or a spare machine: workers run code as your user, see
[`security.md`](security.md)) with:

- bash 5.0, git 2.30, jq 1.6, tmux 3.2, python3 3.10, GNU coreutils, `flock` and procps;
- `gh`, the GitHub CLI;
- Claude Code 2.1.319 or newer (`claude update`), logged in to a Claude subscription (`claude`,
  then `/login`). The usage throttle reads the subscription's usage shares; pick the host profile
  that matches the plan (`max` for a Max plan);
- the superpowers plugin in Claude Code (`/plugin`): the worker prompts name its skills
  (test-driven-development, systematic-debugging, verification-before-completion, writing-plans,
  executing-plans). The reviewer uses the `code-review` and `security-review` skills.

`./install.sh --check` checks all of it and names what is missing with how to get it.

## 2. The reviewer bot

A fresh Claude session reviews each PR; a second GitHub account, the reviewer bot, only
**posts** that session's verdict. The bot is not a review tool of its own: it is an account only
the dispatcher writes as, so `review-gate` can trust the verdicts it posts and no other.

1. Create a GitHub account for the bot (for example `review-bot`), with its own e-mail address.
2. As the bot, create a classic token (Settings → Developer settings → Personal access tokens →
   Tokens (classic)) with the `repo` scope (`public_repo` is enough when every repo is public):
   it posts comments on repos it is a collaborator of, which a fine-grained token cannot reach.
3. Store it, mode 600, and keep every Claude session away from it:

   ```sh
   install -d -m 700 ~/.canccu
   install -m 600 /dev/null ~/.canccu/reviewer-token    # then paste the bot's token into it
   ```

   In `~/.claude/settings.json`, add to `permissions.deny`:
   `"Read(~/.canccu/reviewer-token)"` and `"Edit(~/.canccu/reviewer-token)"`.

## 3. Install

Download a release (`vX.Y.Z`: the newest on the releases page), verify it and unpack it:

```sh
mkdir canccu-release && cd canccu-release
gh release download vX.Y.Z -R glyzer/canccu-dispatcher
sha256sum -c SHA256SUMS                     # must print: canccu-dispatcher-X.Y.Z.tar.gz: OK
tar xzf canccu-dispatcher-X.Y.Z.tar.gz
cd canccu-dispatcher-X.Y.Z
```

Check the host, then install:

```sh
./install.sh --check
./install.sh --host-profile max
```

A git checkout installs the same way, from its top directory.

It installs under `~/.local` (`--prefix` for another place), links the commands into
`~/.local/bin`, builds the monitor's venv, and writes `~/.canccu/config` with every default
commented out ([`install.md`](install.md)). Make sure `~/.local/bin` is on `PATH`.

Set your two logins in `~/.canccu/config` (there are no defaults):

```sh
USER_LOGIN=octo
REVIEWER_LOGIN=review-bot
```

`canccu-dispatcher doctor` should now complain only about things a project fixes.

**On a Pro plan.** Install with `--host-profile pro` instead, or set the one line in
`~/.canccu/config`:

```sh
HOST_PROFILE=pro
```

It runs one thing at a time with the same budgets as Max; the values are in
[`hosts/pro.conf`](../hosts/pro.conf) ([`reference/config.md`](reference/config.md), "Host
profiles"), and `~/.canccu/config` overrides any of them. It also sets the run models (Sonnet
for the workers, Opus for the planner and the reviews); a model line in `~/.canccu/config`
overrides them ([`reference/hosts.md`](reference/hosts.md)).

**Known limits.** Keep a test repo's full suite well under 10 minutes for now (#26), and never
run two dispatchers on one repo (#15).

## 4. Prepare the repo

In `example-org/web`, as its maintainer ([`repo-contract.md`](repo-contract.md) has the details):

1. Add `review-bot` as a collaborator with write access; as the bot, accept the invitation.
2. Set the repo variable `REVIEWER_LOGIN=review-bot` (Settings → Secrets and variables →
   Actions → Variables).
3. Make sure a CI workflow runs on every pull request (and on `merge_group` with a merge queue).
4. Through a PR, add the review gate from `templates/repo/.github/` and the
   `CLAUDE.snippet.md` / `AGENTS.snippet.md` sections to the repo's `CLAUDE.md` and `AGENTS.md`.
   Merge it yourself: it is the last PR you merge by hand.
5. Add a ruleset on the default branch that requires the checks `CI` and `review-gate`, and allow
   auto-merge in the repo's settings if your plan offers it.

## 5. Add the project

```sh
canccu-init web example-org/web
```

It writes `~/.canccu/projects/web/{config,rules}`, creates the labels, and prints the checklist
of the GitHub part of step 4 (not the snippets) plus two steps of its own:

- clone the repo to `~/code/web` (`git clone https://github.com/example-org/web ~/code/web`), and
  read `~/.canccu/projects/web/rules` ([`reference/rules.md`](reference/rules.md));
- create the project's narrow token and log its `gh` dir in with it
  ([`reference/projects.md`](reference/projects.md#a-narrow-token-per-project)). Without it the
  project starts no run: the default `gh` login is refused unless its config sets
  `ALLOW_DEFAULT_GH_LOGIN=1`.

**A safe start on a real repo.** Until you trust it, make every PR wait for your accept: in
`~/.canccu/projects/web/rules`, set `AUTO_MERGE_UNTIL` to today's date or any earlier one
(`YYYY-MM-DD`). It is the date the freeze starts, not the date it ends: from that date on, nothing
merges without you; a future date lets PRs merge on their own until then. Then add the repo's
sensitive paths to `GATED_PATHS` (a `grep -E` pattern; keep the default `^\.github/` in it):

```sh
AUTO_MERGE_UNTIL=2026-01-01   # a past date: every PR waits for your accept from now on
GATED_PATHS='^\.github/|^deploy/|^migrations/'
```

Accept each PR by labelling it `accepted` ([`reference/merging.md`](reference/merging.md)). After a few clean
PRs, remove the `AUTO_MERGE_UNTIL` line; the gated paths keep waiting for you.

Then check: `canccu-dispatcher doctor --project web` prints `no problems found`, and
`canccu-dispatch --project web --dry-run` shows the queue without changing anything.

## 6. Start it

```sh
canccu-up --project web
```

This creates the tmux session (`canccu` for the first project) and attaches: window `main` holds
the lead (an interactive `claude`) on the left and the monitor on the right, window `dispatch`
runs the dispatcher, window `shell` is yours. Detach with `Ctrl-b d`; `canccu-up` attaches again.

## 7. A first issue

Write a small issue, alone or with the lead ([`reference/lead.md`](reference/lead.md)):

```markdown
## Goal
The page footer shows the current year instead of a fixed one.

## Acceptance criteria
- [ ] The footer's year comes from the clock.
- [ ] A test fails when the year is hard-coded.

## Out of scope
Any other footer change.

Risk: low — one component and its test
```

Label it `ready`. Within a minute the dispatcher labels it `in-progress` and starts a worker in a
window `#<n>`. Then, with nothing more from you:

1. the worker opens a PR on `<n>-<slug>` and stops once CI is green;
2. a fresh Claude session (`review#<pr>`) reviews it; `review-bot` only posts that review,
   ending in `Review verdict: pass <sha>`;
3. `review-gate` turns green; the dispatcher arms auto-merge and the PR merges, or, under
   `AUTO_MERGE_UNTIL` or on a gated path, it waits for your accept
   (label the PR `accepted`);
4. the dispatcher closes out the issue and removes the worktree.

A review that asks for changes sends the worker back once, then a fix-check. Anything that needs
you shows in the monitor's NEEDS YOU box, and `review-bot` @mentions you on the issue
([`reference/pings.md`](reference/pings.md)). If it stops, [`troubleshooting.md`](troubleshooting.md)
explains each message.

## Next

- Roadmap steps and work packages: [`reference/lead.md`](reference/lead.md),
  [`reference/packages.md`](reference/packages.md).
- Upgrading: [`upgrading.md`](upgrading.md). Every setting: [`reference/config.md`](reference/config.md).
