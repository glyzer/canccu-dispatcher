<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The repo contract: what a target repo needs

A repo canccu-dispatcher works on needs a few things on its GitHub side and two short sections in
its own `CLAUDE.md` and `AGENTS.md`. Everything to copy is in `templates/repo/`, under the 0BSD
licence (`templates/LICENSE`): copy it freely, it does not bring the AGPL into your repo.
`canccu-init` prints the GitHub steps as a checklist ([`reference/projects.md`](reference/projects.md)).

## On GitHub

1. **The reviewer bot.** Add the second account (`REVIEWER_LOGIN`) as a collaborator with write
   access (Settings → Collaborators); sign in as the bot and accept the invitation. The bot only
   comments (reviews and pings): the dispatcher never pushes, labels or merges as it. For a
   private repo, its token needs access to the repo.
2. **The repo variable `REVIEWER_LOGIN`** (Settings → Secrets and variables → Actions →
   Variables), set to the bot's login. The gate reads it; unset, the gate fails every PR.
3. **A CI check** that runs on every pull request, and on `merge_group` if you use a merge queue.
   The dispatcher waits for green CI before it reviews, and a PR with no check is never green: it
   goes to `needs-you` after `NO_CHECKS_MIN`. A path filter that skips CI for some PRs has the
   same effect for them.
4. **The review gate**: add `.github/workflows/review-gate.yml` and
   `.github/scripts/review-gate` from `templates/repo/` at the same paths, through a PR (below).
5. **A ruleset** on the default branch (Settings → Rules → Rulesets) that requires the status
   checks `CI` (your CI job's name) and `review-gate`. A merge queue is optional; with one, both
   checks must also run on `merge_group`, which the gate does. Allow auto-merge (Settings →
   General) if your plan offers it; without it the dispatcher merges directly, under the same pins.

`canccu-init` creates the dispatcher's labels ([`reference/commands.md`](reference/commands.md));
it never changes rulesets, secrets, variables or collaborators.

## The review gate

[`templates/repo/.github/workflows/review-gate.yml`](../templates/repo/.github/workflows/review-gate.yml)
runs [`templates/repo/.github/scripts/review-gate`](../templates/repo/.github/scripts/review-gate)
on every PR event and every PR comment. Its job `review-gate` is the required check (the default of
the rules' `REVIEW_CHECKS`): do not rename it.

The gate passes only when the newest comment by `REVIEWER_LOGIN` that holds `Review verdict:` ends
in exactly `Review verdict: pass <full head sha>` for the PR's current head, was never edited, and
the base branch has not changed since. `changes` fails it. Comments by anyone else are ignored,
and comment text is matched, never run. A verdict comment re-runs the gate. The workflow token
only reads, except `actions: write` in the job that re-runs it; every action is pinned by its
commit sha. `review-gate --self-test` runs the gate's offline tests, and the workflow runs them
first. [`templates/README.md`](../templates/README.md) is the gate's contract; this tool's own
repo runs the same files.

## In `CLAUDE.md` and `AGENTS.md`

The worker prompt tells each worker to "follow AGENTS.md and the `<n>` / `execute` / `finish`
flow in CLAUDE.md", the reviewer reads `AGENTS.md`, the health pass checks its comment and
file-size rules, and the classifier reads the PR body's lines. Two snippets hold exactly that:

- [`templates/repo/CLAUDE.snippet.md`](../templates/repo/CLAUDE.snippet.md): the `<n>` /
  `execute` / `finish` flow: tiers, the branch name, the plan file `docs/plans/issue-<n>.md`, the
  `Question:` line, test first, merging main, the PR and the 5-line report;
- [`templates/repo/AGENTS.snippet.md`](../templates/repo/AGENTS.snippet.md): the comment rule, the
  file-size rule, tests, branches, how issues are written, and the PR body (`Closes`, `Package:`,
  `Risk:`, `Tier:`, `Decisions made:`, `Follow-up:`, `Roadmap note:`).

They are named `*.snippet.md`, not `CLAUDE.md` or `AGENTS.md`, so that no Claude session in this
tool's repo loads them as its own instructions.

**To merge them into a target repo:**

1. Copy the text below the snippet's opening comment, not the comment or its SPDX line.
2. Without a `CLAUDE.md` (or `AGENTS.md`), make it from the snippet alone. With one, add the
   snippet's sections to it; where your file already says the same thing (a comment rule, a PR
   template), keep one version, and keep the snippet's headings and line names, which the prompts
   and the classifier look for.
3. Replace each `<…>` with your repo's commands (one test file, the full check).
4. Adjust the file-size limit and the issue format if your repo has its own; keep the PR body
   lines as they are.
5. Add both files through a PR. A PR that changes `CLAUDE.md` or `AGENTS.md` always waits for your
   accept, so the dispatcher cannot merge a change to its own instructions by itself.

A `.github/pull_request_template.md` with the PR body lines helps people opening PRs by hand.
