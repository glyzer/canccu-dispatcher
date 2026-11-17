<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- `--all` removes the file itself: an empty store and no file mean the same (`store_get` and `store_list`).
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "reset --all removes every counter" (fails before: --all is a bad name).
Revert: plain revert
