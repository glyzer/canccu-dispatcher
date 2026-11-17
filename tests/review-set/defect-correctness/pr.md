<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the clamp at 0 is done in `bin/tally`, not in the store: the store keeps any count it is given.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "sub takes the count off" (fails before: no sub command).
Revert: plain revert
