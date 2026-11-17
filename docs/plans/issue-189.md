<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Plan for #189: T1 scenario suite against a sandbox repo, gating the tag

> For the session that builds it: run this plan task by task (executing-plans), test first in
> each task, once the issue carries `plan-ok`.

**Goal:** before every tag, `tests/scenarios/run` drives the real `canccu-dispatch --once` against
a real sandbox repo with a fake engine (no model tokens), and `release check` refuses a release
PR body without `Scenarios: pass at <short sha>`.

**Why a plan first:** eight end-to-end flows against live GitHub (rulesets, auto-merge, the merge
queue), a fake engine that must honour the run engine's file contract exactly, and a reset that
moves the sandbox's `main` by force. Two points of the issue do not match the code (Open
questions below), and the issue says to ask rather than improvise.

**No dispatcher behaviour changes.** Only `tests/scenarios/`, `.github/scripts/release`,
`tests/canccu-release.sh` and docs change. `tests/run` does not call the suite (it is not a
`tests/*.sh` file, so the runner never picks it up), and CI never runs it.

## Open questions (for the product owner, before `plan-ok`)

1. **The release-spec template does not exist.** Item 3 of the issue says "The release-spec
   template's acceptance gets the line". Nothing in the repo is a release-spec template:
   `.github/ISSUE_TEMPLATE/` has `bug.md`, `feature.md` and `idea.md`; `docs/plan/issue-template.md`
   is the generic issue template, and the 0.1.4 release (#176, PR #179) was a plain feature
   issue. Proposal: add `.github/ISSUE_TEMPLATE/release.md` (a release issue: bump `VERSION`, date
   the changelog section, and the acceptance line `- [ ] the PR body carries "Scenarios: pass at
   <short sha>" from a run of tests/scenarios/run on the release branch's head`). The other choice
   is a line in `docs/plan/issue-template.md`, which `AGENTS.md` says only a plan issue edits.
2. **Who runs `release check --body`?** Today `release check <tag>` runs in `release.yml` on the
   tag push, where there is no PR body. The issue asks for `--body <file>`. Proposal: the flag is
   optional. `release.yml` stays as it is. A new step in `ci.yml`, run only on a PR whose branch
   or title marks it as a release (`chore(release): v<x>`, the title PR #179 had), writes the PR
   body to a file from `github.event.pull_request.body` (through `env:`, never interpolated into
   the script) and runs `release check v<x> --body <file>`. So a release PR without the line is
   red, and the tag is only ever pushed from a merged release PR. The other choice: make
   `--body` required, and have `release.yml` fetch the body of the PR that merged the tagged
   commit (`gh api repos/{repo}/commits/{sha}/pulls`), which needs `pull-requests: read`.

## Architecture

```
tests/scenarios/run            the entry point: args, the sandbox reset, the loop, the report
tests/scenarios/lib.sh         sandbox helpers: reset, make issues, wait, end-state checks via gh
tests/scenarios/fake-engine    CANCCU_WORKER for the suite: honours canccu-worker's contract
tests/scenarios/<name>.sh      one file per scenario: setup(), script lines, done(), check()
```

Every file stays under 400 lines; each scenario file is a few dozen lines.

**An isolated dispatcher home.** `run` makes a temp `CANCCU_ROOT`/`CANCCU_HOME` holding one
project, `sandbox`, whose `REPO` is `--repo`. Its config sets `INTERVAL` and `CAP=3`, and
`CANCCU_WORKER=tests/scenarios/fake-engine`, so it never touches the host's real projects.
`WORKERS_DIR` and `CODE_ROOT` are under that temp dir too. The gh login is the user's current
one (`GH_CONFIG_DIR` unchanged). `REVIEWER_LOGIN` is the same login, so the posted verdicts count.
The temp dir is removed at the end unless `--keep`.

**The fake engine** (`tests/scenarios/fake-engine`) takes canccu-worker's arguments as
`docs/reference/engine.md` lists them (`--key --dir --name --model --effort --untrusted
--keep-session --fresh --quiet <repo> "<prompt>" turns= cost= min=`, plus `--unlock` and
`--kill`). It sources `lib/canccu-engine.sh` for `lock_path` and the lock format, so a lock it
writes is one the dispatcher reads as alive. Like the real engine, it returns at once. A
`setsid` child holds the lock (its pid and `pstart`), plays the role, writes `.last` in
`report()`'s exact format (one shared helper copied from `libexec/canccu-worker:report`, tested
against it, see Task 1), adds a `spend.log` line with cost `0`, and drops the lock.

The role comes from the key: a number or a package key → **worker** (first run, resume, fix run
or merge run, told apart by the prompt's known phrases); `review-<pr>` → **reviewer** or
**fix-check** (by the prompt). What each role does comes from the scenario's script,
`$SCENARIO_DIR/script`, lines `<role> <round> <action>`, for example `worker 1 crash`,
`worker 2 pr` or `reviewer 1 pass`. Actions:

- worker `pr`: commit `scenario/<n>.txt` in the worktree, push the branch, `gh pr create` with
  the body `AGENTS.md` prescribes (`Closes #<n>` lines, `Package:`, `Risk:`, `Tier:`…), exit `done`;
- worker `contract`: as `pr`, but from `<branch>-contract` with `Refs #<n>`, and the unit's own PR
  as a draft;
- worker `fix`: one more commit on the PR's branch, push, `done`;
- worker `push-denied`: commit, do not push, and end `done` with the message block
  `Permission denials (information):` / `Bash git push origin <branch>`, the way
  `lib/canccu-stream.py` reports a denial;
- worker `crash`: end `crashed (exit 1)`;
- reviewer and fix-check `pass` / `changes`: write `reviews/<pr>/<sha>.md` with a `Blocking:`
  section (one finding for `changes`) and the last line `Review verdict: <word> <full head sha>`.

Every action is logged to `$SCENARIO_DIR/engine.log`, which a check may read and a FAIL quotes.

**The loop.** For each scenario: reset, `setup`, then `canccu-dispatch --once` every 20 s until
`done` holds or 15 minutes pass (`SCENARIO_TIMEOUT_MIN`), then `check`. It prints `<name>: pass`
or `<name>: FAIL <why>` (the why: the first failed expectation and the last `log` line). It exits
1 on any FAIL, and 2 on a usage error or a sandbox that is not set up (preflight below).

**The reset.** Close every open PR (deleting its branch) and every open issue labelled
`scenario`, then set `main` to the tag `scenario-base` (`git push --force origin
scenario-base^{commit}:main` from a temp clone). Branch protection on the sandbox's `main` must
let the login bypass it for that one push; `docs/reference/scenarios.md` says so. This is the
only force-push anywhere, and it goes to the sandbox, never to a PR branch. Preflight refuses
to run when `--repo` is this repo (`gh repo view --json nameWithOwner` of the checkout's
origin), when the tag is missing, or when the login cannot push. A guard against hitting the
wrong repo.

## Scenarios: setup → end state checked with `gh`

| name | setup and script | end state |
| --- | --- | --- |
| `single` | 1 issue `ready`; worker `pr`, reviewer `pass` | its PR merged, the issue closed |
| `package` | 3 issues of one package (the planner's label/step as `docs/reference/packages.md` says); one `pr` closing all three | one PR merged, all 3 issues closed |
| `contract-first` | 1 issue; worker `contract`, then `pr` on resume | the contract PR merged before the unit's PR (`mergedAt` order), both merged |
| `conflict-waiting` | 1 issue whose risk makes it manual (a `Maintainer accept:` line in the review); after the pass, the suite pushes a conflicting commit to `main` | the dispatcher's merge-by-script commit on the PR (a merge of main, no worker run in `engine.log` after the pass), the PR still waiting for accept; the suite then accepts and it merges |
| `queue-removal` | the sandbox's merge queue with a required check the suite can fail once (a status the suite sets with `gh api statuses`, run only for this scenario) | the PR is removed from the queue once, re-queued by the dispatcher, merged |
| `push-after-pass` | worker `pr`, reviewer `pass`; before the merge, the suite pushes a non-merge commit (auto-merge disabled for this repo variable) | `engine.log` has a fix-check for `<passed sha>..<head>`, then the merge |
| `denied-push` | worker `push-denied` | the issue labelled `needs-you`, its comment naming `git push` (`denied_ok` in `lib/canccu-exits.sh`) |
| `crash` | worker `crash`, `crash` | two runs in `engine.log` (the second `--fresh`), the issue `needs-you` naming the crash |

Each row is one scenario file. Where a row needs a repo setting (`queue-removal`'s merge queue,
`conflict-waiting`'s manual path), the file sets and restores it in `setup`/`teardown`, or the doc
lists it as part of the sandbox's standing setup. The build decides which, scenario by scenario,
and writes it under `Decisions made:`.

## Tasks

### Task 1: the fake engine and its contract test

- Files: `tests/scenarios/fake-engine`, `tests/canccu-scenarios.sh` (a unit test: it runs with
  `tests/run`, against the harness's fake gh, never GitHub).
- Test first: the fake engine's `.last` parses with `run_exit` (`lib/canccu-answer.sh`) to
  `done|done`, `crashed|crashed (exit 1)`, and denials `run_msg` that `denied_ok` reads. Its
  lock is `lock_alive` while the child runs and gone after. `--unlock` and `--kill` behave like
  the real engine's. One `report` line from the fake and one from `libexec/canccu-worker:report`,
  for the same inputs, are byte-identical (so a format change in the real engine breaks this test).
- Then the fake engine.

### Task 2: `run`, `lib.sh`, preflight, reset and the loop, dry-run

- Test first in `tests/canccu-scenarios.sh`: `run --repo example-org/web` with the harness's fake
  `gh`, a scenario `noop` (tests only) whose `done` holds after one pass: prints `noop: pass`,
  exit 0. One whose `check` fails: `noop-bad: FAIL <why>`, exit 1. Preflight: no `--repo` → 2;
  `--repo` equal to the checkout's origin → 2, saying so; no `scenario-base` tag → 2. The reset
  calls `gh pr close`, `gh issue close` and the force-push of the tag in that order (the fake
  gh's routes log).
- Then `run` and `lib.sh`.

### Task 3: the eight scenarios

- One file each, in the order of the table. Each gets its dry run in `tests/canccu-scenarios.sh`,
  where the fake gh plays GitHub's side (the issue's acceptance: "a dry run with `--repo` set to a
  fake-gh repo"). Each is then run once against the real sandbox by the builder, with the result
  in the PR's `Verification run:`.
- `tests/run` must not call the suite against GitHub: a test asserts that `tests/run --list` names
  no `tests/scenarios/` file.

### Task 4: the release gate

- Test first in `tests/canccu-release.sh`: `release check v1.2.3 --body <file>` with a body that
  lacks the line → exit 1 and exactly `release: the release PR body has no "Scenarios: pass at
  <sha>" line`. With `Scenarios: pass at 1a2b3c4` → ok. `--body` naming a missing file → 2. A
  line whose sha is not 7–40 hex → fails like a missing one. Without `--body`, as today
  (depending on question 2).
- Then `.github/scripts/release check`. Its header comment gets the flag. If question 2 goes the
  proposed way, add the `ci.yml` step for a release PR and its test in `tests/canccu-ci.sh`.
- The release-spec template's acceptance line, per question 1.

### Task 5: docs

- New `docs/reference/scenarios.md`: the sandbox's setup (a repo of the login's own, its
  `main` ruleset with the login allowed to bypass for the reset, `review-gate` as the required
  check, auto-merge on, the merge queue, the labels the dispatcher needs, the tag `scenario-base`
  on a commit holding `AGENTS.md`/`CLAUDE.md` snippets from `templates/repo/`), the login
  (write access to the sandbox only; a fine-grained token is enough), how to run it
  (`tests/scenarios/run --repo <owner/sandbox> [scenario...]`, `--keep`, the timeout), what a FAIL
  prints, and the release gate.
- A row in `docs/reference/README.md`; `docs/reference/commands.md` if `tests/canccu-docs.sh`
  wants the command there. The changelog's `Unreleased` gets one line.

## Risks

- **GitHub's timing.** The merge queue and auto-merge take minutes. The 15-minute limit and a
  20 s pass interval keep the suite to well under two hours for all eight. A flaky scenario
  shows as a FAIL with the last log line, never as a silent pass.
- **The force-reset of the sandbox's `main`.** Guarded by preflight (never this repo, the tag
  must exist), and documented as the reason the login must be the sandbox's only writer.
- **The fake engine drifting from the real one.** Task 1's byte-identical `report` test, and the
  lock helpers sourced, not copied.
