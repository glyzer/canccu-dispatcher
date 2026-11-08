<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The lead

Part of the reference; the index is [`README.md`](README.md).

## The lead's session

The lead is an interactive `claude` session in the left pane of window `main`, which `canccu-up`
starts in `~/code` with the project's `gh` login ([`projects.md`](projects.md)). The dispatcher
does not start, wake or watch it: it is your own session, used to turn ideas into issues the
pipeline can run and to clear what waits for you. Nothing the lead does bypasses the pipeline:
its PRs, if any, are reviewed and gated like a worker's.

## Writing issues

An issue is the worker's spec and the reviewer's checklist, so write it for both:

- `## Goal`: what changes for whom, in two or three sentences;
- `## Acceptance criteria`: checkboxes a reviewer can verify from the diff and the tests;
- `## Out of scope`: what a worker must not do, so it neither creeps nor asks;
- a last line `Risk: low|normal|high — <why>`.

Label it `ready` once you agree with it; until then the dispatcher lists it under "waiting for the
product owner" in `canccu-status` and never starts it. `blocked` plus a `Blocked by #x` line (or a
GitHub blocked-by link) holds it until #x closes; the dispatcher then swaps the label for `ready`.

## Steps and epics

A roadmap step is a milestone whose title starts with its number (`1 Skeleton`, `2 Contracts`);
"Parallel tracks" runs beside the main track. Each step has:

- an **epic** (label `epic`) whose sub-issues are the step's issues; an `Order: #a → #b` line
  orders them in the queue. The dispatcher posts the step's plan there and labels it `needs-you`
  when the step needs the lead;
- optionally a **checkpoint** issue (label `checkpoint`): the step pauses there after its health
  pass until you label it `checkpoint-ok` or close it ([`steps.md`](steps.md)).

An issue with no milestone, or labelled `fast`, runs alone in the fast lane.

## What waits for you

The monitor's NEEDS YOU box and `canccu-status` list it; pings tell your phone
([`pings.md`](pings.md)). Each item says how to clear it:

| Item | How |
|---|---|
| A plan-tier plan | Read `docs/plans/issue-<n>.md` in the draft PR; label the issue `plan-ok`, or comment |
| An escalated question | Answer it in a comment on the issue: the worker resumes with it |
| An accept | Label the PR `accepted`, or `canccu-ship <n>` |
| A checkpoint | Read the summary; label `checkpoint-ok`, or close it |
| `needs-you` (CI red, no PR, a failed run) | Read the latest comments; comment to resume the worker, `needs-work` with your comments, or fix it yourself |
| An invalid plan, the step budget | Comment on the epic and remove `needs-you` to plan again; raise `STEP_BUDGET` |

`Follow-up:` and `Roadmap note:` lines from the step's PRs land in the digest and the checkpoint
summary: the lead turns the ones you want into issues.
