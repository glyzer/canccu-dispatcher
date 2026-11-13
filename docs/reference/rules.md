<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Rules

Part of the reference; the index is [`README.md`](README.md). The other keys are in
[`config.md`](config.md).

## Rules

A project's rules decide how its PRs are gated and reviewed. They live in
`~/.canccu/projects/<name>/rules`, on the dispatcher's host and never in the repo, so a PR can
never change its own gating. A project without a rules file refuses to run.

`canccu-init` copies `profiles/default/rules`, which leaves every key commented out: such a key
keeps its value from `~/.canccu/config`, else from `lib/canccu-config.default`. So a rules key in
the global config is a default for every project whose rules leave it commented out. The
project's `config` is read after its rules and still wins over them; put rule values in `rules`.

Patterns are extended regular expressions. `grep -iE` ignores case; `grep -E` does not. They are
matched against each changed path of the PR, relative to the repo root (a rename counts by its
old path too).

| Key | Default | Meaning |
|---|---|---|
| `RISKY_PATHS` | `.github/`, `deploy/`, migrations, sign-in, login, auth, rights, permissions, sessions, secrets, tenancy, RLS | `grep -iE` on the changed paths: the full review of a PR without a risk class (a single issue) runs at high effort; a package's review follows its risk class ([`reviews.md`](reviews.md)) |
| `EFFORT_DOCS_PATHS` | empty | `grep -E`: paths that count as docs for the full review's effort, on top of `docs/` and `*.md`, even when `RISKY_PATHS` names them (for example `^contracts/` when the contracts are specs). Never a gated path or agent configuration |
| `FIXCHECK_RISKY` | `deploy/`, sign-in, login, auth, rights, permissions, sessions, secrets, tenancy, RLS, migrations, `*.sql`, schemas | The same for a fix-check's fix diff: medium instead of low effort |
| `GATED_PATHS` | `^\.github/` | `grep -E`: a PR touching one waits for your accept ([`merging.md`](merging.md)). Agent configuration (`.claude/`, `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, at any depth) is always gated on top |
| `USER_VISIBLE_PATHS` | empty | `grep -E`: a PR touching one always waits for the product owner, with the reason `users see it: <path>` (below, "User-visible paths"). Locked |
| `TEST_PATHS` | `(^\|/)(tests?\|__tests__\|spec)/\|\.(test\|spec)\.[a-z]+$` | `grep -E`: test files. A path it matches never counts as user-visible |
| `SECURITY_REVIEW_WHEN` | sign-in, rights, sessions, secrets, tenancy/RLS or `deploy/` | Words in the reviewer's prompt: it also runs the security-review skill when the diff touches these |
| `PLANNER_EXTRA` | empty | The project's guidance for the planner, for example "aim for 2-4 issues per package" |
| `REVIEW_EXTRA` | empty | More for the reviewer to check: "Check every acceptance criterion, <this>, and …" |
| `WORKER_EXTRA` | empty | More worker prompt text, after "… resumes you when it is red." |
| `ANSWER_READ` | `AGENTS.md` | What the answerer reads besides the issue and the PR |
| `ANSWER_READ_ALSO` | empty | … and, after the PR, "and <this>" |
| `AUTO_MERGE_UNTIL` | empty | Optional freeze date, `YYYY-MM-DD`: from this date every PR waits for your accept. Set to anything that is not a real date, it makes every PR manual |
| `EXCLUSIVE_LABEL` | empty | Optional one-at-a-time lock: an issue with this label does not start while another such managed issue is open |
| `EXCLUSIVE_PATTERN` | empty | `grep -E`: … nor one whose body or plan on `origin/main` matches this |
| `EXCLUSIVE_WORKER_RE` | empty | `grep -iE`: the run engine's own check on the issue's JSON (title, body, labels): it refuses a second such run in the repo |
| `ADD_DIRS` | empty | Extra read-only dirs for workers (`--add-dir`), space-separated |
| `REVIEW_CHECKS` | `review-gate` | Checks that wait for the review verdict themselves: left out of "CI green" before the review. The merge queue and the ruleset still require them |
| `HIGH_RISK_PATHS` | the same as `RISKY_PATHS` | `grep -iE` on the health pass's diff: it is high risk (manual accept) when it touches one |
| `HIGH_RISK_TEXT` | migrations, sign-in or auth, rights, sessions, secrets, tenancy/RLS, `deploy/` or CI configuration | High-risk content in words: the planner gives it a package of its own, the reviewer raises a package's `Risk:` line for it |
| `PING_KINDS` | `all` | Which states ping `USER_LOGIN` ([`pings.md`](pings.md)): `all`, or some of `accept checkpoint plan question needs-you pr-needs-you`; empty: none. An unknown word pings nothing and is logged once |

## User-visible paths

A PR that changes what users see (pages, screens, wording, step briefs) waits for the product
owner's accept, whatever its risk. `USER_VISIBLE_PATHS` names those paths; empty (the default)
switches the rule off. The first changed path it matches that `TEST_PATHS` does not is the
reason: `manual: users see it: web/pages/a.tsx`. A change to a page's tests alone stays
technical. Gated paths and agent configuration are checked first: their reason wins.

Step briefs, for example:

```sh
USER_VISIBLE_PATHS='^docs/briefs/'
```

`USER_VISIBLE_PATHS` is locked: the leader and the runs cannot change it. `TEST_PATHS` is open.

## Writing good rules

- Start from the defaults; add the repo's own sensitive dirs (contracts, schemas, setup
  scripts) to `RISKY_PATHS` and `HIGH_RISK_PATHS`, and the ones only you may change (release
  config, host scripts) to `GATED_PATHS`.
- Keep `REVIEW_EXTRA` to checks a reviewer can verify from the diff and the docs ("contract
  changes are additive, migrations non-destructive").
- `AUTO_MERGE_UNTIL` is the brake for a release freeze: from that day every PR waits for your
  accept, without touching the rest of the rules.
