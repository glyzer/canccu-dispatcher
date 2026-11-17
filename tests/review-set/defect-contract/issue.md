<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally add --note: keep a note with a counter

## Goal
A counter's name alone does not say what it counts.

## Acceptance criteria
- [ ] `tally add <name> [n] --note <text>` keeps the note with the counter; a later `add` without `--note` keeps it.
- [ ] `tally show <name>` prints the note after the count.
- [ ] A test in `tests/store.sh`.
