<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# AGENTS.md

Rules for every change to this repo, by a person or an agent. `CLAUDE.md` holds the
`<n>` / `execute` / `finish` flow and the local check.

## The plan

`docs/plan/` is the baseline until release 1.0: the rules every change keeps, the package order
and the shared formats (`docs/plan/contracts.md`). Read `docs/plan/README.md` and the part of the
release file your issue's package has before you build. Use a name, default, text or format that
`contracts.md` fixes as written. Never edit `docs/plan/` as part of another issue: write a
`Roadmap note:` in the PR body instead.

## Comment rule

Comment the why: reasons, invariants, traps, what a reader would otherwise get wrong. Never the
what the code already shows. A comment that only restates the next line goes.

## File-size rule

About 400 lines at most per source file. Split a file that grows past it along its seams.
Exempt: `tests/`, `docs/`, fixtures, and every file listed with a reason in
`.file-size-exemptions` (one `<path> — <reason>` line each). The files already over the limit at
import are listed there; a split takes a file off the list.

## Tests

- Every behaviour change comes with a test that failed before it.
- While working, run only the tests of the files you change: `tests/run <file or pattern>`
  (for example `tests/run dispatch` or `tests/run lib/canccu-usage.sh`).
- Run the full local check (`tests/run`) **once**, just before pushing.
- Never paste whole test logs into the conversation: `tests/run` prints a one-line summary per
  file and only the failing checks, and names the file with the full log.
- Tests and fixtures use invented names only (projects `web` and `tools`, repos
  `example-org/web` and `example-user/tools`, users `octo` and `review-bot`, dates in 2030).
  Never a real person, organisation, host or other project.

## Docs

The reference is split into short per-topic files under `docs/reference/` (the index:
`docs/reference/README.md`). Read only the topic your change touches, and update only that topic
when a behaviour changes; the guides in `docs/` change only when a step a user takes changes. A
new config or rules key gets its row in `docs/reference/config.md` or `docs/reference/rules.md`
(`tests/canccu-docs.sh` fails without it).

## No personal data

Nothing in the repo names a person, an organisation, a host or another project, and no file
holds an absolute home path. Text the tool posts to GitHub shows paths under `$HOME` as `~/…`.
`tests/leak-check.sh` checks the working tree (`--history`: every commit too) against a private
deny-list that is never committed (`CANCCU_LEAK_WORDS`, else `~/.config/canccu-leak-words`).

## Branches

Branch updates merge main into the branch (`git merge origin/main`, then a normal push). Never
rebase or force-push a PR branch: the squash-merge flattens it anyway, and a blocked force-push
stops a run.

## Licence headers

Shell, Python, YAML and Markdown sources start with an SPDX line
(`SPDX-License-Identifier: AGPL-3.0-or-later`; after the shebang in scripts). JSON fixtures and
`lib/canccu-monitor.requirements.txt` carry none: `REUSE.toml` covers them.

## PR body

In this order:

- one `Closes #<n>` line per issue;
- `Package: <name>` (a work package's name; `-` for a single issue);
- `Risk: low|normal|high — <reason>`;
- `Tier: fix|feature|plan`;
- `Decisions made:` the implementation choices the issue left open (names, libraries already in
  the stack, error handling, test shape), one per line; the reviewer checks them;
- `Next action: <what comes next>`;
- `Verification run: <the checks run, with their result>`;
- any `Follow-up: <work outside the issue>` and `Roadmap note: <a change to the plan>` lines.
