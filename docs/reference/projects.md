<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Projects and narrow tokens

Part of the reference; the index is [`README.md`](README.md).

## Projects

A project is one GitHub repo the tool works on. Each lives in `~/.canccu/projects/<name>/`: its
`config`, `rules` and state ([`state.md`](state.md)). At the top of `~/.canccu/` are the
global files: `config`, `reviewer-token` (one bot for all projects), `default-project`, `backoff`
(a usage limit belongs to the shared Claude account, so it stops every project) and
`.engine.lock`.

- **Choosing one.** `--project <name>` as the first argument of any `canccu-*` command but
  `canccu-init`, or `CANCCU_PROJECT`; else the name in `~/.canccu/default-project`; else the only
  project. Otherwise the command refuses and lists the projects.
- **One dispatcher per project**, each with its own lock (`.dispatch.lock`), `dispatch.log`,
  `workers/` and tmux session: `canccu` for the default project, `canccu-<name>` for the others.
  `canccu-up --project <name>` creates the session with `CANCCU_PROJECT=<name>` in every pane, so a
  command typed there acts on that project.
- **One repo, one project.** Two projects on one repo would both adopt, review and merge its PRs;
  two on one clone would share its worktrees. `canccu-init` refuses both. Never run the same repo
  from two hosts either ([`../hosts.md`](../hosts.md)).
- **Caps.** A project's runs stay under its `CAP`, and all projects' runs together under
  `TOTAL_CAP`. A pass counts every project's live runs, and every engine start checks `TOTAL_CAP`
  again under `~/.canccu/.engine.lock`, so two dispatchers starting at once, or a `canccu-run` by
  hand, cannot pass it. The projects share the `TOTAL_CAP` slots by need (next section).

## Fair share of TOTAL_CAP

A project alone may fill every slot of `TOTAL_CAP` (its own `CAP` stays its bound). Once another
project has work it cannot start for want of a slot, the busy one **yields at its next phase
boundary**: a run of it that ends (a worker, review, fix-check, answerer or planner) frees a slot
it does not take again while the other one waits, so the slot passes to the waiting project.
Nothing running is stopped.

- **The wait.** Every pass writes the project's `want` file ([`state.md`](state.md)): the units
  it could not start because the shared slots were taken or owed (runnable fast-lane issues up to
  its `CAP`, a review, fix-check, answerer or resume, every startable package of a step, its
  planner or health pass). A unit held back by the project's own `CAP`, or by its own
  reservations while a shared slot is free (a review or answerer of its own about to start,
  [`pipeline.md`](pipeline.md)), does not count, nor does a run that would not start in a free
  slot either (its step at `STEP_BUDGET`, a review while reviews are refused), nor a start that
  failed for another reason. With no slot free at all the
  fast lane reads only its first runnable issue (each one costs a blockers read on GitHub): the
  wait grows again on a later pass. The wait holds for two `INTERVAL`s and five minutes, so the
  wait of a dispatcher that stopped ends by itself (a dispatcher that exits removes it at once). A
  pass that ends early (no credential, a `gh` error, a pass that dies) writes no wait; a dry run
  writes nothing. A pass by hand (`canccu-dispatch --once`) writes its wait like the loop, and
  it holds for the same time: while that project's dispatcher is stopped, the others yield to it
  until then.
- **The share.** Free slots go to the waiting projects with the fewest runs first: a project with
  `r` runs owes every other waiting project with fewer runs the slots that bring it up to `r` (at
  most its wait, never past its `CAP`), and may start only while free slots remain after those.
  **On a tie** (as many runs) the project that started a run last owes the other one a slot
  (`last_start`; by name when both started at the same moment): exactly one of two tied projects
  yields, so no slot stays idle. A project with work and no run therefore gets the next freed
  slot, also when the busy project's ending run leaves the two level; three projects with work and
  three slots get one each.
- **No daemon.** The decision reads only the projects' run locks and `want` files. Each start
  checks it again under `~/.canccu/.engine.lock`, so two dispatchers deciding at once never pass
  `TOTAL_CAP`, and a start by hand (`canccu-run`, `canccu-review`) yields too: `could not start …:
  the free slot goes to <project>, which waits for one`. The engine exits 75 when it refuses a
  start for want of a shared slot (`TOTAL_CAP`, the usage cap or the share); the pass then counts
  that unit, and the rest of the fast lane or of the step's packages, as waiting.
- `canccu-status` of a waiting project says `waiting for a slot held by <project>`: the projects
  that owe it a slot (more runs, or as many and started last), busiest first.

## Adding a project

1. `canccu-init [--profile <template>] <name> <owner/repo> [clone]`. It writes
   `~/.canccu/projects/<name>/config` (`REPO`, `CLONE=~/code/<repo>` or the absolute path given)
   and `rules` from the template (`default`, or your own in `~/.canccu/profiles/<template>/`;
   a template that names a repo must be for this one), creates the dispatcher's labels in the
   repo, and prints a checklist. It refuses, writing nothing, when the project exists, when
   another project runs the repo, or when another project uses the clone. When it adds a second
   project and there is no `default-project`, it records the first one as the default, so that
   one keeps the `canccu` session. It never changes rulesets, secrets, variables or
   collaborators, never creates or reads a token, and starts nothing.
