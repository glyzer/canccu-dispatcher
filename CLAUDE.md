<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# CLAUDE.md

How a session works on this repo. Read `AGENTS.md` first: its rules (comments, file size, PR
body, tests, branch updates) apply to every change. The dispatcher's worker prompt names the
flow below; a session started by hand follows it too.

## The flow: `<n>`, `execute`, `finish`

### `<n>` — take issue n

1. Read the issue with its comments: `gh issue view <n> --comments`. The issue is the agreed
   spec; its acceptance criteria are what the reviewer checks.
2. Read the code the issue touches.
3. Propose a tier, with one line of reasons:
   - **fix**: a small, local change with an obvious shape;
   - **feature**: new behaviour or a change across several files, with a short plan;
   - **plan**: the shape is not obvious, or the change is risky enough that the plan needs the
     product owner's OK first.
4. Create the branch `<n>-<slug>` (the slug: up to four words of the title) from `origin/main`.
   - fix and feature: continue with `execute` (a worker does not wait).
   - plan: write `docs/plans/issue-<n>.md`, open a draft PR, and stop. The product owner labels
     the issue `plan-ok`; the session is resumed and continues with `execute`.

### `execute` — do the work

- Test first: write the failing test, watch it fail, make it pass.
- While working, run only the tests of the files you change: `tests/run <file or pattern>`, or
  `tests/run --affected` for everything changed against `origin/main`. Never paste whole test logs.
- Commit in small steps with clear messages. Never commit secrets, personal paths or names
  (`tests/leak-check.sh` checks).
- To bring in main: `git merge origin/main`. Never rebase or force-push a PR branch.

### `finish` — open the PR

1. Run the local check once, in full: `tests/run`. It must pass.
2. Push the branch and open the PR (or mark the draft ready), with the body `AGENTS.md`
   prescribes.
3. Watch CI (`gh pr checks <pr> --watch`, bounded with `timeout`). Red: fix, rerun the local
   check, push once. Red after two fix rounds: stop and say why.
4. Never merge, never enable auto-merge, never add or remove the `accepted` label: an
   independent reviewer and the product owner take it from here.
5. End with a 5-line report: status, PR URL, what changed, verification, next action.

## The local check

`tests/run` with no arguments runs all of it, in parallel, with a one-line summary per part
(the full log goes to a file it names):

- `bash -n` and `shellcheck -S warning` on every shell file (the test files without `-x` and
  without SC2154, SC2034, SC1010 and SC2319: they read the harness's globals, and following its
  sources would lint the whole lib once per test file);
- every `tests/*.sh`;
- `bin/canccu-monitor --self-test`;
- `tests/leak-check.sh`.

CI (`.github/workflows/ci.yml`) runs the same command twice: job `CI` on the newest runner (then
the release tarball's install smoke test), job `CI (oldstable)` on Debian 12, whose jq 1.6 is slow
enough to need `CANCCU_TEST_TIMEOUT=20m` (each test file's limit; default 8m).
