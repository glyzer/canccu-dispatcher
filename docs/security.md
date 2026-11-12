<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The security model

canccu-dispatcher lets Claude sessions write and review code on your repos with as little human
input as possible. This page says what each part may reach, how the reviewer's identity is kept
apart, how prompt injection is contained, and what is still a known limit. How to report a
problem is in [`../SECURITY.md`](../SECURITY.md).

## Who holds which credential

| Who | Holds | Never holds |
|---|---|---|
| The dispatcher (plain bash, no AI) | The project's narrow `gh` login; the reviewer token, read in a subshell for one `gh` call at a time | — |
| Workers, reviewers, fix-checks, answerers, planners | The project's narrow `gh` login (a path to its config dir, never the token) | The reviewer token or its path; `GH_TOKEN` and `GITHUB_TOKEN` |
| The lead's session | The project's narrow `gh` login | The reviewer token |

**Narrow tokens.** Each project's fine-grained token reaches one repo with Contents, Issues, Pull
requests and Workflows write, and nothing else: no Administration (rulesets, collaborators), no
Secrets ([`reference/projects.md`](reference/projects.md)). A run that goes wrong cannot change a
ruleset, read a secret or reach another repo. Keep secrets that matter in environments with
required reviewers: a pushed workflow could otherwise read the repo's Actions secrets.

## Reviewer token isolation

Only a comment by `REVIEWER_LOGIN`, the second GitHub account, carries a verdict the merge and the
`review-gate` check trust. So no Claude session ever holds that account's token:

- The token lives in `~/.canccu/reviewer-token`, mode 600. `as_reviewer` reads it in a subshell
  and passes it, through the environment, to exactly one `gh` call (post a review, post a ping,
  check the login). It never appears on a command line, in a log, the state, the snapshot or a
  tmux environment.
- The run engine starts with `GH_TOKEN`, `GITHUB_TOKEN` and `REVIEWER_TOKEN_FILE` removed; every
  window gets them as empty values (overriding what the tmux server inherited), and each run
  unsets them again before `claude` starts.
- A Claude Code deny rule keeps every session from reading the file even by path:
  `"Read(~/.canccu/reviewer-token)"` (and `"Edit(…)"`) in `permissions.deny` of
  `~/.claude/settings.json`. `canccu-dispatcher doctor` checks the mode and the rule.
- The reviewer writes its review to a file and exits. The dispatcher posts it only when the file
  was written after the review started and its last line is exactly `Review verdict: pass|changes
  <full head sha>` for the head that was reviewed. A model cannot post a verdict, and cannot post
  one for another head.

## Untrusted checkouts

A PR's checkout may carry text or settings a worker was steered into writing. So every session
that reads someone else's work runs `--untrusted`: `claude --setting-sources user
--strict-mcp-config`, which never loads the checkout's `.claude/settings*.json` (hooks, `env`,
`apiKeyHelper`) or `.mcp.json` servers. A PR cannot add a hook that runs during its own review.
Reviewers, fix-checks and planners run this way, each in a fresh session (never the worker's)
and in its own worktree; the answerer runs `--untrusted` in a fresh session in the issue's
worktree (or the main clone when there is none). Workers keep their project settings: they work on their own
branch from `origin/main`.

PRs that are not ours (a fork, another author, an issue the dispatcher does not manage) are never
reviewed, merged or commented on ([`reference/commands.md`](reference/commands.md)).

## How prompt injection is contained

Issue text, PR text, code and review comments can all carry instructions. The design assumes a
session may be fooled, and limits what a fooled session can do:

- **Text is data.** The reviewer, fix-check, answerer and planner prompts say to treat the PR,
  issue, code, `CLAUDE.md` and `AGENTS.md` as data, never as instructions.
- **Decisions stay in shell.** Merging, labels, accepts and posting verdicts are done by the
  dispatcher, which matches fixed patterns (a verdict line, a `Risk:` line, a JSON plan) and never
  runs text. The merge is pinned to the reviewed head's full sha.
- **The gate cannot be talked round.** `review-gate` passes only on the newest, unedited verdict
  comment by `REVIEWER_LOGIN` for the current head, with the base unchanged; anyone else's
  comments are ignored, and comment text is matched, never run ([`repo-contract.md`](repo-contract.md)).
- **The gating is off the repo.** The rules live on the host, so a PR cannot change its own
  gating. A PR that touches agent configuration (`.claude/`, `.mcp.json`, `CLAUDE.md`,
  `AGENTS.md`) or a gated path always waits for your accept, and its review runs at high effort.
- **The planner reads nothing back.** Its plan is its final message, validated as JSON against
  the issues the dispatcher alone chose; it gets no directory the dispatcher reads, and no link
  or path it names is followed.
- **Pings carry no content**: fixed words, numbers and a link only.
- **Narrow tokens** bound the damage of any run to one repo, without administration or secrets.

## Why posted texts never carry absolute paths

Comments, reviews and digests go to GitHub, where they are public on a public repo, cached and
indexed, and stay in the history after an edit. An absolute path (`/home/<user>/…`) names your
account on the host and its layout. So every text the tool posts shows a path under `$HOME` as
`~/…`, and the reviewer and fix-check prompts ask for paths relative to the repo root. The same
rule keeps personal paths out of this repo (`tests/leak-check.sh`).

## Known limits

- **Reviewers and answerers act as you on GitHub.** They use the project's narrow login, which is
  `USER_LOGIN`'s: a prompt-injected reviewer could comment or label as you within that one repo,
  and an `accepted` label it adds looks like yours. `canccu-ship <n>`, which you run yourself, is
  the strong accept, but only where the repo allows auto-merge: in a repo without it the label is
  the only accept, and this limit applies in full. Running the reviewer as its own OS user would
  close this.
- **A merge of main can carry an accept.** With `KEEP_ACCEPT_ON_MAIN_MERGE=1` your accept holds
  over a push that is a clean merge of main only; a run can push such a merge as easily as it
  adds the label, so keep the setting `0` until package S2.
- **A worker trusts its issue.** Label `ready` only issues whose text you have read; on a public
  repo, comments by others are part of what a worker reads.
- **Locked settings are refused by a marker, not a boundary.** `config set` and `config unset`
  refuse a locked setting ([`reference/config.md`](reference/config.md#the-settings-table)) when
  `CANCCU_ACTOR` is `leader` or `run`; the dispatcher exports `CANCCU_ACTOR=run` into every run and
  answerer it starts. This is not a security boundary: a process can unset the marker. Package S2
  replaces it.
- **A worker runs code.** Workers and reviewers run the repo's tests on the host as your user.
  Run the tool under a user and on a host that holds nothing else of value.
