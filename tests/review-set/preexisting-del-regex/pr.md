<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the check reuses `valid_name`, the one `add` uses.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: `tests/store.sh` "show of a bad name: exit 2" (fails before: it printed the name with 0).
Revert: plain revert
