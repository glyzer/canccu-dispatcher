<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the limit is checked in `bin/tally` with the other checks of the count, before the store is touched.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "a count over 1000000 is refused" (fails before: the count was added).
Revert: plain revert
