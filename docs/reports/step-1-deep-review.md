<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Step 1 Reference hosts: deep review

This review covers the step's merged PRs #77 (#52, #25, #63, #23) and #95 (#67). It reads them
against origin/main at 9a3e02c3c1a1ee775a733bb7cc1e079a94fb185f. Much of the code has moved since
the merge (lib/canccu-mqueue.sh, lib/canccu-exits.sh and lib/canccu-prbody.sh were split out
later), so each finding cites the line where that code is now. Follow-up #97 is not repeated.
The non-blocking items from the review of #77 were never filed as a follow-up. The ones still
true at the head are listed below.

## Architecture

- **Three special PR kinds.** #63 adds the contract-first PR, next to the plan PR and the normal
  PR. It is recognised only by its branch (`is_contract_pr`: `<unit branch>-contract`), and that
  check now appears in five places: `pr_for`, `classify`, `review_prompt`, the body checks of
  lib/canccu-prbody.sh, and `pr_gone` → `contract_back`. The cases agree with each other: a
  contract PR closes nothing (or goes to manual), `pr_for` prefers it while it is open, and its
  merge brings the unit back to `check` on its own PR. `pr_for` now has three near-identical
  "newest open, not foreign" loops (lib/canccu-github.sh:86).
- **#25 (blocked but finished).** `reap_worker` turns a `blocked` exit that has an open PR into
  `done` (lib/canccu-pipeline.sh:27). After that it takes the same path as any done run,
  including the later `denied_ok` check of the denied commands. So a run that is really blocked
  but has a draft PR still ends in needs-you, through `check_pr`. `ready_unpark`
  (lib/canccu-pipeline.sh:281) is called only after `merge_unpark` and `ci_unpark`, and only for
  `ny_stage` `work` or `ci`. It does not affect the needs-you of a review or a merge.
- **#23 (the stuck gate and queue).** The fix is split between the repo's workflow (re-run every
  gate run of the head) and the dispatcher (`queue_kick`, now in lib/canccu-mqueue.sh). The
  workflow and its template copy are still identical (tests/canccu-ci.sh:89).
  - `queue_kick` is reached from `merging_step` (lib/canccu-merge.sh:258) with no check that the
    repo has a merge queue. In a repo without one, every armed PR older than `NO_CHECKS_MIN`
    costs one extra GraphQL query on every pass. The query finds no entry, so `queue_kick=` is
    never set and nothing stops the repeat.
  - `queue_kick` ignores its third argument. It writes the caller's `head` through bash's dynamic
    scope (lib/canccu-mqueue.sh:62). When GitHub gives no `headCommit`, it dequeues on age alone,
    and its comment does not say so (lib/canccu-mqueue.sh:58).
- **The review-gate rerun job** (.github/workflows/review-gate.yml):
  - `busy ""` is true: the here-string gives grep one empty line, and `-v` selects it. A head
    with no gate run yet therefore polls 30×15 s, about 7.5 minutes, before the "no run yet"
    notice.
  - Each re-run can wait about 400 s, and the runs go oldest first. With three or more runs on
    one head, the 20-minute timeout can end the job before the newest run is re-run.
