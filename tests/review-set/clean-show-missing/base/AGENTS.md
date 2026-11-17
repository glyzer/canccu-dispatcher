<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# AGENTS.md

Rules for every change to tally.

- Every behaviour change comes with a test in `tests/store.sh` that fails without it.
- The counters file's format is a contract: `docs/format.md` fixes it, and the code writes it as
  written. A change to the format changes that file first.
- Run the tests with `bash tests/store.sh`.
