<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
Closes #7
Package: -
Risk: low — a small change to one command
Tier: fix
Decisions made:
- the step is read where the count's default is, so it is validated with the count.
Next action: review
Verification run: bash tests/store.sh — all ok
Testing: none: a one-line default; the existing add checks still pass.
Revert: plain revert