- **#52.** The leftovers are closed:
  - a bad regex fails closed;
  - the reviewer's class reaches `effective_risk`;
  - `canccu-status` clips the activity by the label's real width (bin/canccu-status:65);
  - the `review_effort`/`review_model` state keys are gone (no writer left in lib/ or bin/).

  The optional item (the docs paths' lines do not count) is built, but it is wrong for
  `$`-anchored regexes. See Blocking.

## Security

- The rerun job gets `actions: write` only when a comment comes from `vars.REVIEWER_LOGIN` and has
  or had a verdict (or is an edit). It re-runs only runs of the PR's own head SHA, branch and head
  repo. Comment text never reaches a shell; it is matched with jq. Nothing new found.
- A contract PR is identified by its branch, but trust still comes from `pr_foreign`/`pr_not_ours`
  (the author and not-a-fork checks), as for every PR. A contract PR that closes a member goes to
  manual (lib/canccu-github.sh:309-312), and gated paths still force manual and high effort. So
  the branch name alone cannot make a PR auto-mergeable.
- #25 does not let a run that was denied commands pass unchecked. The `blocked` → `done` rewrite
  happens before the `Permission denials (information):` check, so `denied_ok` still compares the
  worktree with the PR head.
- `EFFORT_DOCS_PATHS` can only lower the effort for paths that are not gated
  (tests/canccu-review-effort.sh:33). A bad regex gives `high`.
- None of this is a security finding.

## Contracts

- The required-check name `review-gate` and the job's name are unchanged
  (tests/canccu-ci.sh:95). The 0BSD header is kept on both copies of the workflow.
- docs/reference/reviews.md:57-58 says that the `EFFORT_DOCS_PATHS` files' lines do not count
  toward the fix-tier 100. The code keeps that only for regexes without `$`. It runs the regex on
  `path<TAB>count` lines (lib/canccu-runs.sh:397), so `$` never matches there. Reproduced: with
  `EFFORT_DOCS_PATHS='\.ya?ml$'`, `RISKY_PATHS` empty, stats `contracts/a.yaml 400` +
  `src/a.ts 3` and `Tier: fix`, `review_effort_pure` gives `high`. With `^contracts/` it gives
  `medium`.
- The step added a state key, `queue_kick`, that docs/reference/state.md does not list. The
  `NO_CHECKS_MIN` row in docs/reference/config.md:89 still describes only the finished worker's
  PR, not the queue kick.
- docs/getting-started.md meets #67's criteria: release download, `sha256sum -c`,
  `./install.sh --check`, the Pro note, and the known limits. The Pro note was replaced as
  planned when `hosts/pro.conf` landed. The "Known limits" line (docs/getting-started.md:90) still
  cites #26 and #15, but both are closed: #15 built the dispatcher claim across hosts.
- #23's "behind main" criteria were not built. The owner's 2026-11-09 comments on the issue
  replace them with the two real causes, and both causes are fixed. I count this as agreed, not a
  `criterion` finding.

## Test quality

- tests/canccu-waits.sh:179-205 reproduces #25: a `blocked` exit with an open PR, under
  `paused` = finish, goes to review; without a PR it still goes to needs-you; a lifted needs-you
  starts the review. Each assertion would fail if the change were reverted.
- tests/canccu-units.sh:215-262 covers the contract PR end to end:
  - ours, and its branch names the unit;
  - a contract PR that closes a member → manual;
  - the review prompt;
  - a pass reviews the contract PR, not the draft;
  - after its merge → check on the draft, and the worker resumes.
- tests/canccu-merge.sh:102-142 covers `queue_kick`: stuck, young, running, not waiting, once per
  head, and the enqueue failing. It never covers a null `headCommit`.
- tests/canccu-ci.sh:96-120 runs the real rerun script, cut out of the workflow, against a fake
  gh. That is a good test. It only feeds two completed runs, though. It has no empty list (that
  case would show the `busy ""` wait), no run in progress and no `action_required` run.
- tests/canccu-review-effort.sh:26-27 tests that the docs paths' lines do not count, but only with
  the `^`-anchored `^contracts/`. That is why the `$` case above passes CI.
- No test of the step was found skipped or weakened.

Blocking:
1. [correctness] lib/canccu-runs.sh:397 — the docs paths' lines still count toward the fix-tier 100 when `EFFORT_DOCS_PATHS` is `$`-anchored
   Evidence: `stats=$(grep -vE "$EFFORT_DOCS_PATHS" <<<"$stats")` runs the regex on `path<TAB>count` lines. With `EFFORT_DOCS_PATHS='\.ya?ml$'`, stats `contracts/a.yaml 400` + `src/a.ts 3` and `Tier: fix`, `review_effort_pure` gives `high`, while `^contracts/` gives `medium`. This breaks docs/reference/reviews.md:57-58, under which those lines do not count.
   Fix: filter on the path field only, e.g. `stats=$(awk -F '\t' -v re="$EFFORT_DOCS_PATHS" '$1 !~ re' <<<"$stats")` (the regex is already known to be valid here). Add a `$`-anchored case next to tests/canccu-review-effort.sh:26.
Non-blocking:
- [other] .github/workflows/review-gate.yml:105 — `busy ""` is true, so a head with no gate run polls about 7.5 min before the "no run yet" notice (the template copy too)
- [other] .github/workflows/review-gate.yml:120 — runs are re-run oldest first with up to ~400 s each; with 3+ runs on a head the 20-min timeout can end the job before the newest is re-run
- [other] lib/canccu-merge.sh:258 — `queue_kick` runs a GraphQL query on every pass for each armed PR past `NO_CHECKS_MIN`, even in a repo without a merge queue
- [other] lib/canccu-mqueue.sh:58 — with no `headCommit`, the entry is dequeued on age alone; `head` comes from the caller's scope, not the unused third argument (line 62)
- [docs] docs/reference/config.md:89 — the `NO_CHECKS_MIN` row does not say that the key also sets when a stuck queue entry is kicked
- [docs] docs/reference/state.md:76 — the state key `queue_kick` (once per head) is not listed
- [docs] docs/getting-started.md:90 — "Known limits" still cites #26 and #15, both closed (#15 built the claim across hosts)
- [test-gap] tests/canccu-ci.sh:96 — the rerun-script test has no empty list, no run in progress and no `action_required` run
- [test-gap] tests/canccu-merge.sh:102 — no `queue_kick` case with a null `headCommit`
- [simplify] lib/canccu-github.sh:86 — `pr_for` has three near-identical "newest open, not foreign" loops
Pre-existing:
Risk: low — the step's deep-review report; the one blocking item is a one-line fix in the review-effort filter, and it only errs toward a higher effort
Findings: 1 blocking, 10 non-blocking, 0 pre-existing
Review verdict: changes 9a3e02c3c1a1ee775a733bb7cc1e079a94fb185f
