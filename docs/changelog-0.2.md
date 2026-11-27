<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Changelog: 0.2

The 0.2.0 release of canccu-dispatcher. The newer ones are in
[`CHANGELOG.md`](../CHANGELOG.md), the 0.1 releases in [`changelog-0.1.md`](changelog-0.1.md).

## [0.2.0] — 2026-11-16

Release 0.2 ends here; its remaining packages move to 0.3 (#105).

**Upgrade:**

- The state format is now `3` and is upgraded at start. The upgrade changes no field, so a release
  older than this one refuses the upgraded state rather than drop the new fields (#216).
- `canccu-pause` now holds every new run, resumes, reviews, fixes and answers included; running
  runs finish and a passed review still merges. `canccu-pause --finish` keeps the old meaning: only
  new issues, packages, planners and health passes wait, work in flight goes on (#215).
- A project without its own `gh` login (`GH_CONFIG_DIR`, or `~/.canccu/projects/<name>/gh`) no
  longer runs on the host's default login: it starts no run until it gets its own login or its
  config sets `ALLOW_DEFAULT_GH_LOGIN=1` (new, default `0`, locked). `canccu-dispatcher doctor`
  names such projects with the steps (#173).

**New:**

- A head that passed review is never reviewed again: a `needs-work` answered with no push, or a
  pass read again, reuses the verdict; a `full review` line asks for a new one (#214).
- Workflow v2, every feature opt-in (off with the defaults) (#216):
  - `REVIEW_LIGHT` (rules, locked, default `0`): a package of class low or normal gets a light
    review, a checklist at low effort; a light verdict rated `Risk: high` gets a full review of
    the same head before it merges or starts a fix run.
  - `FIXCHECK_COUNT_RESOLVED` (locked, default `0`; with `FIXCHECK_COUNT_MAIN=0`): after a merge
    of main that conflicted, the fix-check counts only the hand-resolved lines and later commits.
  - `BUDGET_LINES` (default `0`: the issue count only): above 0, a package's budgets scale with its
    planned changed lines over this, still capped by `BUDGET_PACKAGE_MAX`.
  - `PACE` (default `off`; `notify`, `cap` or `pause`), `PACE_MARGIN` (default `10` points) and
    `PACE_CAP` (default `1` run): weekly pacing against the share of the week gone; while ahead,
    `pause` drains: no new issue or package starts and stopped runs wait, fix runs of started work
    go on. `canccu-status --pace` shows the reading, the mode and the spend of the last 7 days.
  - `STEP_DEEP_REVIEW` (default `0`): a step whose work is done gets a deep review of its whole
    change before the health pass; its blocking findings become one polish issue. Its model,
    effort and budget: `DEEP_REVIEW_MODEL` (default empty: `REVIEW_MODEL`, else `MODEL`),
    `DEEP_REVIEW_EFFORT` (default `high`), `BUDGET_DEEP_REVIEW` (default `150 40 120`).
  - `STEP_TAG` (locked, default empty: no tag): the checkpoint OK tags `origin/main`, `{n}` for
    the step title's leading number, else the milestone's (for example `step-{n}`); the next
    deep review starts from that tag.
  - `CADENCE_DAYS` (default `0`: no rounds): a step whose milestone description has the line
    `Cadence: on` gets a round every this many days while it runs: its deep review, polish and
    checkpoint summary.
  - The lead's toolkit: `canccu-dispatcher watch` waits for the next `dispatch.log` event, a new
    line of a `--file` or a stall, and `canccu-dispatcher stall` names stuck items
    (`docs/reference/lead-tools.md`). New guides
    `docs/kickoff.md` (a new project's planning session) and `docs/gates.md` (what proves a step
    done).
- The dispatcher decides what blocks a merge: the reviewer marks each finding with a class and
  `Evidence:`, and an item with a never-blocking class, no class or no `Evidence:` no longer
  blocks; a changed verdict says why in a `Dispatcher:` line. `reviews.log` gets one line per
  posted verdict, and a pre-existing `security` finding's follow-up issue gets the `security`
  label (`docs/reference/findings.md`) (#190).
- No repeats: a finding already fixed or answered on the PR, and one on lines unchanged since the
  PR's last pass (never `security`), no longer blocks. The history is in `reviews/<pr>/history`,
  and both review prompts carry it (#191).
- Issue, PR and milestone titles lose their control characters before they reach a terminal, the
  monitor or `dispatch.log`. `docs/security.md` states that the reviewer token's deny rule covers
  the session's own Read and Edit tools only (#173).
- `ACCEPT_CHANNELS` (locked, default `all`): the accepts that count, of `label` (the `accepted`
  label), `ship` (`canccu-ship`), `reply` (an answer comment, none yet) and `leader` (the leader's
  `canccu-ship`). `canccu-ship` writes an accept record before it merges, `canccu-status` shows the
  setting, and a comment made while the unit's run was live is no answer of the product owner's
  (#185).
- With `LEADER=on`, an item of the leader's not acknowledged within 60 minutes of its feed line
  passes to the product owner, with a feed line that says so; the leader acknowledges with
  `canccu-dispatcher wait --owner leader --ack <id>` (#183).
- `canccu-status --kpi`: per day of the last 7, the leader's tokens, the runs' test runs, the pings
  and the feed lines by owner. `TEST_CMD` (rules, default `tests/run`; empty: not measured) names
  the command whose calls a run counts and times, in the spend log's `tests=` and `test_secs=`
  (#188).
- The planner bundles at least `PACKAGE_MIN_ISSUES` issues per package where they fit together
  (default now `3`, was `1`) and puts the high-risk issues of one area together, apart from normal
  work. `PACKAGE_HOLD_SMALL` (rules, default `0`): `1` lets it hold a lone small leftover for a
  later wave's package of its area (#79).
- The monitor's ROADMAP keeps its package table with many blocked issues: the waiting cell names
  the main blockers then `+N more`, and done packages fold into one row (#76).
