<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Issue template

Every work issue uses these sections, in this order. Written so that a worker never has to guess.

## Goal
One or two sentences: what is true after the merge that is not true now, and for whom.

## Today (verified at <short sha> of main)
What the code does now, with file and function names. Only facts that were read in the code.

## Change
Numbered steps. Each names the file and function it touches and gives the fixed parts word for word:
setting names and defaults, state fields, log texts, comment texts, command syntax.

## Decided (do not reopen)
Choices already made, each with its one-line reason.

## Acceptance criteria
Checkboxes. Each is testable and names the test file it lands in.

## Out of scope
What a worker might be tempted to add, and which issue owns it instead.

## Docs
The doc files to change, and what to say.

## Depends on / Risk
Issues that must merge first. Risk: low | normal | high, with the reason.

## If the code disagrees
If a file, function or behaviour named here is not as described, do not improvise:
stop with a line starting `Question:` that says what differs.

## Notes for the writer

- Name the package (`Package: P1`) in the first line of **Depends on / Risk**.
- Risk uses the PR body's words: `low`, `normal`, `high`.
- A text a user will read (a comment, a log line, a message) is given in full, in backticks.
- Use invented names only, as `AGENTS.md` asks for tests.
