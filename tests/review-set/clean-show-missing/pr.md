<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- a counter at 0 still exists (`store_has` looks for its line, not its count).
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "an unknown name: a message and exit 1" (fails before: it printed plums 0).
Revert: plain revert
