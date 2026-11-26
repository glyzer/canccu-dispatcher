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
| `RELEASE_RED_LABEL` | `release-red` | An open issue with this label ("release red at <sha7>", filed by the project's release workflow) is not work until the dispatcher reran the failed jobs at that commit once ([`release-reds.md`](release-reds.md)). Empty: no rerun, such an issue is ordinary work |
| `CI_INFRA_PATTERN` | `toomanyrequests\|pull rate limit\|error pulling image\|failed to pull\|manifest unknown\|TLS handshake timeout\|i/o timeout\|connection reset by peer\|ETIMEDOUT\|ECONNRESET\|EAI_AGAIN\|Could not resolve host\|The runner has received a shutdown signal\|lost communication with the server` | A failed job's log line (`grep -iE`) that names an infrastructure error (a registry pull, a lost runner, a network timeout), not the code: a release-red green on its rerun is closed and nothing is filed |
| `FLAKY_FILE_AFTER` | `2` | A `flaky: <check>` issue gets `ready`, at the end of the queue, from this many failures of that check |
