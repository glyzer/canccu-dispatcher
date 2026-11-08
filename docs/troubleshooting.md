<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Troubleshooting

Start with the two checks that cover most problems:

- `canccu-dispatcher doctor [--project <name>]` prints one line per problem of the host, the
  install and each project (dependencies, links, `PATH`, the host profile, the logins, the
  reviewer token and its deny rule, the clone, the `gh` credential, the dispatcher lock, the
  snapshot's age, stale run locks) and `no problems found` when clean.
- `canccu-status [--project <name>]` says what the dispatcher is doing and why something waits.

The project's `dispatch.log` (`~/.canccu/projects/<name>/dispatch.log`) has one line per action
and, prefixed `  │ `, the raw output of the commands it ran. A run's own log and its exit report
are in `workers/` ([`reference/engine.md`](reference/engine.md)).

## Nothing happens

| You see | Why | Do |
|---|---|---|
| The dispatcher does nothing at all | `USER_LOGIN` is not set | Set it in `~/.canccu/config` |
| `TOKEN MISSING (…)` | The project's `gh` dir has no token | Log the dir in ([`reference/projects.md`](reference/projects.md#a-narrow-token-per-project)) |
| `TOKEN CANNOT REACH <repo> (…)` | GitHub refused the token (401, 403, 404): wrong owner, repo not selected, expired | Make a new fine-grained token for that repo and log the dir in again |
| `CREDENTIAL CHECK FAILED (…)` | GitHub did not answer (network, 5xx) | Nothing: checked again next pass |
| An issue is never started | It lacks `ready`, has an open blocker, is in a step that is not current, is of the one-at-a-time kind while another is open, or the caps are full | `canccu-dispatch --dry-run` shows the queue and why each issue waits |
| "paused" | `canccu-pause` | `canccu-resume` |
| "usage limit until <time>" | A run hit the Claude usage limit | Nothing: it resumes after the reset ([`reference/usage.md`](reference/usage.md)) |
| "draining (weekly N%)" | The weekly share passed `USAGE_WEEKLY_DRAIN` | Nothing new starts until it drops; raise the threshold if you accept the risk |
| `could not start …: TOTAL_CAP (…) runs over all projects are running` | Another project uses the slots | Wait, or raise `TOTAL_CAP` in `~/.canccu/config` |
| `canccu-up: session … exists but canccu-dispatch is not running` | The session outlived its dispatcher | Start it in window `dispatch`: `canccu-dispatch --project <name>` |
| The monitor says "dispatcher not running?" | No snapshot for 3 passes | Look at the window `dispatch`; `doctor` names a lock held by another process |

## Reviews

| You see | Why | Do |
|---|---|---|
| `REVIEWS BLOCKED: …` | The reviewer token file is missing or not mode 600 | `install -m 600 /dev/null ~/.canccu/reviewer-token`, paste the bot's token |
| `reviews refused: the reviewer token signs in as '…', not REVIEWER_LOGIN …` | The token belongs to another account, or was revoked | Put the bot's own token in the file; check `REVIEWER_LOGIN` |
| `no CI checks on PR #<n>` | No CI ran on the PR: no workflow, or a path filter skipped it | Add a CI check that runs on every PR ([`repo-contract.md`](repo-contract.md)) |
| `review-gate` fails with "REVIEWER_LOGIN is not set" | The repo variable is missing | Set the repo variable `REVIEWER_LOGIN` |
| `review-gate` stays red after a pass verdict | The comment was edited, the head moved, or the base branch changed | The dispatcher reviews the new head; never edit a verdict comment |
| `no valid verdict (…)` | The reviewer's file did not end in a verdict for that head | The issue goes to `needs-you`; `canccu-review <pr>` runs it again |
| `post failed …` | GitHub refused the bot's comment | Check that the bot is a collaborator and accepted the invitation |

## PRs that wait

| You see | Why | Do |
|---|---|---|
| `awaiting accept (manual: …)` | The classifier's first reason ([`reference/merging.md`](reference/merging.md)) | Label the PR `accepted`, or `canccu-ship <n>` |
| `AUTO-MERGE OFF: …` | `AUTO_MERGE_UNTIL` is set to something that is not a date, or has passed | Fix or clear it in the project's rules |
| A PR listed as "not ours" | A fork, another author, another branch name, or an issue the dispatcher does not manage | Expected: the dispatcher never touches it |
| `needs-you` after a merge was armed | No merge within `MERGE_WAIT_MIN`, or someone disabled auto-merge | Look at the merge queue and the required checks |

## Runs

| You see | Why | Do |
|---|---|---|
| `stalled: no output for 10m, killed` | A hung command (a server, a watch mode, an unbounded wait) | Answer on the issue to resume it; teach the repo's `CLAUDE.md` to bound waits |
| `stopped: turn budget …`, `cost budget`, `time budget` | The run reached its budget | Comment to resume (a resume has its own budget), or raise `BUDGET_*` |
| `blocked` | Claude Code's permission checks refused a command | Run it yourself or widen the allow list, then comment to resume |
| `stale run lock … (no process or window of it)` | A run died without cleaning up | Harmless: the next start of that run clears it. Or remove the file `doctor` names |
| A worker's question keeps coming back | `ANSWER_MAX` rounds were used | Answer it yourself in a comment |

## The install

`install.sh --check` names every missing or too old tool with how to get it. A command on `PATH`
that runs an older install: `doctor` says so, and `install.sh --replace-links` replaces old links
([`install.md`](install.md)). After an upgrade, a dispatcher keeps its old release until you
restart it ([`upgrading.md`](upgrading.md)).
