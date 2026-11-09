<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Upgrading

An upgrade installs a new release beside the old one and switches `current` to it
([`install.md`](install.md)). It never touches `~/.canccu`. A running dispatcher, and every run it
started, keeps the release it started from until it is restarted, so an upgrade is safe at any
time; the sequence below makes the switch clean, with no project running two releases at once.

## The sequence

For each project (`--project <p>`; the examples use the project `web`):

1. **Pause**: `canccu-pause --project web`. No new issue, package or planner starts; running
   runs go on.
2. **Stop** the dispatcher: in its window `dispatch`, press Ctrl-C while the pane is quiet,
   between passes (a pass that is reaping or starting runs is busy; wait for its log lines to
   end). A paused dispatcher still starts reviews and resumes for work in flight; a stopped one
   starts nothing. The runs keep going in their own windows.
3. **Wait** until no run is left: `canccu-status --project web` lists none under running, and the
   monitor's NOW is empty. A run that must not wait can be stopped with `canccu-stop <n>`
   (`canccu-run <n>` continues it later).
4. **Install** the new release, from its tarball or checkout: `./install.sh` (with the same
   `--prefix` as before, if you gave one). It names any process still on an older release.
5. **Restart** the dispatcher in its window: `canccu-dispatch --project web`. Its first pass reaps
   the runs that finished while it was stopped. The monitor in the right pane picks up the new
   release when you restart it too (Ctrl-C, then `canccu-monitor --project web`).
6. **Resume**: `canccu-resume --project web`.

Then check: `canccu-dispatcher --version`, and `canccu-dispatcher doctor` prints `no problems
found` (it names a process left on an older release).

## Before you upgrade

- Read the release's `CHANGELOG.md` entry. A new config key gets its default by itself, as long
  as your `~/.canccu/config` leaves it commented out ([`reference/config.md`](reference/config.md)).
- A new rules key is not added to an existing project's `rules` file: copy the line from
  `profiles/default/rules` when you want to change it.
- A host profile (`HOST_PROFILE`) pins the plan-dependent values, so a changed default does not
  move them.

## Going back

`canccu-dispatcher rollback` points `current` at the previous release; run the same sequence
around it. The last three releases are kept, and a release a live dispatcher or run uses is never
pruned.