2. By hand, as the checklist says (the target repo's side is in
   [`../repo-contract.md`](../repo-contract.md)):
   - add the reviewer bot as a collaborator with write access; the bot accepts the invitation;
   - set the repo variable `REVIEWER_LOGIN`;
   - add the review-gate workflow and its script from `templates/repo/` through a PR;
   - make sure a CI check runs on every PR (and on `merge_group` with a merge queue);
   - require CI and `review-gate` in a ruleset on the default branch;
   - clone the repo to `CLONE` and review the rules ([`rules.md`](rules.md));
   - create the project's narrow token and log its config dir in with it (below).
3. `canccu-dispatch --project <name> --dry-run`, then `canccu-up --project <name>`.

**Merging without auto-merge.** The dispatcher uses auto-merge when the repo allows it
(`allow_auto_merge`, read once per pass). Otherwise (for example a private repo on a free plan)
it merges directly, under the same pins ([`merging.md`](merging.md)). The log says
`auto-merge enabled` or `merged directly`.

## A narrow token per project

Each project uses its own fine-grained GitHub token, so no run (dispatcher, worker, reviewer,
fix-check, answerer or planner) holds a credential that reaches another repo or the repo's
administration. A fine-grained token belongs to one resource owner: projects under two owners
need two tokens. The reviewer bot's token is separate: the dispatcher uses it only to post
verdicts and pings.

**Create the token** (`canccu-init` prints the same steps): github.com → Settings → Developer
settings → Personal access tokens → Fine-grained tokens → Generate new token. Resource owner: the
repo's owner. Repository access: *Only select repositories* → the project's `REPO`. Repository
permissions, exactly:

| Access | Permissions |
|---|---|
| Read and write | Contents, Issues, Pull requests, Workflows |
| Read-only | Actions, Commit statuses, Metadata |
| No access | everything else: **no Administration, no Secrets** |

Workflows write with Contents write still lets a run push a workflow, and a workflow that runs
can read the repo's Actions secrets. Keep secrets that matter in environments with required
reviewers, so a pushed workflow cannot reach them.

**Log the project's config dir in with it**, then delete the token file:

```sh
install -m 600 /dev/null ~/.canccu/projects/web/gh-token   # paste the token into it
install -d -m 700 ~/.canccu/projects/web/gh
GH_CONFIG_DIR=~/.canccu/projects/web/gh gh auth login --with-token --insecure-storage < ~/.canccu/projects/web/gh-token
GH_CONFIG_DIR=~/.canccu/projects/web/gh gh api repos/example-org/web -q .full_name   # prints the repo
rm ~/.canccu/projects/web/gh-token
```

`--insecure-storage` keeps the token in that dir's `hosts.yml` (mode 600). A keyring entry is
stored per host and account, not per config dir, so two projects would overwrite each other's.
Another dir works too: set `GH_CONFIG_DIR=<path>` in the project's config.

**How it is used.** The tools export the dir as `GH_CONFIG_DIR` and drop any `GH_TOKEN` or
`GITHUB_TOKEN` from the environment (`gh` would prefer those). Git reaches GitHub through `gh`'s
credential helper for that dir, set through git's environment config (never a config file), and
`git@github.com:` remotes are rewritten to `https://github.com/`, so an ssh clone pushes with the
project's token too. Every run gets the dir and that git config in its tmux window. Only the path
travels: the token never appears in an environment, a command line, a log, the state or the
snapshot.

**The check before each pass.** The dispatcher checks that the dir's `hosts.yml` holds a token
(it looks for the key, never reads the value), then that `gh api repos/<REPO>` answers. Problems:
`TOKEN MISSING`, `TOKEN CANNOT REACH <repo>` (HTTP 401, 403 or 404), or `CREDENTIAL CHECK FAILED`
(no answer: network, 5xx). The pass then does nothing for that project, logs the problem once,
and writes the snapshot with `ok: false`; `canccu-status` and the monitor show it. Other
projects keep running.

A project without a config dir starts no run: the default `gh` login reaches every repo of the
host's user, so running on it is a choice, not an accident. The pass logs once, and the snapshot
and `canccu-status` say, `this project has no gh login of its own (GH_CONFIG_DIR); set one up
(canccu-dispatcher doctor shows how) or set ALLOW_DEFAULT_GH_LOGIN=1`; `canccu-dispatcher doctor`
names each such project with the steps above. With `ALLOW_DEFAULT_GH_LOGIN=1` in its config it
runs on the default login, and `canccu-status` warns: `no gh config dir for project <name>`. Once
no project runs on it, you can `gh auth logout` the default login and revoke a classic token.

**The lead's session** uses the same dir: `canccu-up` starts every pane with the project's
`GH_CONFIG_DIR` and git config, so the lead's `gh` and `git push` use the project's token. A
session that already exists keeps its environment: export `GH_CONFIG_DIR` in a pane by hand, or
end the session and run `canccu-up` again.
