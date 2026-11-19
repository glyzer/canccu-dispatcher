<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Package accept-and-host-profiles (#244, #14): plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (one session builds every
> task itself, in order; no subagents).

**Why a plan first:** #244 alone would be a feature: its spec is exact and the code matches the
"Today" section. #14 is not. Its body (2025) and the product owner's comments of 2026-11-10,
-11-16 and -11-17 set different values for the same keys, and the merged #168 deliberately
undid one of the body's points ("pro takes max's budgets"). It also adds about ten settings that
reach every prompt and every run. The values under "Decisions to approve" need the product owner's
OK before anything is built. Risk: high (the accept path, and the caps, throttle, budgets and
prompts of every run).

**Order:** #244 first (tasks A1–A5), then #14 (tasks H1–H8). Each task is committed with its tests
before the next one starts. One PR closes both issues.

## Part A: #244, an accept survives the dispatcher's merges of main

The code matches the issue's "Today" section: `keep_accept` (`lib/canccu-accepts.sh`),
`KEEP_ACCEPT_ON_MAIN_MERGE=0` locked, label channel only, `main_merge_only` (clean merges only),
and otherwise `requeue`, which also drops the `accepted` label (`drop_accepted`).

### A1. Default on
- `lib/canccu-config.default`: `KEEP_ACCEPT_ON_MAIN_MERGE=1`, with the comment saying a clean merge
  of main, or a resolved one whose fix-check passed, carries the accept. The settings row stays
  `enum:0|1 project locked`.
