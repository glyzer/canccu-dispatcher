<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Config: CI, release-reds and the narrow runs

Part of the reference; the index is [`README.md`](README.md). The other project keys, how to
change a setting and the settings table are in [`config.md`](config.md); the rules keys in
[`rules.md`](rules.md).

## Keys

| Key | Default | Meaning |
|---|---|---|
| `CI_WAIT_MIN` | `90` | A finished worker's PR whose CI is still pending after this many minutes goes to `needs-you` |
| `NO_CHECKS_MIN` | `10` | A finished worker's PR with no CI check reported at all after this many minutes goes to `needs-you` ("is CI set up for this repo, or did a path filter skip it?"; for a PR that conflicts with main, which GitHub runs no checks on: "it conflicts with main, so GitHub runs no checks; merge main into it or say how") |
| `CI_DIGEST_PATTERN` | `FAIL\|✗\|×\|AssertionError\|Error:\|error TS[0-9]+\|##\[error\]\|^[[:space:]]+[0-9]+:[0-9]+[[:space:]]+error` | What a red CI's fix run is given ([`pipeline.md`](pipeline.md)): a digest of every failing job's log, built by script, each job under its name and link. It has each line this pattern (`grep -E`) matches with its next 8 lines (up to where the next step starts), and the test and lint summary lines (`Tests … failed`, `✖ N problems`) first. ANSI codes, timestamps, compose output, container teardown and Actions' `##[error]Process completed with exit code` line are left out. A job whose log has no match gives its last `CI_LOG_LINES` (default `60`) lines, as before the digest; empty: the tails only |
| `CI_DIGEST_LINES` | `120` | At most this many lines in that digest, over all its failing jobs: each job gets its share, its summaries and first failures first |
