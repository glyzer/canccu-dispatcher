<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Releases

The steps of a release. `.github/scripts/release` holds the checks; `tests/canccu-release.sh`
tests them.

1. On a release branch, set `VERSION` to the new version and give `CHANGELOG.md`'s section a
   date: `## [<version>] — <YYYY-MM-DD>`.
2. Run the scenario suite on the branch's head
   ([`scenarios.md`](scenarios.md)): `tests/scenarios/run --repo <owner/sandbox>`. It must
   exit 0. On a sandbox without a merge queue (a repo a user owns), `queue-removal` prints
   `SKIP no merge queue` and the other eight must pass.
3. Open the release PR. Its body carries the line `Scenarios: pass at <short sha>`, the head
   the suite passed on. When the diff since the last tag touches the review prompt, REVIEW.md
   handling, `lib/canccu-verdict.sh` or `REVIEW_MODEL`'s default, run the reviewer's test set
   too ([`review-set.md`](review-set.md)), and the body also carries `Review set: pass at <short
   sha>`. CI runs `release check v<VERSION> --body <the PR body>` on a PR that changes `VERSION`:
   a body without a needed line is red.
4. Once it is merged, tag the merge commit `v<VERSION>` and push the tag. `release.yml` checks the
   tag against `VERSION` and the changelog, runs the local check, builds the tarball and
   `SHA256SUMS`, and publishes the GitHub release with the changelog section as its notes.
