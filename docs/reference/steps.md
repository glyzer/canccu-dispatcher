<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Steps

Part of the reference; the index is [`README.md`](README.md). How a step's issues become
packages is in [`packages.md`](packages.md).

## The current step

A step is a milestone; its work issues are the ones that are neither `epic` nor `checkpoint`.
The **current step** is the first *pending* milestone in milestone order (the leading number of
its title): it has open work issues, or an open checkpoint, or its step is planning, running,
waiting for or in its health pass, at its checkpoint, or needs the lead. Earlier steps are done.
A milestone named "Parallel tracks" is a second current step whenever it is pending; its
checkpoint gates nothing else. Only current steps run packages. An empty step with an open
checkpoint is current and idle: later steps wait.

**Cross-step blockers.** An open work issue of the current step blocked by an open issue of a
later step would stall it: the step's epic gets `needs-you` with one comment per pair (`step
<title> waits on #x in step <title>`), so the lead can move the issue.

## Health pass

When every work issue of the step is closed and some work was done, one health package
(`pkg-<m>-health`, `BUDGET_HEALTH`) works through a fixed checklist on the files the step's PRs
touched: files over the size limit split up; dead code for dropped features and old names
removed; comments follow the comment rule; duplicated logic merged; no behaviour change; no
`Closes` line. Its rules come from the target repo's `AGENTS.md` ([`../repo-contract.md`](../repo-contract.md)).
It is `normal` risk, `high` when its diff touches `HIGH_RISK_PATHS`. Nothing to change: no PR
and the line `Health: nothing to do`. Once per step. It runs on `HEALTH_MODEL` at `HEALTH_EFFORT`
(empty: `MODEL` and the account's default effort) and ends with a short report for the lead.

## Checkpoint

After the health pass, the step's checkpoint issue (labelled `checkpoint`) gets `needs-you` and
one summary comment: the packages with their risk classes and PRs, the health PR, the spend
against `STEP_BUDGET`, the roadmap notes and follow-ups. The step stays current, so no package of
the next step starts, until you label the checkpoint `checkpoint-ok` (the newest such label
event must be by `USER_LOGIN`, after the summary) or close it; the dispatcher then closes it and
the step is done. The fast lane runs on during the pause. A step without an open checkpoint
skips the pause. The step's epic closes once the step is done and its sub-issues are closed.

## Stops

What the dispatcher does not handle on its own stops the step: a finished package's issue
reopened in the step, a done step's checkpoint reopened, a done step with new open work, or its
epic closed while it runs. Nothing of the step starts; its epic (else its checkpoint) gets
`needs-you` and one comment with what it found. The step goes on by itself once the lead sorted
it out (closed or moved the issue, closed the checkpoint, reopened the epic).

## Notes

`Follow-up:` and `Roadmap note:` lines of the step's package PRs are kept once per text in
`steps/<m>.notes`, and listed in the digest, the checkpoint summary, the snapshot and
`canccu-status`. The dispatcher never creates issues from them: the lead does, with you.

## Step budget

`STEP_BUDGET` (USD) covers the exact costs (`workers/spend.log`) of the step's planner, package,
review, fix-check, answerer and health runs since the step became current. Runs without a
reported cost (stopped at a budget, stalled or crashed) are counted apart. At the limit no new
run of the step starts (running ones finish) and the epic gets `needs-you` once; raising
`STEP_BUDGET` clears it on the next pass. The fast lane is not charged.
