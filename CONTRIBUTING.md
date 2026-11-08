<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Contributing

Thanks for helping. This repo is run by canccu-dispatcher itself: a dispatcher picks up issues
labelled `ready`, a worker opens the PR, an independent reviewer reviews it, and it merges when the
review passes and CI is green. The same rules hold for a PR by hand.

Read [`AGENTS.md`](AGENTS.md) (the rules for every change: comments, file size, tests, branches,
the PR body) and [`CLAUDE.md`](CLAUDE.md) (how a session works on an issue) first.

## Issues

An issue is the agreed spec: the worker builds what it says, and the reviewer checks its criteria.
Use the templates (feature, bug, idea). A feature or bug issue has:

- `## Goal`: what changes, for whom, and why, in a few sentences;
- `## Acceptance criteria`: checkboxes a reviewer can verify from the diff and the tests;
- `## Out of scope`: what the change must not do;
- a last line `Risk: low|normal|high — <why>`.

An idea is a direction to discuss, in the same shape: it is planned, not worked on, and becomes
a feature once its acceptance criteria are agreed. Only the maintainer labels an issue `ready`.

## The local check

`tests/run` runs all of it, in parallel, with a one-line summary per part and the full log in a
file it names: `bash -n` and `shellcheck` on every shell file, every `tests/*.sh` (the docs test
and the leak check too), and `bin/canccu-monitor --self-test`. While working, run only what your
change touches: `tests/run <file or pattern>`, or `tests/run --affected`. Run the full check once
before you push; CI runs the same command on the newest runner and on Debian 12.

Tests and docs use invented names only (projects `web` and `tools`, repos `example-org/web` and
`example-user/tools`, users `octo` and `review-bot`, dates in 2030). `tests/leak-check.sh` checks
that nothing names a real person, organisation, host or home path.

## Docs

The reference is split by topic under [`docs/reference/`](docs/reference/README.md). Read and
update only the topic your change touches. A new config key needs its row in
`docs/reference/config.md` or `docs/reference/rules.md`: `tests/canccu-docs.sh` fails without it.

## Commits and PRs

- Commit messages: `type(scope): what changed`, lower case, for example
  `fix(dispatch): keep the accept when the update is clean`. Types: `feat`, `fix`, `docs`,
  `test`, `ci`, `chore`. The body says why.
- Small commits; never commit secrets, personal paths or names.
- Branch `<n>-<slug>` from `origin/main`. To bring in main, merge it; never rebase or force-push a
  PR branch. PRs are squash-merged.
- The PR body follows [`AGENTS.md`](AGENTS.md#pr-body): `Closes #<n>`, `Package:`, `Risk:`,
  `Tier:`, `Decisions made:`, `Next action:`, `Verification run:`.
- Never merge your own PR, and never add or remove the `accepted` label: the reviewer and the
  maintainer do.

Licence: contributions are AGPL-3.0-or-later; files under `templates/` are 0BSD.
