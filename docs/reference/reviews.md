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

It writes its review to `~/.canccu/projects/<name>/reviews/<pr>/<sha>.md`: the blocking
findings under "Blocking:", ranked, each with a repo-relative `file:line` and a concrete fix;
then, only when the PR breaks a contract or holds a destructive migration, `Maintainer accept:
<what>`; for a package, `Risk: <low|normal|high> — <why>` (it confirms or raises the plan's
class, never lowers it); and last, exactly `Review verdict: pass <sha>` or `Review verdict:
changes <sha>`. Only correctness and security findings (an unmet acceptance criterion counts) make
the verdict `changes`; nits go under "Non-blocking:". The dispatcher checks the file and posts
it as `REVIEWER_LOGIN`.

**Non-blocking findings go to a follow-up issue.** From every verdict comment (a review's or a
fix-check's, `pass` or `changes`, once per verdict) the dispatcher takes the items under
"Non-blocking:" and files them in one open issue per wave: `Follow-ups: non-blocking review
findings, step <title>, wave <w>` for a package, `…, health pass` for the health pass, and
`… (fast lane)` for every other issue. The first findings make the issue (not labelled `ready`:
you decide), later ones are comments on it while it is open; a closed one makes a new issue.
A PR that closes the follow-up issue files its own findings in a new one. The
fix run of a `changes` verdict gets only the blocking findings, and the fix-check checks only
those. They are saved to `reviews/<pr>/<head>.findings.md` before the fix run starts; its prompt
names that file and inlines at most their first 3,000 characters, so a long list is read there. A `gh` error is logged and blocks nothing: the items stay in the PR comment.
`canccu-status --findings` lists the most common findings and the files cited most, across the
review records (`FINDINGS_TOP` lines at most, 15 by default).

**Effort by risk.** Always `high` when the diff touches `GATED_PATHS` or agent configuration
(never a light review for those, even as "docs"), and on any `gh` error. Then:

- **A PR with a risk class** (a package's effective class, as for its merge: the highest of the
  plan's, the PR's `Risk:` line and the reviewer's; the health pass is `high` when it touches
  `HIGH_RISK_PATHS`, else `normal`): `high` → `high`; `low` or `normal` → `medium`, whatever
  paths it touches.
- **A PR without one** (a single issue): `high` when the diff touches `RISKY_PATHS`; `medium`
  for a docs-only diff and for a `Tier: fix` diff under 100 changed lines that touches none of
  those; `high` otherwise. Docs are `docs/`, `*.md` and the rules' `EFFORT_DOCS_PATHS`, which
  count as docs even when `RISKY_PATHS` names them; their lines do not count toward the 100
  either. An `EFFORT_DOCS_PATHS` that is not a valid regex makes every review `high` (with a
  warning in the log).

`REVIEW_EFFORT_MAX` (`low`, `medium` or `high`) then caps the effort of every full review and
fix-check on the machine, with no exceptions: gated paths, agent configuration, a diff that could
not be read and a package of risk `high` are capped too. It never raises an effort, and who must
accept a gated PR does not change. A capped review's `reviews/<pr>.effort` reads `medium (capped)`.

**Model by kind.** A full review runs on `REVIEW_MODEL`, a fix-check on `FIXCHECK_MODEL`; each
is `MODEL` when empty. A project that runs fix-checks on a cheaper model (`claude-sonnet-5-5`)
and leaves `REVIEW_MODEL` empty keeps every full review, a high-risk PR's too, on `MODEL`. The
log line of the start names the effort and the model, and `canccu-status` shows both next to the
running review: `review PR #50 (medium · claude-opus-5-5)` (the effort alone when no model is
set).

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
review's `Maintainer accept:` still counts). `changes` → `needs-you` with the open items, saved
as `reviews/<pr>/<head>.open.md`, the head kept as `open_sha`; its own `Maintainer accept:` and
`Risk:` lines are kept with the full review's, so a later pass that does not copy them still
waits for you.

**Your `needs-work` on those open items** (still in the fix round, not after a stopped merge) is
one more fix round: the worker follows up (a fresh session unless `RESUME_ON` names `needs-work`) with the open items and your comments, the findings file
`reviews/<pr>/<open_sha>.findings.md` is rebuilt from both (never appended to; a pointer to the
fix-check's PR comment when the items were not saved), then a fix-check of `<open_sha>..<new
head>` runs against them; each of your comments counts as a blocking item. A line in your
comment that is just `full review` (any case; `*`, `_`, backticks and a final `.` or `!`
allowed) asks for a new full review instead, as does a `needs-work` on a refused accept.

## The verdict line

A verdict counts only if it is the last non-empty line of a comment **by `REVIEWER_LOGIN`**,
says `pass` or `changes`, and ends in the **full 40-character sha of the PR's current head**
(bold or backticks around it are fine). A verdict for an older head, with a short sha, any other
word, by any other account, or one already acted on does not count; the newest counting comment
wins. A `Maintainer accept:` line before the verdict makes the PR manual: the dispatcher enforces
your accept, not `review-gate`.

The dispatcher posts a review only when the file was written after the review started and its
last line is a verdict for exactly that head. A file that fails the check is never posted. A
run that ended `done` without one (no file, an old one, or no verdict for the head) is asked once
per head, in its own session (`--keep-session`, 10 turns, 2 USD, 10 minutes), to write the file
from the review it already did; the log says `asked once to write the review file`. A retry that
leaves no valid file either, or a run that ended any other way, goes to `needs-you`. Backing off
or no free slot: the retry waits for the next pass. A failed post is retried every pass; a run's first failed post, or its second
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
- create the branch `<n>-<slug>` from `origin/main`; run only the tests of the changed files,
  in the foreground, never the full suite locally (CI runs it); run nothing in the background
  (a headless run ends with its turn); commit and push early (after the tests-first commit and
  when the tests pass); do not review its own work;
- add `Tier:` and `Decisions made:` to the PR body; stop with a `Question:` line when it must ask;
- bring in main with `git merge origin/main`, never rebase or force-push; never merge, enable
  auto-merge or touch `accepted`; stop as soon as the PR is open and ready, without waiting for
  CI: the dispatcher watches it and starts the fix session on red (`FIX_ATTEMPTS`);
- the rules' `WORKER_EXTRA`; stop and say why on a question, a destructive migration, a breaking
  contract change or a blocked command; end with a 5-line report.

A package's prompt is the same for all its issues on one branch `pkg-<m>-<name>`, with one PR,
`Package:` and `Risk:` lines, and `Follow-up:` and `Roadmap note:` lines for work outside it
([`packages.md`](packages.md)).
