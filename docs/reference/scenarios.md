<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Scenario suite

`tests/scenarios/run` drives the real `canccu-dispatch --once` against a real sandbox repo. A
fake engine (`tests/scenarios/fake-engine`) plays the worker, reviewer, fix-check and planner,
so a run costs no model tokens. It gates every release tag ([`release.md`](release.md)). Neither
`tests/run` nor CI runs it. Its unit tests and the dry run of each scenario are in
`tests/canccu-scenarios.sh`, which `tests/run` runs against the harness's fake `gh`.

## The sandbox

The suite resets the sandbox before each scenario: it closes every open PR (and deletes its
branch), every open issue labelled `scenario` and every open dispatcher claim (each scenario's
home is a host of its own, and an earlier one's fresh claim would stop the next), then
**force-pushes `main` back to the tag `scenario-base`**. Use a repo that holds nothing else and has no other writers. The standing
setup:

- a repo owned by the login that runs the suite;
- a ruleset on `main` that requires the check `review-gate`, with the login allowed to bypass
  it (the reset's force-push needs that);
- auto-merge allowed, and a merge queue on `main` (`queue-removal` uses it);
- a required CI check that takes a minute or more (`push-after-pass` pushes before the merge);
- the labels the dispatcher uses (it creates the missing ones); preflight creates `scenario`
  when it is missing;
- the tag `scenario-base` on a commit that holds the `AGENTS.md` and `CLAUDE.md` snippets from
  `templates/repo/`.

The login needs write access to the sandbox and nothing else: a fine-grained token limited to
that repo is enough. The reviewer's verdicts are posted as the same login.

Preflight refuses to start, with exit 2, when `--repo` is this repo itself, when the login cannot
push to it, when the tag `scenario-base` is missing, or when it cannot create the label
`scenario`.

## Running it

```sh
tests/scenarios/run --repo <owner/sandbox> [--keep] [scenario...]
```

- No scenario named: all nine, in order: `single`, `package`, `contract-first`,
  `conflict-waiting`, `queue-removal`, `push-after-pass`, `denied-push`, `denied-pr`, `crash`.
- Each scenario gets its own temp dispatcher home (`CANCCU_ROOT`, project `sandbox`, `CAP=3`), so
  the host's real projects are never touched. Its project runs as the login that runs the
  suite: its config sets `ALLOW_DEFAULT_GH_LOGIN=1` rather than a `GH_CONFIG_DIR`, since that
  login may live in a keyring, with no config dir to point at. `--keep` keeps the temp dir and prints its path.
- One `canccu-dispatch --once` pass every `SCENARIO_PASS_SEC` (default 20) seconds, until the end
  state holds or `SCENARIO_TIMEOUT_MIN` (default 15) minutes pass.
- Exit 0 when all pass, 1 when one fails, 2 on a usage error or a sandbox that is not set up.

| Scenario | What happens | End state checked with `gh` |
|---|---|---|
| `single` | one issue; the worker opens a PR, the review passes | the PR merged, the issue closed |
| `package` | three issues of one step; the planner bundles them | one merged PR closes all three |
| `contract-first` | the worker opens a contract PR and its own as a draft | the contract PR merged first, then the unit's |
| `conflict-waiting` | the PR waits for an accept; main moves under it | a merge of main on the PR, then merged after the accept |
| `queue-removal` | the merge queue drops the PR once | queued again by the dispatcher, merged |
| `push-after-pass` | a push lands on the PR after the review passed | a fix-check ran, then the merge |
| `denied-push` | the worker's `git push` is denied | the issue `needs-you`, naming `git push` |
| `denied-pr` | the worker pushed, but its `gh pr create` is denied | the dispatcher opens the PR from the worker's body file (the body says so); it merges and the issue closes |
| `crash` | the worker crashes twice | one fresh retry, then `needs-you` |

## The fake engine

It takes `libexec/canccu-worker`'s arguments ([`engine.md`](engine.md)), takes the lock with
the real engine's helpers (`lib/canccu-engine.sh`), and writes `.last` in the layout of
canccu-worker's `report()` (`tests/canccu-scenarios.sh` checks the two are byte-identical). What
each run does comes from the scenario's `script`, lines `<role> <round> <action>`; every run
adds `<role> <round> <key> <action>` to the scenario's `engine.log`.

## What a FAIL prints

`<scenario>: FAIL <why> (last log: <the last dispatch.log line>)`. The why is the first end-state
check that failed, `needs-you: …` when the scenario does not expect a `needs-you`, or
`timed out after <n> s: …`. A setup that fails prints `<scenario>: FAIL setup: <command> failed
(exit <n>): <the last line it printed on stderr>`. With `--keep`, the scenario's `engine.log`, `dispatch.out` and the
dispatcher home stay for a look.

## The release gate

A passing run on the release branch's head gives the release PR's body line
`Scenarios: pass at <short sha>`. CI checks it on every PR that changes `VERSION`
(`.github/scripts/release check v<VERSION> --body <file>`): without the line, the PR is red.
