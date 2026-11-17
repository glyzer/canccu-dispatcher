<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the output is for people (`<name>: <count>`), not the counters file's format.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "add prints the new count" (fails before: add printed nothing).
Revert: plain revert
