<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- one `usage` function for both: the two texts cannot drift apart.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "help prints the usage" (fails before: help was an unknown command).
Revert: plain revert
