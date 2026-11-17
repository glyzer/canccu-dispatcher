<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally rename: a counter under a new name

## Goal
A counter with a typo in its name can only be removed and counted again.

## Acceptance criteria
- [ ] `tally rename <old> <new>` moves the counter's count to the new name.
- [ ] It fails, changing nothing, when `<old>` does not exist or `<new>` does.
- [ ] A test in `tests/store.sh`.
