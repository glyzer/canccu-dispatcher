<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Changelog

Every release of canccu-dispatcher, newest first. The version is in `VERSION`;
`canccu-dispatcher --version` prints it.

## [0.1.0] — unreleased

- The review gate as templates for a target repo (`templates/repo/`, 0BSD); this repo runs the
  same files. `canccu-init` points at them.
- CI: a second job, `CI (oldstable)`, runs the local check on Debian 12; the job `CI` also
  install-tests the release tarball. `release.yml` publishes a release from a `v*` tag.
- Issue templates (feature, bug, idea), a PR template, and Dependabot for the pinned actions.
- The installer: `install.sh` puts a release under `PREFIX/lib/canccu-dispatcher/releases/<version>/`,
  switches `current` to it atomically and links the commands into `PREFIX/bin/` (docs/install.md).
- `canccu-dispatcher --version`, `doctor`, `rollback` and `uninstall`.
- Host profiles (`HOST_PROFILE`, `hosts/<profile>.conf`); `hosts/max.conf` pins today's defaults.
- The version in `canccu-status`'s first line, in the status snapshot (`version`) and in the
  monitor's header.
- The dispatcher, run engine, monitor and tests, imported with neutral defaults.
