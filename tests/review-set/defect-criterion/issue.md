<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally show: a total line, and the top counters

## Goal
With many counters, `tally show` gives no overview.

## Acceptance criteria
- [ ] `tally show` ends with a line `total<TAB><the sum of the counts>`.
- [ ] `tally show --top <k>` prints the k largest counters, largest first, and no total line.
- [ ] Tests for both in `tests/store.sh`.
