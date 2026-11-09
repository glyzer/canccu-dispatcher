<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Changelog

Every release of canccu-dispatcher, newest first. The version is in `VERSION`;
`canccu-dispatcher --version` prints it.

## [0.1.1] — 2026-11-09

Ports from the original dispatcher, and one new fix.

- An extra fix round now ends in a fix-check, not a new full review (#28, PR #48).
- Review effort follows the risk class (`EFFORT_DOCS_PATHS` adds paths that count as docs), and
  the review and fix-check models can be set per kind (`REVIEW_MODEL`, `FIXCHECK_MODEL`) (#30,
  PR #51).
- A fair share of `TOTAL_CAP` across projects: a project over its share yields at the next phase
  boundary (#16, PR #53).
- Large JSON values (issues, PRs, milestones, plans) reach jq as files, not arguments. Step logic
  no longer stops when a repo's open issues pass Linux's 128 KiB argument limit (#54, PR #55).

## [0.1.0] — 2026-11-09

The first public version.

- Import: the dispatcher, run engine, monitor and tests, with neutral defaults; host profiles
  (`HOST_PROFILE`, `hosts/<profile>.conf`) and the version in `canccu-status`, its snapshot and
  the monitor's header.
- Installer: `install.sh` installs versioned releases under a `PREFIX` and switches between them
  atomically (docs/install.md); `canccu-dispatcher --version`, `doctor`, `rollback` and
  `uninstall`.
- CI and release: the local check on the newest runner and on Debian 12, an install test of the
  release tarball, `release.yml` publishing a release from a `v*` tag, the review gate as
  templates for a target repo (`templates/repo/`), issue and PR templates, and Dependabot.
- Docs: a README to a first merged PR, guides in `docs/`, the reference in short per-topic files
  under `docs/reference/` (checked by `tests/canccu-docs.sh`), the repo-contract snippets,
  `CONTRIBUTING.md` and `SECURITY.md`.
