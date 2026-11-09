<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# State

Part of the reference; the index is [`README.md`](README.md). The status snapshot's schema is in
[`snapshot.md`](snapshot.md).

## Where the state lives

Everything the tool keeps is under `~/.canccu` (or `CANCCU_ROOT`). The installed code lives
elsewhere (`~/.local/lib/canccu-dispatcher/`, [`../install.md`](../install.md)); an upgrade never
touches the state, and uninstall keeps it unless you pass `--purge-state --yes`.

| Path | What |
|---|---|
| `config` | The global config ([`config.md`](config.md)) |
| `reviewer-token` | The reviewer bot's token, mode 600, one for all projects |
| `default-project` | The project a command without `--project` acts on; it owns the tmux session `canccu` |
| `backoff` | The epoch until which nothing starts in any project (a usage limit) |
| `.engine.lock` | Held while a run starts, so `TOTAL_CAP` holds over all projects |
| `profiles/<template>/` | Your own project templates for `canccu-init --profile` |
| `projects/<name>/` | One project (below) |

## A project's dir

In `~/.canccu/projects/<name>/`:

| Path | What |
|---|---|
| `config`, `rules` | [`config.md`](config.md), [`rules.md`](rules.md) |
| `gh/` | The project's own `gh` login (`hosts.yml`, mode 600) ([`projects.md`](projects.md)) |
| `state/<K>` | One file per unit the dispatcher manages (`<n>`, `pkg-<m>-<name>`, `pkg-<m>-health`), `key=value` lines (below) |
| `steps/<m>` | A step's state, with `steps/<m>.keys` (its run keys, for its budget), `.packages` (one line per finished package), `.notes` (follow-ups and roadmap notes), `.plan-<w>.json` (each wave's plan) and `.plan-<w>.rejected.json` |
| `workers/` | The run engine's state: locks, logs, `.last` reports, session ids, worktrees, `usage.json`, `spend.log`, `.nudge` files ([`engine.md`](engine.md)) |
| `reviews/<pr>/<sha>.md` | A reviewer's review of that head, which the dispatcher posts; `<sha>.findings.md` the full review's findings for the fix-check; `reviews/<pr>.sha`, `.mode` and `.effort` what the PR's latest reviewer works on |
| `questions/<K>.txt` | The question a worker stopped with, for its answerer |
| `pings/<n>` | The state issue n was last pinged for ([`pings.md`](pings.md)) |
| `digest/<date>.md` | The daily digest |
| `merged.log` | One line per merged PR of a managed issue: time, issue, PR, how (`auto`, `accepted`, or `by hand` when the dispatcher did not arm it), title |
| `answers.log` | One line per question an answerer answered, with the link to its comment |
| `dispatch.log` | One line per action, plus the raw output of the commands (prefixed `  │ `) |
| `dispatch.pid`, `.dispatch.lock` | The running dispatcher and its lock |
| `paused` | Present while paused (`canccu-pause`) |
| `status.json` | The status snapshot, written after every pass ([`snapshot.md`](snapshot.md)) |
| `.warned-*` | The last recurring warning of a kind, so it is logged once |

## A unit's state

`state/<K>` holds, among others: `phase` ([`pipeline.md`](pipeline.md)), `pr`, `color` (its
palette index), `stage` (`review` → `fixing` → `fixcheck`), `reviewed_sha` (the head the full
review asked for changes on), `review_mode`, `review_sha`, `review_effort`, `review_maccept` (the
full review's `Maintainer accept:` reason), `posted` (the head whose review was posted),
`ny_kind` (what a `needs-you` waits for: `plan`, `question` or empty), `ny_stage` (where it
parked), `ny_wait` (`ci`: it only waited on CI), `exclusive` (of the one-at-a-time kind),
`accept_sha`, `merge_sha` and timestamps. A package adds `pkg`, `step`, `wave`, `members`,
`branch`, `risk`, `risk_reason`, `review_risk` and `health`.

Every write of a `state/<K>` or `steps/<m>` file goes through a temp file under the file's own
lock (`.<K>.lock` beside it), so the pass and a `canccu-ship`, `-stop`, `-run` or `-review` at the
same time never lose a key. The state of an issue goes when the issue closes.

`steps/<m>` holds the step's `phase` (`idle`, `planning`, `running`, `health-due`, `health`,
`checkpoint`, `done`, `needs-you`), `title`, `track` (`main` or `parallel`), `wave`, `plan`,
`left_out`, the needs-you reason, `health`, `health_pr`, `checkpoint` and the summary's link.

## Colour per issue

An issue gets a colour when it becomes managed or a run of it starts: the lowest free one of 6
ANSI 256 colours (33 blue, 208 orange, 135 purple, 37 teal, 205 pink, 142 olive; red, yellow and
green mean needs-you, waiting and merged). Issues running at the same time never share one while
`CAP` is 6 or less. The colour marks the issue in the monitor, in the dispatcher's pane and in
its windows' tmux status. `dispatch.log` stays plain; `NO_COLOR` turns colour off.
