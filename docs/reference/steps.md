<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Steps

Part of the reference; the index is [`README.md`](README.md). How a step's issues become
packages is in [`packages.md`](packages.md).

## The current step

A step is a milestone; its work issues are the ones that are neither `epic` nor `checkpoint`.
The **current step** is the first *pending* milestone in milestone order (the leading number of
its title): it has open work issues, or an open checkpoint, or its step is planning, running,
in its deep review, waiting for or in its health pass, at its checkpoint, or needs the leader. Earlier steps are done.
A milestone named "Parallel tracks" is a second current step whenever it is pending; its
checkpoint gates nothing else. Only current steps run packages. An empty step with an open
checkpoint is current and idle: later steps wait. A step whose work issues are all closed is current
until its health pass has run, with or without a checkpoint issue (#278): its deep review and health
pass never depend on one.

**Cross-step blockers.** An open work issue of the current step blocked by an open issue of a
later step would stall it: the step's epic gets `needs-you` with one comment per pair (`step
<title> waits on #x in step <title>`), so the leader can move the issue.

## Health pass

When every work issue of the step is closed and some work was done, one health package
(`pkg-<m>-health`, `BUDGET_HEALTH`) works through a fixed checklist on the files the step's PRs
touched: files over the size limit split up; dead code for dropped features and old names
removed; comments follow the comment rule; duplicated logic merged; no behaviour change; no
`Closes` line. Its rules come from the target repo's `AGENTS.md` ([`../repo-contract.md`](../repo-contract.md)).
It is `normal` risk, `high` when its diff touches `HIGH_RISK_PATHS`. Nothing to change: no PR
and the line `Health: nothing to do`. Once per step. It runs on `HEALTH_MODEL` at `HEALTH_EFFORT`
(empty: `MODEL` and the account's default effort) and ends with a short report for the leader.

## Deep review and polish

With `STEP_DEEP_REVIEW=1` (the default), a step whose work issues are all closed gets a deep review before its
health pass: one worker run (`pkg-<m>-deep`, window `deep#<m>`, a fresh session on
`DEEP_REVIEW_MODEL`, else `REVIEW_MODEL`, else `MODEL`, at `DEEP_REVIEW_EFFORT` (`medium`, capped by `REVIEW_EFFORT_MAX`), budget
`BUDGET_DEEP_REVIEW`), charged to the step. The step's phase is `deep`: it stays current. The log
says `#pkg-<m>-deep started: the deep review of step <title>`. Its prompt names the base (the
tag matching `STEP_TAG` exactly, `{n}` as digits only, so no round tag, with the highest `{n}`
below the step's own number, since with parallel tracks a later step's tag can be newer; with none
below it, the step's merged PRs from `steps/<m>.packages`, since any other such tag is the step's
own or a later step's), the head it reads (`origin/main`'s sha, the step field `deep_head`), the
step's issues and its follow-up tickets (the `followups` key `step-<m>`, and the older `step-<m>-*`). It writes
`docs/reports/step-<n>-deep-review.md` (`<n>`: the leading number of the milestone's title, else
the milestone number) with the sections Architecture, Security, Contracts and Test quality, then
the finding block of contracts §8 ending in `Review verdict: pass|changes <deep_head>`, and opens
one PR with `Package: deep-review`, `Step: <title>`, `Risk: low — the step's deep-review report`
and no `Closes` line. That PR is reviewed and merged like any other (the package names `deep`
and `deep-r<r>` are reserved for it and its cadence rounds' branches, like `health`).

Once it merged, the dispatcher reads the report from `origin/main` with the review parsers:

- blocking items left: one issue in the step's milestone, labelled `ready`, titled
  `Step <title>: polish (deep review)`, with the items, the report and the PR. The step goes back
  to `idle` and the planner plans it like any issue. Logged as
  `step <title>: the deep review found <b> blocking finding(s); polish issue #<i> filed`. A create
  that prints no link: the issue is the newest open one with that exact title; none found is
  logged (`the polish issue was filed but gh printed no link …`) and the summary says `none`;
- none: `step <title>: the deep review found nothing blocking; the health pass follows`;
- the PR closed without merging: `#pkg-<m>-deep: PR #<pr> was closed without merging; the health
  pass follows`;
- no report on `origin/main` yet: one warning, read again each pass.

Once the step's work issues (the polish issue too) are closed again, the health pass and the
checkpoint run as before.

## Checkpoint

After the health pass, the step's checkpoint issue (labelled `checkpoint`) gets `needs-you` and
one summary comment: the packages with their risk classes and PRs, the health PR, the spend
against `STEP_BUDGET`, with `STEP_DEEP_REVIEW=1` the deep review
(`**Deep review:** PR #<pr>, <b> blocking (polish #<i> | none)`), the roadmap notes and follow-ups. The step stays current, so no package of
the next step starts, until you label the checkpoint `checkpoint-ok` (the newest such label
event must be by `USER_LOGIN`, after the summary) or close it; the dispatcher then closes it and
the step is done. The fast lane runs on during the pause. A step without an open checkpoint
skips the pause. The step's epic closes once the step is done and its sub-issues are closed.

**New work at the checkpoint** (#243). An open work issue in the step while it waits (your "not
yet, polish these first") takes it back to `idle`: the checkpoint's `needs-you` goes and the
planner plans that work like any. Once it is closed, the health pass and the checkpoint come
again, with a fresh summary; the deep review is not redone. Logged: `step <title>: new open work
at its checkpoint (#a, #b); back to planning`.

**Step tag.** With `STEP_TAG` set (locked: a tag push can start a release workflow; the default
`step-{n}`, `{n}` as above), the checkpoint OK fetches, tags `origin/main`'s head and pushes the
tag with the project's own login, as a merge of main is pushed. An existing tag is never moved.
Logged: `step <title>: tagged <tag> at <sha7>`, `step <title>: tag <tag> exists already; not
moved`, or `step <title>: tagging <tag> failed (<why>); tag it by hand`. A value without `{n}`, or
no valid tag name after it (`git check-ref-format`): no tag, one warning.

## Cadence rounds

A long-running step can be checked while it runs. With `CADENCE_DAYS` above 0 (project config; default 14),
a step whose milestone description has the line `Cadence: on` (any case; the title keeps its
ordering number) starts a **round** every `CADENCE_DAYS` days, counted from the end of the last
round (step field `cadence_at`), else from the step's start, while the step runs or is idle with
work open. Logged: `step <title>: cadence round <r> starts (every <D> days)`. A round:

1. with `STEP_DEEP_REVIEW=1`, the deep review of the section above, from the head of the last
   round whose report merged (a round whose PR closed unmerged keeps its own base; else the step
   tag below the step's, else the step's PRs) to `origin/main`, then its polish
   issue until that is closed. Its prompt says the step's work goes on: only merged work is
   reviewed, and open issues are no finding. A round whose PR closed unmerged goes on to its
   summary, which says `closed without merging`. Each round has its own branch `pkg-<m>-deep-r<r>` and report
   `docs/reports/step-<n>-r<r>-deep-review.md`, so its PR adds only its own report (the step's
   end keeps `pkg-<m>-deep` and `step-<n>-deep-review.md`);
2. the round's summary on the step's open checkpoint, with `needs-you` and a `checkpoint` line in
   the feed;
3. `checkpoint-ok` by `USER_LOGIN` after the summary ends it: the label and `needs-you` go, the
   checkpoint stays open, the comment `Cadence round <r> OK.`, the tag `<STEP_TAG name>-r<r>`
   when `STEP_TAG` is set, `cadence_at` now; logged `step <title>: cadence round <r> OK`. Closing
   the checkpoint ends the round too, and no further round starts until one is open. A
   checkpoint that is gone (its label removed, the issue transferred or deleted) ends the round
   as a close does, with one warning: `step <title>: cadence round <r>'s checkpoint #<c> is gone;
   the round ends`. The open checkpoints are read on their own (up to 500), apart from the
   newest 200 closed ones, so an old open checkpoint is never taken as gone.

The step's waves go on during a round; a round has no health pass. A round due while the step has
no open checkpoint is skipped (one warning) and starts once one is open. Once every work issue is
closed no round starts; one in progress ends first (also once `CADENCE_DAYS` is 0 or the
`Cadence: on` line is gone), then the step ends like any step (deep
review, health pass, checkpoint). Step fields: `round`, `round_phase` (`deep`, `read`, `polish`,
`checkpoint`), `round_head`, `round_from` (the head of the last round whose report merged: the next round reads from it), `round_pr`, `round_blocking`, `round_polish`, `round_cp`,
`round_cp_at`, `cadence_at`.

## Stops

What the dispatcher does not handle on its own stops the step: a done step's checkpoint
reopened, a done step with new open work, or its epic closed while it runs. Nothing of the step
starts; its epic (else its checkpoint) gets `needs-you` and one comment with what it found. The
step goes on by itself once the leader sorted it out (closed or moved the issue, closed the
checkpoint, reopened the epic).

A finished package's issue that is open again (reopened, or left open by its merged PR) does not
stop the step. To build it again, give it `ready` (and remove `needs-you`): the planner plans it
in the next wave like any other issue of the step. Without `ready` it waits for you.

## Notes

`Follow-up:` and `Roadmap note:` lines of the step's package PRs are kept once per text in
`steps/<m>.notes`, and listed in the digest, the checkpoint summary, the snapshot and
`canccu-status`. The dispatcher never creates issues from them: the leader does, with you. Put
follow-ups and review leftovers in the step's milestone, not the fast lane: the planner then
bundles them with the step's other issues of their area, where each one alone would pay a
package's review, CI, accept and merge.

## Step budget

`STEP_BUDGET` (USD) covers the exact costs (`workers/spend.log`) of the step's planner, package,
review, fix-check, answerer and health runs since the step became current. Runs without a
reported cost (stopped at a budget, stalled or crashed) are counted apart. At the limit no new
worker, resume or answer of the step starts (running ones finish; a fix run after a `changes`
verdict is a resume and waits too), and the epic gets `needs-you` once. Reviews, fix-checks and
merges of the step's open PRs go on, so the work already paid for is not left unreviewed. Raising
`STEP_BUDGET` clears it on the next pass, without a restart. The fast lane is not charged.
