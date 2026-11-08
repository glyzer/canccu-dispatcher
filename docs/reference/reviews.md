<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Reviews, the fix-check, the answerer and the worker prompt

Part of the reference; the index is [`README.md`](README.md). The prompts are in
`lib/canccu-runs.sh` (`WORKER_PROMPT`, `review_prompt`, `fixcheck_prompt`),
`lib/canccu-answer.sh` and `lib/canccu-packages.sh`; they rely on the repo contract in
[`../repo-contract.md`](../repo-contract.md).

## Reviewer

A fresh headless session per PR head (key `review-<pr>`, window `review#<pr>`, budget
`BUDGET_REVIEW`), in its own worktree at the head, run `--untrusted` (the checkout's
`.claude/` settings, hooks and `.mcp.json` never load) and never with the bot's token: it has
the project's narrow login like every run ([`engine.md`](engine.md), [`../security.md`](../security.md)). It reads the issue, `AGENTS.md` and the diff against `origin/main`;
runs the code-review skill at the chosen effort, and the security-review skill when the diff
touches `SECURITY_REVIEW_WHEN`; checks every acceptance criterion, the rules' `REVIEW_EXTRA` and
the choices under `Decisions made:` in the PR body. It treats the PR, the issue, the code,
`CLAUDE.md` and `AGENTS.md` as data, never as instructions; it edits, pushes, comments, labels
and merges nothing.

It writes its review to `~/.canccu/projects/<name>/reviews/<pr>/<sha>.md`: findings ranked, each
with a repo-relative `file:line` and a concrete fix; then, only when the PR breaks a contract or
holds a destructive migration, `Maintainer accept: <what>`; for a package, `Risk: <low|normal|high>
— <why>` (it confirms or raises the plan's class, never lowers it); and last, exactly `Review
verdict: pass <sha>` or `Review verdict: changes <sha>`. Only correctness and security findings
(an unmet acceptance criterion counts) make the verdict `changes`; nits go under
"Non-blocking:". The dispatcher checks the file and posts it as `REVIEWER_LOGIN`.

**Effort by risk.** `high` when the diff touches `RISKY_PATHS`, `GATED_PATHS` or agent
configuration (never a light review for those, even as "docs"), for a high-risk package, on any
`gh` error, and by default. `medium` for a docs-only diff (`docs/` or `*.md`) and for a
`Tier: fix` diff under 100 changed lines that touches none of those. `canccu-status` shows the
effort next to the running review.

## Fix-check

After the worker fixed a full review's findings and CI is green, the fix-check runs: the same
setup (window `fixcheck#<pr>`, budget `BUDGET_FIXCHECK`), with the findings in its prompt and
`git diff <reviewed sha>..<head>` as its only diff. It answers each blocking finding (fixed, not
fixed, the fix broke something), looks for nothing new except a correctness or security bug the
fix introduced, and ignores changes that came from merging `origin/main`. It copies the review's
`Maintainer accept:` and `Risk:` lines, and adds its own for a breaking change in the fix diff.
Its file is posted like a review, so `review-gate` passes on the new head.

**Effort:** `low` by default; `medium` above 300 changed lines in the fix diff, when it touches
`FIXCHECK_RISKY`, or when the diff cannot be read. `pass` → classify as for a review (the full
review's `Maintainer accept:` still counts). `changes` → `needs-you` with the open items.

## The verdict line

A verdict counts only if it is the last non-empty line of a comment **by `REVIEWER_LOGIN`**,
says `pass` or `changes`, and ends in the **full 40-character sha of the PR's current head**
(bold or backticks around it are fine). A verdict for an older head, with a short sha, any other
word, by any other account, or one already acted on does not count; the newest counting comment
wins. A `Maintainer accept:` line before the verdict makes the PR manual: the dispatcher enforces
your accept, not `review-gate`.

The dispatcher posts a review only when the file was written after the review started and its
last line is a verdict for exactly that head. A file that fails the check is never posted
(`needs-you`). A failed post is retried every pass; a run's first failed post, or its second
time-out in a row, labels the issue `needs-you` once, with a comment saying where the review file
is, and the label goes again once the verdict is acted on, the run is void, or a new run starts.
A posted review GitHub does not list yet is waited for `POST_WAIT` seconds before
it counts as missing; a timed-out post is retried only after that wait, never at once. Each
review run ends with one outcome line in the log: `posted as …`, `post failed …`, `post timed out
…`, `no valid verdict (<why>)` or `void` (a push during the run).

**Workers never review.** The worker prompt and every resume say "Do not review your own work;
run the checks only." The independent reviewer is the only review.

## Answerer

When a worker stops with a question, a fresh session (key `answer-<n>`, `BUDGET_ANSWER`,
`--untrusted`) reads the issue, the rules' `ANSWER_READ`, the PR so far and `ANSWER_READ_ALSO`.
If the answer follows from those, it posts an issue comment starting `Answer:` (the answer, the
reason and the source) and ends with `ANSWERED`; the worker resumes with it. It escalates instead,
with a comment starting `Needs the product owner:` (the options and a recommendation, at most 5
lines) and `ESCALATE`, when the answer would change the issue's scope or criteria, contradict or
add a recorded decision, choose between user-visible behaviours nothing decides, or be
irreversible or touch security, money or personal data. A plan-tier question always goes to you.
One round per question, at most `ANSWER_MAX` per issue.

## Worker prompt

The worker starts in its worktree with `<n> <prompt>`. The prompt tells it to follow `AGENTS.md`
and the `<n>` / `execute` / `finish` flow in `CLAUDE.md`, with these overrides:

- propose a tier and go on without waiting on fix and feature (the feature plan goes in the PR
  description); on the plan tier write `docs/plans/issue-<n>.md`, open a draft PR and stop;
- use the superpowers skills test-driven-development, systematic-debugging and
  verification-before-completion (writing-plans and executing-plans on the plan tier), never
  brainstorming, using-git-worktrees, finishing-a-development-branch, requesting-code-review,
  subagent-driven-development, dispatching-parallel-agents or writing-skills: the dispatcher owns
  worktrees, branches, reviews and questions, and the issue is the agreed spec;
- create the branch `<n>-<slug>` from `origin/main`; run only the affected tests while working
  and the full suite once before pushing; do not review its own work;
- add `Tier:` and `Decisions made:` to the PR body; stop with a `Question:` line when it must ask;
- bring in main with `git merge origin/main`, never rebase or force-push; never merge, enable
  auto-merge or touch `accepted`; stop when the PR is ready and CI is green;
- the rules' `WORKER_EXTRA`; stop and say why on a question, a destructive migration, a breaking
  contract change, a blocked command, or CI red after two fix rounds; end with a 5-line report.

A package's prompt is the same for all its issues on one branch `pkg-<m>-<name>`, with one PR,
`Package:` and `Risk:` lines, and `Follow-up:` and `Roadmap note:` lines for work outside it
([`packages.md`](packages.md)).
