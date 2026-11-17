<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally sub: take a count off a counter

## Goal
`tally add` only counts up; a counter that was counted too far cannot be corrected.

## Acceptance criteria
- [ ] `tally sub <name> [n]` takes n (default 1) off the counter.
- [ ] A counter never goes below 0: a `sub` past 0 leaves it at 0.
- [ ] A test in `tests/store.sh`.
