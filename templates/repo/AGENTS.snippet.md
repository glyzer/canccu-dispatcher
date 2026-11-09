<!-- SPDX-License-Identifier: 0BSD -->
<!--
  canccu-dispatcher's AGENTS.md snippet. Copy everything below this comment into your repo's own
  AGENTS.md (create it if there is none) and adjust the limits and commands to your repo. Keep the
  headings "Comment rule" and "File-size rule" and the PR body lines: the prompts, the health pass
  and the merge classifier rely on them. Merging it is described in canccu-dispatcher's
  docs/repo-contract.md.
-->

## Comment rule

Comment the why: reasons, invariants, traps, what a reader would otherwise get wrong. Never the
what the code already shows. A comment that only restates the next line goes.

## File-size rule

About 400 lines at most per source file. Split a file that grows past it along its seams. Tests,
docs and fixtures are exempt.

## Tests

- Every behaviour change comes with a test that failed before it.
- While working, run only the tests of the files you change; run the full suite once, just before
  pushing. Never paste whole test logs into the conversation.

## Branches

The branch for issue n is `<n>-<slug>`. Branch updates merge main into the branch
(`git merge origin/main`, then a normal push). Never rebase or force-push a PR branch: the
squash-merge flattens it anyway, and a blocked force-push stops a run.

## Issues

An issue has a `## Goal`, `## Acceptance criteria` (checkboxes a reviewer can verify),
`## Out of scope`, and a last line `Risk: low|normal|high — <why>`. The issue is the agreed spec:
work outside it goes in a `Follow-up:` line, never into the PR.

## PR body

In this order:

- one `Closes #<n>` line per issue, and no other issue;
- `Package: <name>` (a work package's name; `-` for a single issue);
- `Risk: low|normal|high — <why>`;
- `Tier: fix|feature|plan`;
- `Decisions made:` the implementation choices the issue left open (names, libraries already in
  the stack, error handling, test shape), one per line; the reviewer checks them;
- `Next action: <what comes next>`;
- `Verification run: <the checks run, with their result>`;
- any `Follow-up: <work outside the issue>` and `Roadmap note: <a change to the plan>` lines.
