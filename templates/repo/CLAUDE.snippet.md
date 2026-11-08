<!-- SPDX-License-Identifier: 0BSD -->
<!--
  canccu-dispatcher's CLAUDE.md snippet. Copy everything below this comment into your repo's own
  CLAUDE.md (create it if there is none), then replace each <…> with your repo's commands. Keep
  the headings `<n>`, `execute` and `finish`: the worker prompt names this flow by them. Merging it
  is described in canccu-dispatcher's docs/repo-contract.md.
-->

## How a session works on this repo

Read `AGENTS.md` first: its rules apply to every change. canccu-dispatcher's worker prompt names
the flow below and adds its own overrides; a session started by hand follows it too.

### `<n>`

Take issue n.

1. Read the issue with its comments: `gh issue view <n> --comments`. The issue is the agreed
   spec; its acceptance criteria are what the reviewer checks.
2. Read the code the issue touches.
3. Propose a tier, with one line of reasons:
   - **fix**: a small, local change with an obvious shape;
   - **feature**: new behaviour or a change across several files, with a short plan (it goes in
     the PR description);
   - **plan**: the shape is not obvious, or the change is risky enough that the plan needs the
     maintainer's OK first.
4. Create the branch `<n>-<slug>` (the slug: up to four words of the title) from `origin/main`.
   - fix and feature: continue with `execute`.
   - plan: write `docs/plans/issue-<n>.md`, open a draft PR with a `Tier: plan` line, and stop.
     The maintainer labels the issue `plan-ok`; the session is resumed and continues with
     `execute`.

If you cannot go on without an answer, write the question on its own line starting
`Question:` and stop. Do not guess at scope, product behaviour or anything irreversible.

### `execute`

Do the work.

- Test first: write the failing test, watch it fail, make it pass.
- While working, run only the tests of the files you change: `<the command for one test file>`.
  Never paste whole test logs.
- Commit in small steps with clear messages. Never commit secrets or personal paths.
- To bring in main: `git merge origin/main`. Never rebase or force-push a PR branch.

### `finish`

Open the PR.

1. Run the full local check once: `<the full test command>`. It must pass.
2. Push the branch and open the PR (or mark the draft ready), with the body `AGENTS.md`
   prescribes.
3. Watch CI. Red: fix, rerun the local check, push once. Red after two fix rounds: stop and say
   why.
4. Never merge, never enable auto-merge, never add or remove the `accepted` label: an independent
   reviewer and the maintainer take it from here. Do not review your own work.
5. End with a 5-line report: status, PR URL, what changed, verification, next action.
