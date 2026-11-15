<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Releases

The steps of a release. `.github/scripts/release` holds the checks; `tests/canccu-release.sh`
tests them.

1. On a release branch, set `VERSION` to the new version and give `CHANGELOG.md`'s section a
   date: `## [<version>] — <YYYY-MM-DD>`.
2. Run the scenario suite on the branch's head
   ([`scenarios.md`](scenarios.md)): `tests/scenarios/run --repo <owner/sandbox>`.
3. Open the release PR. Its body carries the line `Scenarios: pass at <short sha>`, the head
   the suite passed on. CI runs `release check v<VERSION> --body <the PR body>` on a PR that
   changes `VERSION`: a body without the line is red.
4. Once it is merged, tag the merge commit `v<VERSION>` and push the tag. `release.yml` checks the
   tag against `VERSION` and the changelog, runs the local check, builds the tarball and
   `SHA256SUMS`, and publishes the GitHub release with the changelog section as its notes.
