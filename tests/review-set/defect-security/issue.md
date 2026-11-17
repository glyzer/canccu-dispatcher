<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally import: add the counters of a backup file

## Goal
A backup of the counters file (or one from another machine) cannot be added back.

## Acceptance criteria
- [ ] `tally import <file>` adds each counter of a file in the counters format (`docs/format.md`) to the store.
- [ ] A test in `tests/store.sh`.
