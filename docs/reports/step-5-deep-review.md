<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Step 5 Fixes after 0.3: deep review

Reviewed at origin/main 1c6605e65b46e589065c054e5adb2f30d21a060f, against tag `step-4`. The scope
was the step's merged PRs (#299, #306, #305, #311, #313, #315) and their issues (#295, #296, #297,
#298, #307). What the follow-up #300 already lists is not reported again.

## Architecture

- **Run tags** (#299, lib/canccu-engine.sh, lib/canccu-containers.sh): the fix for two projects
  sharing a sweep prefix moved the collision instead of removing it. The tag is an encoding whose
  other half is the prefix match in `containers_sweep`; `--` is no escape, because a project name
  may hold it (blocking 1). It also renames the tag of every project with a `_` in its name, and
  nothing takes over the objects under the old one (blocking 2).
- **Waits and their bounds** (#299, #313, lib/canccu-followup.sh): `busy_wait` (bounded from
  `check_at`) and `rerun_wait` (bounded by `ci_wait_at`, per head) do not extend each other:
  `ci_rerun` resets `check_at` only when it calls gh, and a refused call then runs under the 600 s
  bound. `needs_you` clears `ci_wait_at`, so a lifted one starts a new wait. Sound.
- **Verdict reuse and the pass of a merge of main** (lib/canccu-pipeline.sh): `pass_sha` moves
  before the ask form is written and is put back when `after_pass` fails; `ask_review` compares the
  head with it, so a stale pass is not shown as a pass. Sound.
- **Dry run** (#315): migrations 1 to 5 write only through `_st_put` and `step_set`, so they stay in
  `DRY_ST`, and the shell that runs them is not a `$(…)`.
- **Budget ask** (#315): `step_ended` is checked before the ask and after the `budget_ny` guard.
  A step that ended after it was asked keeps its mark; no second ask follows.
- **Notifier** (#299): the retries of a failed close or edit (`unsettled`) stop at the first
  failure. That is right for an outage, but a refusal `notify_done` does not know stays at the
  head and blocks every later line (blocking 4). A transient error of gh that holds 404 loses a
  passed head's images (blocking 5).
- **Nightly**: the only Nightly run listed on main (22d6c3c) is red with `fork: retry: Resource
  temporarily unavailable` (#314, open). The release workflow runs the same job before it
  publishes, so the cause matters for step 6. It was not established here: tests/canccu-upgrade.sh,
  one of the files that failed, passes alone, and no processes were left behind.

## Security

- The collision of run tags crosses the project border: one project's sweep removes another's
  containers, networks and volumes (blocking 1). It needs two projects on the host whose names
  differ only in `_` and `--`.
- `canccu-notify photos` takes only files that start with the PNG signature. This narrows the
  leader's `photos *` allow rule to what it says; a file made to start with these 8 bytes still
  passes, which needs write access the leader would have to have already.
- `merge_method_read` takes only the words its own query builds, so a gh error body cannot reach a
  `--<word>` flag. The ask form carries only the dispatcher's values and the reviewer's stripped
  lines. Telegram replies still need both the chat id and the user id.
- No new secret, token or path was found in logs, comments or fixtures.

## Contracts

- docs/reference/engine.md:50 fixes the tag's form and no longer matches the code (non-blocking).
- contracts §4 (the ask form, line by line) and §3 (feed lines): the changed code keeps the texts.
- contracts §5 still says `KEEP_ACCEPT_ON_MAIN_MERGE` 0 where the default is 1: reported by the
  step-4 deep review and not changed by this diff, so not listed again.
- The duration in the comments of the nightly and the release workflow is wrong (non-blocking).
- No breaking contract and no destructive migration was found.

## Test quality

- tests/canccu-engine.sh:278 checks one pair (`web_x`, `web-x`). A test of the property (distinct
  valid names never share a tag or a prefix) would have failed on blocking 1. No test runs
  `containers_sweep` with the objects of a second project of a similar name.
- tests/canccu-asks.sh:88 does not test what its name says (non-blocking).
- No skipped test and no weakened assertion was found beyond the gaps #300 lists: the changed
  assertions follow changed behaviour.

Blocking:
1. [correctness] lib/canccu-engine.sh:114 — two valid project names that differ in `_` and `--` now share one run tag, so each one's sweep removes the other's containers, networks and volumes
   Evidence: `canccu_valid_name` allows `^[a-z0-9][a-z0-9_-]{0,30}$`, so `web_x` and `web--x` are both valid. `run_tag 7` gives `canccu_web--x_7` for both (step-4: `canccu_web-x_7` and `canccu_web--x_7`). Run with a stubbed docker list holding a volume of `web--x`'s run 7, `containers_sweep` of `web_x` passes `canccu_web--x_7` to `run_containers_rm`, and the other way round; at step-4 it removed neither. `web-_x`, `web_-x` and `web---x` share a tag too.
   Fix: keep the project's `_` (Compose allows it) and turn every `_` of the key into `-`, as now: the last `_` separates. In `containers_sweep` take only tags with no `_` after the prefix (`[[ $t == "$pre"* && ${t#"$pre"} != *_* ]]`), so `web` does not match `web_x`. Test tags and sweep with `web`, `web_x`, `web-x` and `web--x`.
2. [correctness] lib/canccu-engine.sh:114 — after the upgrade the containers and volumes of a project with a `_` in its name are never removed
   Evidence: a unit 7 of `web_x` open at the upgrade has objects tagged `canccu_web-x_7`. After it, `unit_tags` gives `canccu_web--x_7` and the sweep's prefix is `canccu_web--x_`, so neither the unit's end nor any sweep removes them (the stubbed sweep of `web_x` leaves `canccu_web-x_7`). docs/reference/engine.md says that they go when the unit ends. A resumed run also gets a new `COMPOSE_PROJECT_NAME`, so a second stack starts beside the first. The CHANGELOG does not name it.
   Fix: have the unit's end remove the old tag of its key too (`unit_tags` adds it when the project name holds a `_` and no project folder has the old tag's name), or name the leftover and the command that removes it in the CHANGELOG's upgrade notes. Test the first.
3. [correctness] lib/canccu-spend.sh:78 — a finding written as `* Change: …` is read as the `Change:` heading, and the items after it are not counted
   Evidence: for a review body without a valid verdict, `Blocking:`, `* Change: the lock is dropped early`, `* b second`, a blank line and `Review verdict: changes <sha>`, `findings_count` gives `0 0`; with `* The change: …` it gives `2 0`. The `*` in `^[[:space:]*_#]*change:` matches the bullet. `blocking_note` stores the 0, so `extra_fix_due` judges on it.
   Fix: match a heading only, as `ask_change` does: the line ends after the colon and its markup (`^[[:space:]*_#]*change:[[:space:]*_]*$`). Add the case to the test.
4. [correctness] lib/canccu-notify.sh:385 — one edit or close that Telegram refuses for a reason `notify_done` does not list stays first in `unsettled`, and the `break` keeps every later line from being tried
   Evidence: run of `notify_tick` with the Telegram calls stubbed and `unsettled` holding A and B: with `closeForumTopic` of A's topic refused ("not enough rights to manage forum topics"; B's close would work), two passes leave `A B` and B is never tried; the same when A's edit answers "message can't be edited". The loop and its `break` were added in the step (#299).
   Fix: give up a refusal that no retry changes (such as "message can't be edited"), and go on to the next line after a refusal by Telegram; stop the loop only on a curl failure or a time-out, so that Telegram down still costs one call. Test a refused edit and a refused close at the head with a second line behind each.
5. [correctness] lib/canccu-notify.sh:310 — `*404*` matches any error text with 404 in it (a path or a request id), so a transient error counts as a deleted file and a passed head's image is never sent
   Evidence: a PR that changes `img/404.svg`, with a network error from gh that names the URL (`Get "https://api.github.com/repos/example-org/web/contents/img/404.svg?ref=…": dial tcp: i/o timeout`): `notify_svgs` returns 0, so `notify_images` records the head and the image is never sent. With `img/a.svg` and the same error it returns 1 and the next pass retries. The match was added in the step (#299); the comment above it says that any other error is transient.
   Fix: match gh's status, `*"(HTTP 404)"*`. Test it with a path that holds 404 and such an error (tried again next pass), and keep a real 404 skipped.
Non-blocking:
- [docs] docs/reference/engine.md:50 — it says that any character but `a-z0-9-` becomes a `-`; a project's `_` becomes `--`
- [docs] .github/workflows/nightly.yml:24 — the comment says that the run takes about an hour of its 60 minutes (release.yml:73 too); ci.yml:105 says half an hour, and the Nightly run took 30m40s
- [other] .github/workflows/nightly.yml:24 — the only Nightly on main is red with `fork: retry: Resource temporarily unavailable` (#314); the cause is not established, and the release runs the same job before it publishes
- [test-gap] tests/canccu-asks.sh:88 — it counts `issue comment` calls, not renderings: it passes with the form still rendered after the failed post
Pre-existing:
Risk: normal — blocking 1 removes another project's volumes, but only for two projects with such names on one host; 2 to 5 are small
Findings: 5 blocking, 4 non-blocking, 0 pre-existing
Review verdict: changes 1c6605e65b46e589065c054e5adb2f30d21a060f
