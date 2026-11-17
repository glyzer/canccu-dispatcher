<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The counters file

`$TALLY_FILE` (default `~/.tally`) holds one line per counter: the name, a tab, the count.

- A name is lowercase letters, digits and `-`.
- A count is a whole number, 0 or more.
- The lines are sorted by name.

Other tools read this file: the format is a contract.
