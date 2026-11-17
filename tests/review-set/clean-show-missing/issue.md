<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally show <name>: an unknown name is an error

## Goal
`tally show plums` prints `plums 0` for a counter that never existed, which hides typos.

## Acceptance criteria
- [ ] `tally show <name>` of a name with no counter prints `tally: no counter <name>` on stderr and exits 1.
- [ ] The test of the old behaviour changes with it.
