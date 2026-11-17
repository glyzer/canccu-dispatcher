<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally add: a default step from TALLY_STEP

## Goal
Some counters always count in tens; typing the count every time is error-prone.

## Acceptance criteria
- [ ] `tally add <name>` without a count adds `$TALLY_STEP` when it is set, else 1.
- [ ] A bad `$TALLY_STEP` is refused like a bad count.
