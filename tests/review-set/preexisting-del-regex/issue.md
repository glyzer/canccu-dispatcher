<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally show: refuse a bad name

## Goal
`tally show 'Bad Name'` prints a counter that can never exist.

## Acceptance criteria
- [ ] `tally show <name>` with a name that is not valid (`docs/format.md`) prints `tally: bad name <name>` and exits 2.
- [ ] A test in `tests/store.sh`.
