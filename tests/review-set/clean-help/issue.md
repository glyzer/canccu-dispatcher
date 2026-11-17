<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# tally help: print the usage

## Goal
The usage is only printed after a mistake, on stderr, with exit 2.

## Acceptance criteria
- [ ] `tally help` prints the usage on stdout and exits 0.
- [ ] An unknown command still prints it on stderr and exits 2.
- [ ] Tests in `tests/store.sh`.
