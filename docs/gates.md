<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Gates: what proves a step done

A step ends at its checkpoint ([`reference/steps.md`](reference/steps.md)). Its gate is what the
product owner reads there before `checkpoint-ok`. Every step has the functional gate; the
[kickoff](kickoff.md) picks the others per step in the step ladder.

Each gate is either an **automatic check** (a CI workflow the project names, which must be green
on the step's last commit) or **evidence plus a person's accept** (an artefact the step produces,
which a named person reads and accepts at the checkpoint).

## Always: the functional gate

- The step's acceptance criteria are proven by tests: one test per criterion, each named in the
  step's report, so a reader can find the test behind a claim.
- The step's deep review passed, with its blocking findings fixed (the polish issue closed)
  ([`reference/steps.md`](reference/steps.md#deep-review-and-polish), `STEP_DEEP_REVIEW`).

## Chosen per step

### UX

A screenshot book of the step's screens and flows, the leader's evaluation of it against the
users' experiences, and the product owner's accept.

### API or library

The docs of every public name the step adds or changes, runnable examples, and a compatibility
check against the last release (an automatic check where the language has one).

### CLI or tooling

Scripted scenario runs with their transcripts: each documented command run as a user would, its
output kept with the step.

### Performance

Benchmarks against a budget the kickoff set (time, memory, size), run the same way each time; a
result over budget fails the gate.

### Security

A dependency audit, and a security-focused deep review of the step's change.

### Operations

A deploy rehearsal or a dry run on a setup like production, with its log, and the rollback tried.

### Data or AI

Evaluation scores against thresholds the kickoff set, on a fixed evaluation set, with the run
that produced them.
