<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Step 6 Token cost: review loop: deep review

Reviewed at origin/main 92d681ba4a2bfabf24f20905c0b9e21284661117, against tag `step-4`. The range
holds step 5's PRs too (#299, #306, #305, #311, #313, #315), which the step-5 deep review
(docs/reports/step-5-deep-review.md) covered. This review looks mostly at what came after it:
#321 (the fixes of that review's findings), #323 (health chores) and #334 (the review fix loop,
issues #325 and #326). Findings the follow-up #335 already lists are not reported again.

## Architecture

- **Two fix budgets** (#334, lib/canccu-fixbudget.sh): `fixes` (red CI, `FIX_ATTEMPTS`) and
  `rfixes` (review fixes, `REVIEW_FIX_ATTEMPTS`) share `fixes_pr`, and `_fix_bump` resets the
  other count when the PR changes. Older state keeps its `fixes` as CI fixes, as the header
  says. Sound. One piece was not moved over: `extra_fix_due` still gates the extra round of
  `FIX_EXTRA_IF_FEWER` on `fix_max` (`FIX_ATTEMPTS`). That round now counts as a review fix
  (`rfix_count`, docs/reference/review-depth.md), so `FIX_ATTEMPTS=0` (no CI fixes) also turns
  off a review round that config.md says runs past the cap (blocking 1).
- **The owed round** (#334, lib/canccu-actions.sh, lib/canccu-resume.sh): a full review's
  `changes` with no review fix left saves the findings, parks at needs-you with `stage=fixing`,
  `reviewed_sha` and `fix_owed=1`. `owed_round` runs before `extra_round` (needs-work) and before
  the plain answer resume (needs-you), so the lead's comment becomes a `fix` run with the findings
  and the comments. The comments are also added to the findings file, which is what the fix-check
  reads. Any acted-on verdict clears `fix_owed` and `fix_cont`, so a hand review cannot leave a
  stale round. `resume … || return 0` comes before the state changes, so a refused start is retried
  whole. Sound.
- **Full review after the continued round** (lib/canccu-pipeline.sh `check_pr`): `fix_cont` sends
  a fix over `FIXCHECK_FULL_LINES` of the PR's own lines to a full review (`own_lines_over`,
  split out of `postpass_full`). Lines merged from main drop out by `count_from`. The split keeps
  `postpass_full`'s order (lines, gated, risky). Sound.
- **Run tags** (#321, lib/canccu-engine.sh, lib/canccu-containers.sh): the project keeps its `_`,
  the key has none, and the sweep takes only tags with no `_` after its prefix. This closes the
  step-5 blocking findings 1 and 2. One leftover of the old collision remains: `run_tag_old` skips
  a tag another project's name maps to, but that project's sweep still matches it (non-blocking).
- **Notifier** (#321, #323): `notify_try` gives one place to tell a refusal from "not reached";
  the settle loop stops only on the latter. A refusal `notify_done` does not list is tried again on
  every pass, with no bound (non-blocking).

## Security

- `owed_round` puts the user's comments into the fix prompt and the findings file. They come from
  `user_comments`, which keeps only `USER_LOGIN`'s comments without the dispatcher's mark and drops
  those made while a run was alive. No other account's text reaches the fix run or the fix-check.
- The SVG fetch now skips only on gh's `(HTTP 404)`. The run-tag sweep no longer crosses into a
  project with a `_`/`-` variant of the name, except for the old tags noted above.
- No new secret, token, absolute path or personal name was found in the code, tests or fixtures.

## Contracts

- `REVIEW_FIX_ATTEMPTS` has its row in lib/canccu-config.default, lib/canccu-settings.tsv
  (`int:0:10 project open`, as #326 says) and docs/reference/config.md. The default is 1.
- The snapshot's `fixes` field is additive and keeps `schema` 2, as contracts §1 allows. It is
  documented in docs/reference/snapshot.md.
- The status line `fixes: ci 2/2 · review 0/1` is written as #326 fixes it.
- `MERGE_TRIES` was never a setting in config.default or settings.tsv. Its removal (#323) changes
  only docs/reference/merging.md, which now says it is a fixed bound.
- docs/reference/config.md:63 says the extra round of `FIX_EXTRA_IF_FEWER` runs "past the cap".
  The code makes it depend on `FIX_ATTEMPTS` (blocking 1).
- No breaking contract and no destructive migration was found.

## Test quality

- tests/canccu-reviewfix.sh covers each criterion of #325 and #326 with checks that read the state,
  the worker's prompt and gh's calls. The merge-of-main cases use a real git history.
- The changed assertions in tests/canccu-followup.sh and tests/canccu-followups.sh follow the
  changed behaviour: the old `fixes` checks became `rfixes` checks, and none was dropped.
- tests/canccu-dispatch.sh adds the `fix runs:` section to the two owner-list expectations
  exactly, and does not loosen them.
- tests/canccu-followups.sh:183-185 (`fix-zero`) locks in the old meaning: with `FIX_ATTEMPTS=0`
  and the default `FIX_EXTRA_IF_FEWER=1` it asserts "FIX_ATTEMPTS=0: no extra fix round", so
  blocking 1 passes the suite.
- The snapshot's `fixes` field is checked only by the key count (tests/canccu-pane.sh:181). Its
  values and its null without a PR are not checked (non-blocking).
- No skipped test was found.

Blocking:
1. [correctness] lib/canccu-fixbudget.sh:48 — `extra_fix_due` still requires `FIX_ATTEMPTS > 0`, so with no red-CI fixes allowed the extra review round of `FIX_EXTRA_IF_FEWER` never runs, although it now counts as a review fix
   Evidence: with `blocking_prev=3`, `blocking_last=1` and `FIX_EXTRA_IF_FEWER=1`, `extra_fix_due` gives "not due" for `FIX_ATTEMPTS=0 REVIEW_FIX_ATTEMPTS=1` and "due" for `FIX_ATTEMPTS=2 REVIEW_FIX_ATTEMPTS=0`. So a fix-check's `changes` with fewer findings goes to needs-you when CI fixes are off. #326 makes `FIX_ATTEMPTS` "automatic red-CI fix runs per PR" (config.md:61), and config.md:63 and review-depth.md:85 make this round a review fix past the cap. The comment kept above the line ("FIX_ATTEMPTS=0 means no automatic fix run at all") is the old meaning.
   Fix: drop the `(( $(fix_max) > 0 ))` term, since the round runs past `REVIEW_FIX_ATTEMPTS` by design. If `REVIEW_FIX_ATTEMPTS=0` is meant to turn it off, gate it on `(( $(rfix_max) > 0 ))` instead and say so in config.md. Then change the `fix-zero` test in tests/canccu-followups.sh:183-185 to match, rather than adding a second test that contradicts it: flip its assertion to `due` (and its name to "FIX_ATTEMPTS=0: the extra review round still runs"), or, with the `rfix_max` gate, set `REVIEW_FIX_ATTEMPTS=0` in its `env_new` and keep `none`.
Non-blocking:
- [correctness] lib/canccu-containers.sh:93 — `run_tag_old` (line 34) gives up the pre-#317 tag of `web_x` when a project `web-x` exists, but `web-x`'s sweep still matches `canccu_web-x_<key>` and removes the old-tag objects of `web_x`'s open unit. This is the rest of the old collision, limited to objects made before the upgrade.
- [correctness] lib/canccu-notify.sh:346 — an edit or close that Telegram refuses for a reason `notify_done` does not list stays in `unsettled` and is tried again, with a log line, on every pass with no bound.
- [test-gap] tests/canccu-pane.sh:181 — the snapshot's new `fixes` field is checked only by the key count, not by its values or its null without a PR.
- [test-gap] tests/canccu-reviewfix.sh:76 — the hand-review case covers a hand `pass` after the owed round, not a hand `changes` (which owes the round again on the new head).
Pre-existing:
Risk: low — one blocking finding, reachable only with `FIX_ATTEMPTS=0`, and it stops for a person rather than doing anything wrong
Findings: 1 blocking, 4 non-blocking, 0 pre-existing
Review verdict: changes 92d681ba4a2bfabf24f20905c0b9e21284661117
