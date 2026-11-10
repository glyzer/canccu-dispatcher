<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Templates for a target repo

`templates/repo/` holds the files a repo that canccu-dispatcher works on adds through a PR, at
the same paths under its root. They are 0BSD (`templates/LICENSE`): copy them freely. This repo
runs the same files: `tests/canccu-ci.sh` fails when its copies differ.

## The review gate

- `.github/workflows/review-gate.yml`: the workflow. Its job `review-gate` is the check a
  ruleset requires (the default of `REVIEW_CHECKS`); do not rename it.
- `.github/scripts/review-gate`: the gate. `review-gate --self-test` runs its offline tests; the
  workflow runs them first on every PR.

The gate passes only when the newest comment by the reviewer identity that holds
`Review verdict:` ends in exactly `Review verdict: pass <full head sha>` for the PR's current
head, was never edited, and the base branch has not changed since. That is the line
canccu-dispatcher's reviewer writes last (`changes` instead of `pass` fails the gate). Comments
by anyone else are ignored, and comment text is matched, never run.

Setup, by a maintainer (`canccu-init` prints these steps in its checklist):

1. Set the repo variable `REVIEWER_LOGIN` to the reviewer account's login (Settings → Secrets
   and variables → Actions → Variables). Unset, the gate fails every PR.
2. Add both files through a PR.
3. Require the checks `CI` and `review-gate` in a ruleset on the default branch.

The workflow token only reads, except `actions: write` in the job that re-runs the gate when the
reviewer posts a verdict. That job re-runs every gate run of the PR's head, one at a time: a push
and a body edit each start one, and either one left red keeps the PR out of the merge queue. Every action is pinned by its commit SHA; Dependabot updates them.

## The CLAUDE.md and AGENTS.md snippets

- `CLAUDE.snippet.md`: the `<n>` / `execute` / `finish` flow the worker prompt names.
- `AGENTS.snippet.md`: the comment and file-size rules the health pass checks, and the PR body
  lines the reviewer and the classifier read.

They are named `*.snippet.md`, never `CLAUDE.md` or `AGENTS.md`, so no session in this repo loads
them as instructions. A target repo merges them into its own `CLAUDE.md` and `AGENTS.md`:
`docs/repo-contract.md` says how.
