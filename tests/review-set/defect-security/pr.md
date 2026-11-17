<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the import reads the file line by line with `read`, no awk: the counts go through `store_set` like `add`'s.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "import adds the counts of a file" (fails before: no import command).
Revert: plain revert