- Tests: `tests/canccu-config.sh` checks default 1. `tests/canccu-merge.sh` keeps its `=0` case
  (today's behaviour).

### A2. Any counting channel carries over
- `keep_accept <n> <pr> <old> <head>` takes the accept from **either**
  - the label, as today: `accept_channel label`, the PR's `accepted`, `accepted_by_user` since
    `accept_at`; **or**
  - `ship_recorded <pr> <old>`: a canccu-ship record for the old head whose actor's channel
    (`ship` for po, `leader` for leader) `ACCEPT_CHANNELS` lists.
- `accept_by` (new state field: `label` or `ship`) records which channel it was, for the log.
- Tests (`tests/canccu-merge.sh`, the existing `mmrepo` fixture): accepted with canccu-ship (an
  accepts.log line for `MB_B`, no label), then a clean merge of main → auto-merge armed on
  `MB_MM1` with `--match-head-commit MB_MM1`, and no new ask block. The same with
  `ACCEPT_CHANNELS=label` → requeue as today.

### A3. A merge with resolved conflicts, once its fix-check passes
1. **Recognise it** (`resolved_merge_only <old> <head>`, next to `main_merge_only` in
   `lib/canccu-merge.sh`): the same first-parent walk of at most 5 steps from head to old, each
   step a two-parent commit whose second parent is on `origin/main`. Unlike `main_merge_only`, the
   tree may differ from `merge-tree --write-tree`. It prints the files where the tree differs from
   the merge-tree result (which still has the conflict markers): the resolved lines, measured the
   way `FIXCHECK_COUNT_RESOLVED` measures them (`count_from`). The walk fails on any commit that
   is not such a merge. That is a new commit of the PR's own (AC 4).
2. **Hold, not carry**: in `accept_step` and `merging_step`, when `keep_accept` fails, the accept
   counted on old (A2's check) and `resolved_merge_only` holds, and every printed file is in the
   PR's own diff at old (`git diff --name-only --no-renames $(merge-base origin/main old) old`),
   the state keeps `carry_sha=<old>` and `carry_by=<label|ship>` before `requeue`. The label still
   goes, as today: it is the old head's. A file outside that diff, or a git error, leaves
   `carry_sha` empty, and a new accept is asked (AC 5).
3. **The review runs as today**: `requeue` → `postpass_step` → a fix-check (or a full review, by
   `postpass_full`) of the new head.
4. **Carry on pass**: `after_pass` (`lib/canccu-actions.sh`) on a manual class with `carry_sha`
   set and `KEEP_ACCEPT_ON_MAIN_MERGE=1`: `merge_auto "$n" "$pr" accepted "$head"`, no
   `to_accept`. The log line is the carry-over line (A4).
5. **Clearing**: `carry_sha` and `carry_by` are cleared by `new_cycle`, by a `changes` verdict (the
   fix round runs as today, and its fix-check pass asks again: AC 3), and by any later push that
   `resolved_merge_only` does not accept from `carry_sha`.
- `STATE_FORMAT` stays: empty new fields mean today's behaviour.
- Tests (the `mmrepo` fixture gets a conflicting branch: `MB_RC`, a merge of main resolved inside a
  file of the PR's diff; `MB_RX`, one resolved by editing a file outside it):
  - accepted (label, and ship), `MB_RC` pushed, fix-check `pass` → auto-merge on `MB_RC`, no ask
    block (AC 2);
  - the same with fix-check `changes` → the worker's fix round, `carry_sha` empty (AC 3);
  - a plain commit after old → requeue, a new accept asked after its pass (AC 4);
  - `MB_RX` → requeue, a new accept asked (AC 5);
  - `KEEP_ACCEPT_ON_MAIN_MERGE=0` → no `carry_sha`, today's path (AC 6).

### A4. Log line
Today's line, with the channel and the step-3 suffix:
`#<n> PR #<pr>: \`accepted\` carried over from <old7> to <head7>: a merge of main only (KEEP_ACCEPT_ON_MAIN_MERGE=1)`.
When A3 applied, `(conflicts resolved, fix-check pass)` follows it (`(conflicts resolved, review
pass)` after a full review). The existing log test keeps its text.

### A5. canccu-ship never arms an unreviewed head (the leader's comment of 2026-11-19)
- `bin/canccu-ship` on a managed unit: if the head is not `pass_sha` and `main_merge_only
  pass_sha head` fails, it writes the accept record for that head and arms nothing. It sets
  `carry_sha=<head>` and `carry_by=ship`. Its output, and the log line, say:
  `#<n> PR #<pr>: <head7> has no review pass yet; sent to the fix-check first, and the accept carries over once it passes`.
  The dispatcher's next pass runs the fix-check (`postpass_step`), and A3.4 merges on pass.
- `ship_armed` in `accept_step` already requires `head == accept_sha` (a passed head); a test pins
  it.
- An unmanaged unit keeps today's direct `gh pr merge --auto` (no review state to check).
- Tests: `tests/canccu-merge.sh`, or `tests/canccu-review2.sh` where the canccu-ship cases live:
  ship on an unreviewed head → no `pr merge` in gh.log, the line above, and after a fix-check pass
  → `pr merge --auto --match-head-commit <head>`.

### A docs
`docs/reference/merging.md` (the accept channels, the carry-over), `docs/reference/config.md` (the
row: default 1, the new meaning), `docs/security.md` (the line on a merge carrying an accept: S2
is done, and a resolution outside the PR's diff never carries), CHANGELOG under Unreleased (an
upgrade note: the default is now 1; set 0 to keep today's behaviour).

## Part B: #14, host profiles and host-only settings

### Decisions to approve (product owner)
Where the issue body and the later comments differ, the newest comment wins. The rest of the body
stands:

| Key | Issue body | Plan (source) |
|---|---|---|
| pro `CAP`, `TOTAL_CAP` | 1, 1 | 1, 1 (body; already so) |
| max `CAP`, `TOTAL_CAP` | today (3) | **2, 2**: v2 runs two at once (2026-11-16 comment) |
| pro `USAGE_SLOW/STOP/WEEKLY_DRAIN` | 40 / 80 / 70 | **Question**: today 80 / 95 / 90 (0.2 plan, #101). The 11-10 comment says CAP=1 and the throttle protect the 5-hour window, but gives no numbers |
| pro budgets, `STEP_BUDGET` | lower than max | **Question**: #168 (merged) set them equal to max, because shorter runs stopped follow-ups midway. Plan: keep them equal unless you name lower values |
| pro `MODEL` | empty | `claude-opus-5-5` for workers, planner and reviewer (11-10 update); `FIX_MODEL`, `HEALTH_MODEL` Sonnet |
| `REVIEW_MODEL_LIGHT`, `FIXCHECK_MODEL` | – | cleared in both profiles: v2 reviews on Opus (11-16) |
| review effort | `REVIEW_EFFORT_DEFAULT=medium`, gated stays high | no new key. The existing `REVIEW_EFFORT_MAX` and `DEEP_REVIEW_EFFORT`: pro `medium`/`medium`, max `high`/`high` (11-17). That replaces the body's point: on pro, a gated path is reviewed at medium too |
| `PACKAGE_MIN_ISSUES=3`, the planner hint | pro | left to #242's shared defaults: a profile never changes which features are on (11-17) |

### H1. Profiles
`hosts/pro.conf` and `hosts/max.conf` as in the table. Tests (`tests/canccu-hosts.sh`): each
profile's caps; the throttle state (`normal`, `slow`, `stop`, `drain`, from `usage_state`) at each profile's thresholds;
`review_effort_pure` on a gated path and on a normal diff under each profile; and the same project
on pro and max gets the same feature keys (all keys outside the profile files are equal).

### H2. `BASE_BRANCH` (default `main`)
Replaces the fixed `main` / `origin/main` in: the worker's worktree base (`libexec/canccu-worker`),
the planner prompt, the reviewer and fix-check prompts (`lib/canccu-runs.sh`), the CI-on-base line,
`main_merge`, `main_merge_only`, `count_from`, `pr_fetch`, and the post-merge pull
(`lib/canccu-aftermerge.sh`). `canccu-init` writes the repo's default branch
(`gh repo view --json defaultBranchRef`). Test: one end-to-end case with `BASE_BRANCH=trunk` in
the harness repo, and a grep test that no `origin/main` is left outside the docs and the defaults.

### H3. `CLONE_ROOT`, `EXTRA_PATH`, `GUARD_VMEM_KB`
`CLONE_ROOT` (default `~/code`): the default clone parent in `canccu-init` and the panes' start dir
in `canccu-up`. `EXTRA_PATH` (default empty) replaces the fixed list in `lib/canccu-engine.sh`.
`GUARD_VMEM_KB` (default `2000000`, already read): its row as a host key. All three are host keys
(`~/.canccu/config` only).

### H4. `WORKER_SKILLS`, `REVIEW_SKILLS`, `HEALTH_CHECKLIST`
The skill sentences of the prompts become settings. `WORKER_SKILLS` defaults to empty, so no
third-party plugin is named; this host sets today's sentence in `~/.canccu/config`.
`REVIEW_SKILLS` defaults to the code-review and security-review skills. `HEALTH_CHECKLIST` defaults
to today's checklist text. Test: the prompts with the defaults name no `superpowers`, and with
today's sentence set they match today's text word for word (the last AC of #14).

### H5. `MERGE_METHOD` (default `squash`)
`MERGE_METHOD` is already an internal variable in `lib/canccu-github.sh`: the method the repo
allows, read each pass. It is renamed `MERGE_FLAG`, and `MERGE_METHOD` becomes the setting
(`squash|merge|rebase`). If the repo does not allow that method, the dispatcher uses the first
method the repo allows, as today, and says so once (`warn_once`). A merge queue still passes no
method. Test: auto-merge in a repo without a merge queue (`--auto --squash`), and with one.

### H6. `canccu-init`
It writes `USER_LOGIN` (from `gh api user` with the project's token) and `BASE_BRANCH`, and
refuses to finish with an empty login. Its text and `docs/repo-contract.md` call the merge queue
optional.

### H7. `canccu-dispatcher doctor`
It prints `host profile: <name>`, and one line per key that `~/.canccu/config` overrides (key,
profile value → host value). It also prints the last day's runs per issue with their cost, from
spend.log (the "Cheaper runs" point): an issue with more than 3 runs is marked.

### H8. Docs
`docs/hosts.md`: what a host decides (plan profile, caps, thresholds, models, paths, memory
guard, skills), with a Max and a Pro example. A row for each new key in
`docs/reference/config.md`, `docs/reference/hosts.md`, and a CHANGELOG upgrade note (max `CAP`
3 → 2; `WORKER_SKILLS` must be set to keep today's skill sentence).

## Size and files
About 1,200 changed lines with tests. `lib/canccu-runs.sh` (exempt) gets call sites only.
`lib/canccu-accepts.sh` grows to about 220 lines.

## Follow-ups seen, not in this package
- The "test-tier" defaults from #14's "Cheaper runs" section: no test-tier setting exists yet
  to set. The plan does only the doctor report.
