<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally add: refuse a count over 1000000

## Goal
A mistyped count (an extra digit or two) makes a counter useless.

## Acceptance criteria
- [ ] `tally add <name> <n>` with n over 1000000 prints `tally: count too big: <n>` and exits 2, changing nothing.
- [ ] A test in `tests/store.sh`.
