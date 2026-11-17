<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the total is computed in the store (`store_total`), so another command can print it too.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "the file is sorted" and "reset removes the counter" now expect the total line (they fail before).
Revert: plain revert
