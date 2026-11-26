<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Release-reds and flaky checks

Part of the reference; the index is [`README.md`](README.md). The keys are in
[`config-runs.md`](config-runs.md).

A project's release workflow may file an issue when CI on the base branch is red, labelled
`RELEASE_RED_LABEL` (default `release-red`) and titled `release red at <sha7>`. Most such reds are
a flaky check or a registry or runner fault: a worker's whole investigation for nothing. So the
dispatcher reruns them first, by script, with no AI run.

## The rerun

- The commit comes from the title (`release red at <sha7>`), else from a full SHA in the body.
- The dispatcher lists the failed runs at that commit on `BASE_BRANCH` (`gh run list --commit`)
  and reruns their failed jobs once (`gh run rerun --failed`). The state is kept in
  `release-red/<n>` in the project's dir, so a later pass never reruns again.
- Until the rerun has ended, the issue is not taken as work, even when it is `ready`.
- No commit, no failed run, or no rerun that starts: logged, and the issue is ordinary work.
- A rerun not ended after `CI_WAIT_MIN` minutes: a comment, and the issue is ordinary work.

## The result

| Rerun | First run's logs | What happens |
|---|---|---|
| red | any | A comment (red again, with the first run's failure digest); the issue is ordinary work |
| green | a line `CI_INFRA_PATTERN` matches | A comment naming the line; the issue is closed; nothing is filed |
| green | no such line | Each failed check gets its `flaky: <check>` issue; a comment links them; the issue is closed |

## Flaky issues

One open issue per check, titled `flaky: <check>`. Its body's `Failures: <n>` line counts the
failures; each failure adds a comment with the commit, the job, the run links and the failing
lines. From `FLAKY_FILE_AFTER` failures (default `2`) it gets `ready`; the queue takes it after
every other ready issue. Closing it (the check fixed) starts the count again with a new issue.

The project's workflow and its tagging stay as they are: the next green push tags as usual.
