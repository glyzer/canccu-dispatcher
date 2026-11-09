<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Multiple hosts

Each host runs its own install, its own state dir (`~/.canccu`) and its own projects. Hosts share
nothing but GitHub and, often, one Claude account and one reviewer bot.

## One repo, one host

**Never run a project for the same repo on two hosts.** Both dispatchers would adopt, review and
merge its PRs, and both could start a worker on the same ready issue. `canccu-init`
refuses a second project for a repo on one host, but nothing checks across hosts yet: keep a list
of which host runs which repo.

To move a project to another host:

1. On the old host, pause it and let every managed issue finish, or stop the ones that must wait
   (the [upgrade sequence](upgrading.md#the-sequence) up to "wait"). Leave no issue `in-progress`
   without a PR.
2. Stop its dispatcher for good, and end its tmux session. Keep or remove
   `~/.canccu/projects/<name>/`, but never start that dispatcher again.
3. On the new host, `canccu-init` the project and set up its narrow token and clone
   ([`reference/projects.md`](reference/projects.md)). An open PR of ours for an `in-progress`
   issue is adopted on its first pass.

## One Claude account on several hosts

- `TOTAL_CAP` caps the runs of one host. Give each host a share, so the sum fits the account.
- The usage throttle reads the account's usage shares from this host's runs only
  ([`reference/usage.md`](reference/usage.md)). The shares are the account's, so a host with recent
  runs sees the others' use too; a host that has not run for a while starts from an older reading.
- A usage-limit back-off (`~/.canccu/backoff`) stops only the host that hit the limit. The other
  host's runs hit it too and back off on their own.

## Host profiles

`HOST_PROFILE` in each host's `~/.canccu/config` picks the values that suit that host's Claude
plan: caps, budgets and the throttle ([`reference/config.md`](reference/config.md#host-profiles)).
Two hosts on different plans get different profiles.

## The reviewer bot

One bot serves every project on every host: each host needs `~/.canccu/reviewer-token` (mode
600, behind the Claude deny rule). A token per host is easier to revoke when one host goes. The
narrow project tokens are per project; a project that moves gets a new one on its new host, and
the old one is revoked.
