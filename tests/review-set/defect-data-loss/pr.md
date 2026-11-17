<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the rename rewrites the file in one awk pass; sorting keeps the file in name order (docs/format.md).
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "rename keeps the count under the new name" (fails before: no rename command).
Revert: plain revert
