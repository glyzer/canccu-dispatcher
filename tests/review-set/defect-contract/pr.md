<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the note lives in the counters file itself, so a counter and its note can never come apart.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "add --note keeps the note" (fails before: --note is taken for nothing).
Revert: plain revert
