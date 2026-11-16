<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Kickoff: planning a new project

A template for the planning session that starts a new project, before the first issue. Copy the
template into the project's own docs, fill it in with the product owner, and turn the step ladder
into milestones ([`reference/lead.md`](reference/lead.md#steps-and-epics)). The question bank
below helps fill each part; skip what does not apply. The gate kinds are in [`gates.md`](gates.md).

## The template

### Vision

One paragraph: what the project is, the problem it solves, and what is different once it exists.
One sentence of what it is not.

### Users

Who uses it, one line each: the role, what they want from it, how often they use it. Name the
primary user: when two users' needs clash, theirs wins.

### Their experiences

For each user, the two or three moments that matter, from their side: what they do, what they see,
what tells them it worked. These become the steps' acceptance criteria.

### Quality bar

What "good enough to ship" means here: correctness, speed, accessibility, the platforms and
versions supported, the documentation a user needs. Say what is deliberately left rough.

### Constraints

What is fixed before any code: the language and stack, licences, hosting, budgets (money, the
Claude account's usage), deadlines, data the project may not hold, the systems it must work with.

### The step ladder

The steps in order, each a milestone titled with its number (`1 Skeleton`, `2 Import`). Per step:

| Step | Goal (what a user can do once it is done) | Gate kind |
|---|---|---|
| `1 Skeleton` | … | functional |
| `2 …` | … | functional + UX |

Each step ends at its checkpoint; its gate says what proves it done ([`gates.md`](gates.md)). Keep
the first step small: a running skeleton with CI, so every later step is reviewed and merged the
same way.

## Question bank

### Vision

- What does a user do today instead, and what is wrong with it?
- What would make this project a failure even if every feature works?
- In a year, what is the one thing it must do well?

### Users

- Who pays, who uses, who maintains? Are they the same people?
- Who is not a user, though they might think they are?
- How technical is the primary user? What do they already know?

### Their experiences

- Walk through a user's first ten minutes. Where would they get stuck?
- What is the most frequent task? The most important one? Are they the same?
- What does a user do when something goes wrong, and what do they see?

### Quality bar

- Which failure is worse: a wrong answer or no answer?
- How fast is fast enough, on which hardware or network?
- Which platforms, browsers or versions must work on day one?
- What documentation does a user need before they can start?

### Constraints

- Which parts of the stack are decided, and which are open?
- Which licences may dependencies have?
- What data may the project store, and where? Who may see it?
- What is the budget per step, and what happens when a step runs over?

### The step ladder

- What is the smallest step a user could try?
- Which step carries the most risk? Can it come earlier?
- Which steps need a gate beyond the functional one, and who accepts it?
- Is any step long-running enough for cadence rounds ([`reference/steps.md`](reference/steps.md#cadence-rounds))?
