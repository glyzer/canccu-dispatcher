<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Changelog

Every release of canccu-dispatcher, newest first. The version is in `VERSION`;
`canccu-dispatcher --version` prints it.

## Unreleased

- A merge that fails on a GitHub server error (a 5xx, a timeout, a dropped connection) is tried
  again on later passes, up to `MERGE_RETRY` (default 3), before it needs you; a refusal still
  needs you at once. Removing `needs-you` from an accepted PR stopped at the merge, with no
  comment, tries the merge again (#130).
- Worker and reviewer prompts and `CLAUDE.md` call the person who accepts the product owner (#131).
- `canccu-dispatcher config set KEY=VALUE` and `config unset KEY` check a setting, write only its
  line (atomically, checked with `bash -n`), keep a `config.history` line, and refuse a locked
  setting to the leader and to runs, which now carry `CANCCU_ACTOR=run` (#109).
- `canccu-dispatcher config show [--project <name>] [--global] [--origin] [KEY…]` prints every
  setting with its value, its default and the file it comes from; `lib/canccu-settings.tsv` lists
  every setting's type, file and whether it is locked (#108).
- A host profile for a Claude Pro plan: `HOST_PROFILE=pro` (`hosts/pro.conf`) runs one thing at a
  time with small budgets and `REVIEW_EFFORT_MAX=medium`; it sets no model. The getting-started
  guide's paste block for a small plan is now that one line (#101).
- A merged PR that leaves an issue of its unit open no longer parks the unit for good: the issue
  gets `needs-you` and a comment, and the unit is released; `ready` builds it again from main. An
  issue its `Closes` names gets `MERGE_WAIT_MIN` to be closed by GitHub first. A finished
  package's issue that is open again no longer stops its step (#86).
- Contract-first PRs work for single issues: the issue's branch is kept in its state, and its
  prompt has the same contract rule as a package's. A PR that names no issue (no `Closes`, no
  `Plan for`) is never merged automatically, whatever its branch (#87).
- A contract-first PR that GitHub would treat as closing an issue never reaches a review or an
  accept: the worker is resumed once to correct its body, then `needs-you` (#98).
- A fresh follow-up run always keeps its safety rules: they come first in its prompt, and the
  handoff no longer repeats the whole first prompt. A fix round's long findings are read from the
  findings file. Workers use no subagents, packages included (#88).
- `REVIEW_EFFORT_MAX` (`low`, `medium` or `high`) caps the effort of every review and fix-check on
  the machine, gated paths and agent configuration included; empty, the default, changes nothing
  (#84).
- A running dispatcher reads its config files again at the next pass when one changed: a raised
  `STEP_BUDGET` applies without a restart. A syntax error keeps the old values; `REPO`, `CLONE`
  and `GH_CONFIG_DIR` still need a restart. A step at `STEP_BUDGET` still reviews, fix-checks
  and merges its open PRs; only new workers, resumes and answers wait (#65).
- A `plan-ok` or `needs-work` issue whose blocker is open no longer reserves a run slot: with one
  slot, a runnable issue starts instead (#69).
- An old usage reading no longer throttles: one older than `USAGE_MAX_AGE_MIN` (6 hours) or than
  the dispatcher's start counts as unknown, so a restart after an account switch ends a drain. The
  usage text shows the reading's age (#64).
- A failed GitHub read of a passed PR is tried again next pass (`retry:` from `canccu-classify`)
  instead of asking for an accept. A review's fix round and the resume after a merged contract PR
  wait for the end of a back-off without changing any state. A passed review's list of what it
  checked no longer counts as blocking findings in the spend log; the reviewer lists its blocking
  findings under `Blocking:`, and a `changes` review without that heading still counts its items
  before `Non-blocking:` (#94).
- A reviewer that ends `done` without a valid review file is asked once per head, in its own
  session, to write it; only a second miss goes to `needs-you` (#93).

## [0.1.2] — 2026-11-10

Fewer false alarms and wasted runs, plan-only PRs, and the repo's own merge method (PR #60).

- `blocked` is a hold: a labelled issue is never started or resumed. The dispatcher removes only
  a `blocked` it set itself. To wait on a dependency, use a `ready` issue with a blocked-by link
  instead. **Breaking:** a `blocked` that someone else set is no longer swapped for `ready` when
  its links close (#59).
- A worker that ends with no PR and a `Status: blocked` or `not started` line waits quietly
  (phase `waiting`, the dispatcher's own `blocked`), with no needs-you and no answerer. A run that
  ended with no PR starts a fresh session instead of resuming the old one (#59).
- Plan-only PRs: a PR is matched by its `Closes` lines, a `Plan for #n` line or its `<n>-…`
  branch. After a plan PR merges, its issues get `ready` and `plan-ok`, and the next start builds
  the merged plan (#46).
- Merges pass the repo's allowed method when it has no merge queue (squash, else merge, else
  rebase). A PR that has already merged counts as merged, not as a rejection (#45).

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
