<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Step 4 Release 0.3: deep review

Reviewed at origin/main f10f1700c64c5e07612a4290ad69e9fda7e8abb2. The scope was the step's merged
PRs (#232, #234, #240, #245, #247, #249, #251, #253, #255, #261) and their issues. Follow-ups
already filed (#233, #235, #241, #248, #254, #257, #260) are not reported again.

## Architecture

- **The review brake** (#232, lib/canccu-brake.sh, lib/canccu-brakestate.sh, lib/canccu-verdict.sh,
  lib/canccu-depth.sh): the parts fit together. While the brake is on, the light review class is
  off, the effort is raised (unless capped), the pass-without-repeat sentence is dropped, and an
  item with a blocking class (or no class) under `Pre-existing:` blocks. Only `po` can release it,
  through `canccu-dispatcher brake release`. One gap: `REVIEW_MODEL_LIGHT` is not reverted while
  the brake is on. This is harmless while the light class is off, but nothing ties the two together.
- **Accept carry-over** (#245/#244, lib/canccu-mainmerge.sh, lib/canccu-accepts.sh): an accept is
  kept only when the head is a merge of main whose tree `git merge-tree --write-tree` reproduces,
  or a resolved merge whose fix-check passed. `accept_held` and `ship_reviewed` still require a
  review of the exact head (rule 2). Sound.
- **The dispatcher claim** (#253, lib/canccu-claim.sh):
  - `claim_tick` writes the claim body, then reads it back. GitHub offers no compare-and-swap, so
    two hosts whose write and read-back interleave can both act for one pass. Each sees the other's
    claim only at its next pass.
  - The `EXIT` trap at bin/canccu-dispatch:263 releases the claim on every exit, a `die` included.
    The workers' tmux sessions outlive the loop, so a second host can take the repo while those
    runs are still live.
  - Expiry compares times from different hosts' clocks.
  - None of this breaks rule 2: a merge still needs a passed review of the exact head. It can
    still start the same run twice, though.
- **The upgrade between passes** (#20, lib/canccu-upgrade.sh, bin/canccu-dispatch:262-272):
  - While the upgrade is pending, new runs are held, and the `exec` happens only once no run of
    the project is live.
  - An `exec` runs no EXIT trap, so the claim, the lock and the pane pass on to the new release.
  - Correct.
- **Telegram** (#249, lib/canccu-telegram.sh, lib/canccu-notify.sh): one module reads the token,
  and the reply inbox goes to the leader as data. The image path, though, bypasses the content
  setting the rest of the module applies (see Contracts).
- **CI checks** (#261) and **test tiers** (#255): `CI_CHECKS` is shared by `ci_state` and the
  report, and `test_rule` is the one place that builds the prompt's test sentence. Clean.

## Security

- **Bot token:**
  - Only `tg_call` reads the token, into curl's config on stdin. It appears in no argument, log or
    process title.
  - curl's errors have the token cut out.
  - `tg_token_problem` refuses a token file that is inside a repo, has a mode other than 600, or
    does not have a token's shape. The shape check keeps the token from breaking out of the quoted
    config line.
  - The leader's settings.json denies the token file.
- **Inbox:** only replies from `TELEGRAM_USER_ID`, in open topics, are kept. The leader's prompt
  says a reply is text to weigh, never a command to run.
- **Images:**
  - SVGs are fetched from GitHub by path at the passed head, never from links in the PR body.
  - The paths are filtered to a safe character set.
  - `rsvg-convert` runs under `timeout 30`.
  - Files are copied to plain names before `curl -F`.
- **`dispatcher_pr`** (#237, lib/canccu-exits.sh:69-105): the body file goes through `realpath`
  and must lie inside the worktree. Nothing found trusts a PR body for carrying `CANCCU_MARK`:
  `user_comments` and the findings parser use the marker only to skip the dispatcher's own
  comments and issue bodies.
- **Claim:** the claim issue never enters the queue (lib/canccu-queue.sh). A forged claim body
  can at most pause a host. It cannot cause an accept or a merge (rule 3 holds).
- The data-flow finding is under Contracts: rendered images leave the host under
  `NOTIFY_CONTENT=link`.

## Contracts

- **`NOTIFY_CONTENT=link`:** contracts §4 (docs/plan/contracts.md:105) says that "With
  `NOTIFY_CONTENT=link` only the first line, the last line and the link leave the host". Plan
  decision 6 adds that link is "for users who want only a link to leave the host".
  - `notify_tick` calls `notify_images` (lib/canccu-notify.sh:341) regardless of `NOTIFY_CONTENT`.
  - `notify_images` (lib/canccu-notify.sh:280) has no check either.
  - So under `link`, every SVG a passed PR changes is rendered and uploaded to Telegram, with the
    repo's content in it.
  - docs/reference/notify.md "Images" does not mention the setting.
  - This breaks the contract's promise about what leaves the host.
- **`KEEP_ACCEPT_ON_MAIN_MERGE`:** lib/canccu-config.default:62 sets it to 1, as #244 decided.
  contracts §5 (docs/plan/contracts.md:116) still says 0, and #245 carries no `Roadmap note:` for
  the change.
- The other §5 defaults that #242 changed match the issue: `REVIEW_LIGHT`, `STEP_DEEP_REVIEW`,
  `DEEP_REVIEW_EFFORT`, `STEP_TAG`, `BUDGET_LINES`, `PACE`, `CADENCE_DAYS` and
  `FIXCHECK_COUNT_RESOLVED`.
- The Telegram keys `TELEGRAM_CHAT_ID`, `TELEGRAM_USER_ID` and `TELEGRAM_TOKEN_FILE` are locked
  (rule 8).
- The brake's feed line uses the §3 form (`po ask needs-you`).

## Test quality

- tests/canccu-notify.sh tests `NOTIFY_CONTENT=link` for message text (around lines 140-142) and
  tests the SVG path (around lines 318-330), but never the two together. That is why the contract
  break above passes CI.
- tests/canccu-claim.sh:
  - Line 178 is named "… the label is created where missing", but it asserts that no
    `label create` happens, because the label exists. Line 181 covers the actual creation. The
    name misleads.
  - No test has two hosts claim at once (the read-back loses), and none covers a claim released by
    a crash exit while workers are live.
- The assertions removed in tests/canccu-pane.sh and tests/canccu-ci.sh were rewrites for changed
  behaviour (the CI timeout limits, the monitor lines). None found was weakened or skipped.
- #261's `ci_job_timed_out`/rerun path and #255's `TEST_TIER` prompts each have tests that would
  fail if the behaviour broke.

Blocking:
1. [contract] lib/canccu-notify.sh:341 — rendered repo SVGs are sent to Telegram under `NOTIFY_CONTENT=link`
   Evidence: `notify_tick` calls `notify_images` (line 280) without checking `NOTIFY_CONTENT`. contracts §4 (docs/plan/contracts.md:105) says that under link only the first line, the last line and the link leave the host. No test combines link with an SVG-changing PR.
   Fix: under `NOTIFY_CONTENT` other than full, skip `notify_svgs` (or send only the PR link). Add a test in tests/canccu-notify.sh that, under link, a passed PR changing an SVG sends no photo. Say so in docs/reference/notify.md "Images".
Non-blocking:
- [docs] docs/plan/contracts.md:116 — §5 gives `KEEP_ACCEPT_ON_MAIN_MERGE` the default 0, but lib/canccu-config.default:62 ships 1 (#244), and #245 has no `Roadmap note:` for it
- [other] lib/canccu-claim.sh — `claim_tick`'s write-then-read check has no compare-and-swap: two hosts can both act for one pass, and expiry compares the clocks of different hosts
- [other] bin/canccu-dispatch:263 — the EXIT trap releases the claim on a crash or `die` too, while the project's tmux workers keep running, so another host can take the repo during live runs
- [test-gap] tests/canccu-claim.sh:178 — the name says the label is created, but the assertion checks that it is not; two hosts claiming at once is untested
- [other] lib/canccu-depth.sh — the brake turns the light review class off but leaves `REVIEW_MODEL_LIGHT` as configured; nothing ties the two together
Pre-existing:
Risk: low — a report only; the one blocking item is a small, local fix in the notifier
Findings: 1 blocking, 5 non-blocking, 0 pre-existing
Review verdict: changes f10f1700c64c5e07612a4290ad69e9fda7e8abb2
