<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Multiple hosts

Each host runs its own install, its own state dir (`~/.canccu`) and its own projects. Hosts share
nothing but GitHub and, often, one Claude account and one reviewer bot.

## One repo, one host

**Never run a project for the same repo on two hosts.** Both dispatchers would adopt, review and
merge its PRs, and both could start a worker on the same ready issue. `canccu-init`
refuses a second project for a repo on one host, and [the dispatcher claim](#the-dispatcher-claim)
keeps a second host's dispatcher from acting.

To move a project to another host:

1. On the old host, pause it with `canccu-pause --finish` (a plain pause would hold the work in
   flight too) and let every managed issue finish, or stop the ones that must wait
   (the [upgrade sequence](upgrading.md#the-sequence) up to "wait"). Leave no issue `in-progress`
   without a PR.
2. Stop its dispatcher for good, and end its tmux session. Keep or remove
   `~/.canccu/projects/<name>/`, but never start that dispatcher again.
3. On the new host, `canccu-init` the project and set up its narrow token and clone
   ([`reference/projects.md`](reference/projects.md)). An open PR of ours for an `in-progress`
   issue is adopted on its first pass.

## The dispatcher claim

Each repo has one issue titled "Dispatcher claim", labelled `dispatcher-claim` and pinned; the
first dispatcher to find none creates it. Its body names the host whose dispatcher runs the repo:

```
host: a1b2c3d4e5f60718
label: lab-1
at: 2030-11-05T12:00:00Z
```

- `host` is the host id, 16 random hex characters written once to `~/.canccu/host-id`. `label`
  is the host's `HOST_LABEL` (empty when unset), `at` the time of the last write. The body never
  holds a hostname, a path or a user name.
- Each pass reads the claim. Its own claim is renewed by an edit of the body (never a comment), at
  most every `CLAIM_RENEW_MIN` minutes (default 10). A claim older than `CLAIM_EXPIRY_MIN`
  minutes (default 30), or one with no host, is free: the next pass takes it.
- A clean stop of the dispatcher (Ctrl-C, or a TERM) releases the claim: it empties `host`.
- While another host's claim is fresh, this dispatcher does nothing for the repo. It says so once
  in its log, and `canccu-status`, the monitor and the snapshot (`pass.claim`) show it.
  `canccu-init` warns before it adds a claimed repo.
- `canccu-dispatch --take-over` prints whose the claim is and takes it for this host. Use it after a
  host move, when the old host is gone for good and you do not want to wait for the expiry.
- On a gh error reading or writing the claim, a dispatcher whose own claim is still fresh works on
  under it, until it would have expired; it never takes a foreign claim it cannot read.

The claim issue is not work: the queue and the product owner's list leave it out.
Leave it open; closing it only makes the next pass create another.

## One Claude account on several hosts

- `TOTAL_CAP` caps the runs of one host. Give each host a share, so the sum fits the account.
- The usage throttle reads the account's usage shares from this host's runs only
  ([`reference/usage.md`](reference/usage.md)). The shares are the account's, so a host with recent
  runs sees the others' use too; a host that has not run for a while starts from an older reading.
- A usage-limit back-off (`~/.canccu/backoff`) stops only the host that hit the limit. The other
  host's runs hit it too and back off on their own.

## What a host decides

One release runs unchanged on every host: what differs between hosts is a setting, never a value
in the code. Each host's `~/.canccu/config` decides:

- **the plan profile**, `HOST_PROFILE`: `max` or `pro`. It sets the caps, budgets, usage
  thresholds, run models, review effort and test tier (`TEST_TIER`: what a run tests locally) of
  that Claude plan
  ([`reference/hosts.md`](reference/hosts.md#host-profiles));
- **caps and thresholds** beyond the profile: `TOTAL_CAP` (this host's share of the account),
  `USAGE_SLOW`, `USAGE_STOP`, `USAGE_WEEKLY_DRAIN`;
- **the model**: `MODEL` and the other model keys, when the profile's split does not suit;
- **paths**: `CLONE_ROOT` (where projects are cloned and the panes start) and `EXTRA_PATH`
  (dirs a bare `PATH` lacks);
- **the memory guard**: `GUARD_VMEM_KB`, the memory cap of every `gh`, `jq` and `python3`
  call;
- **skills**: `WORKER_SKILLS` and `REVIEW_SKILLS` (below).

A project's own `config` still wins over the host's for every key but `TOTAL_CAP` and
`HOST_PROFILE`. `canccu-dispatcher doctor` prints the profile and each key the host's config
overrides.

### A Max host

```sh
# ~/.canccu/config
HOST_PROFILE=max
TOTAL_CAP=2                          # the profile's; lower it when another host shares the account
CLONE_ROOT=$HOME/code
EXTRA_PATH=$HOME/.local/bin:$HOME/.bun/bin
WORKER_SKILLS='Use the superpowers skills test-driven-development, systematic-debugging and verification-before-completion. On the plan tier use writing-plans for the plan, and executing-plans after plan-ok.'
```

### A Pro host

```sh
# ~/.canccu/config
HOST_PROFILE=pro                     # one run at a time, Sonnet workers, reviews at medium effort
CLONE_ROOT=$HOME/src
EXTRA_PATH=$HOME/.local/bin
GUARD_VMEM_KB=1500000                # a small machine
```

### Skills

The prompts name a skill only when the host has it. `WORKER_SKILLS` (default empty) is the
sentence the worker, package and health prompts and the plan-OK resume carry: empty, they name
none. A host with the [superpowers](https://github.com/obra/superpowers) plugin sets the sentence
the Max example shows, which is what every prompt said before the setting existed. The list of
skills a worker must not use (brainstorming, worktrees, subagents and the like) stays in every
prompt either way: the dispatcher owns those steps.

`REVIEW_SKILLS` (default `code-review security-review`) names the reviewer's two skills: the
first reviews the diff, in the full review and the fix-check; the second is the security review
its trigger asks for. Both defaults are Claude Code's own skills.

## The reviewer bot

One bot serves every project on every host: each host needs `~/.canccu/reviewer-token` (mode
600, behind the Claude deny rule). A token per host is easier to revoke when one host goes. The
narrow project tokens are per project; a project that moves gets a new one on its new host, and
the old one is revoked.
