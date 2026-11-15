<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# A project's dir

Part of the reference; the index is [`README.md`](README.md). The state's format and a unit's
fields are in [`state.md`](state.md). Every file in `~/.canccu/projects/<name>/`:

| Path | What |
|---|---|
| `config`, `rules` | [`config.md`](config.md), [`rules.md`](rules.md) |
| `gh/` | The project's own `gh` login (`hosts.yml`, mode 600) ([`projects.md`](projects.md)) |
| `state/<K>` | One file per unit the dispatcher manages (`<n>`, `pkg-<m>-<name>`, `pkg-<m>-health`), `key=value` lines ([`state.md`](state.md#a-units-state)) |
| `steps/<m>` | A step's state, with `steps/<m>.keys` (its run keys, for its budget), `.packages` (one line per finished package), `.notes` (follow-ups and roadmap notes), `.plan-<w>.json` (each wave's plan) and `.plan-<w>.rejected.json` |
| `workers/` | The run engine's state: locks, logs, `.last` reports, session ids, worktrees, `usage.json`, `spend.log`, `.nudge` files ([`engine.md`](engine.md)) |
| `reviews/<pr>/<sha>.md` | A reviewer's review of that head, which the dispatcher posts; `<sha>.findings.md` the full review's findings for the fix-check (or, after your `needs-work` on a fix-check's open items, those items and your comments, rebuilt each time from `<sha>.open.md`, the open items that fix-check left); `reviews/<pr>.sha`, `.mode`, `.effort` and `.model` what the PR's latest reviewer works on, at which effort and on which model, and `.light` the head its light review ran on ([`review-depth.md`](review-depth.md#the-light-review)) |
| `reviews/<pr>/history` | The PR's blocking findings, one tab-separated line per finding left after the dispatcher's demotions, for each verdict acted on: `<sha> <class> <file> <line or a-b> <open\|fixed\|answered>`. A fix-check marks each `open` line it does not raise again `fixed`; an accept, or a `needs-work` that starts a new cycle, marks every `open` line `answered`. Rewritten whole, never half ([`findings.md`](findings.md#no-repeats)) |
| `reviews.log` | One tab-separated line per posted verdict (contracts §8), append only: `<time> <pr> <sha> <full\|fixcheck> <pass\|changes> <b> <n> <p> <demoted> <classes>`: UTC time, the kind (a post-pass check is `fixcheck`), the effective verdict, the blocking findings left, the count line's non-blocking and pre-existing numbers, the findings moved out of `Blocking:`, the blocking classes left (comma-separated, or `-`) ([`findings.md`](findings.md)) |
| `followups` | One tab-separated line per wave (`step-<m>-wave-<w>`, `step-<m>-health`, `fast`): the issue its non-blocking review findings go to ([`reviews.md`](reviews.md)) |
| `handoffs/<K>.md` | The handoff a run stopped by the usage limit ended with, for the fresh session after the reset ([`usage.md`](usage.md#after-the-reset)) |
| `questions/<K>.txt` | The question a worker stopped with, for its answerer |
| `pings/<n>` | The state issue n was last pinged for ([`pings.md`](pings.md)) |
| `digest/<date>.md` | The daily digest |
| `merged.log` | One line per merged PR of a managed issue: time, issue, PR, how (`auto`, `accepted`, or `by hand` when the dispatcher did not arm it), title |
| `workers/spend.log` | One tab-separated line per run, written when it ends ([`state.md`](state.md#the-spend-log)) |
| `accepts.log` | One tab-separated line per `canccu-ship` accept, written before it merges: the epoch, the unit (`<n>` or `pkg-<m>-<name>`), the PR, the head sha it accepts, the actor (`po`, or `leader` with `CANCCU_ACTOR=leader`) ([`merging.md`](merging.md#the-accept-channels)) |
| `answers.log` | One line per question an answerer answered, with the link to its comment |
| `want` | The project's wait for a shared slot, rewritten by every pass: `n` (the runs it could not start for want of a slot of `TOTAL_CAP`; 0: none), `cap` (its `CAP`), `until` (the epoch the wait holds to); removed when the dispatcher exits ([`projects.md`](projects.md#fair-share-of-total_cap)) |
| `last_start` | When the project's engine last started a run (ns since the epoch): the fair share's tie rule |
| `state.format` | The format of `state/` and `steps/`: one number ([`state.md`](state.md#the-state-format)) |
| `dispatch.log` | One line per action, each starting with its UTC time (`2030-11-05T12:00:00Z`; lines written by an earlier release have the host's local time, `2030-11-05 12:00:00`, and readers accept both), plus the raw output of the commands (prefixed `  │ `) |
| `events`, `heartbeat` | The feed, one line per event a person must act on, and the file every pass touches ([`lead.md`](lead.md#the-feed)) |
| `feed.open` | `<key>=<id>` of the open feed items no unit's state holds (holds, checkpoints, PRs labelled `needs-you`), and `leader_ack=<id>`: the highest line the leader acknowledged |
| `.running` | Present while the dispatcher loops; one left at its start means a stop it did not plan |
| `dispatch.pid`, `.dispatch.lock` | The running dispatcher and its lock |
| `paused` | Present while paused: empty for `canccu-pause` (no new run at all), `finish` for `canccu-pause --finish` (work in flight goes on) ([`pipeline.md`](pipeline.md#one-pass)) |
| `gh_limit` | The epoch until which passes pause for a GitHub rate limit ([`pipeline.md`](pipeline.md#one-pass)); removed when it has passed |
| `pace` | `since=<epoch>` while the project is ahead of the week with `PACE` on ([`usage.md`](usage.md#pacing)) |
| `.disk-low` | Present while free space is below `DISK_MIN_MB`, so the hold is logged once |
| `status.json` | The status snapshot, written after every pass ([`snapshot.md`](snapshot.md)) |
| `.warned-*` | The last recurring warning of a kind, so it is logged once |
| `blocked/<n>` | Issue `n`'s `blocked` was set by the dispatcher (a `waiting` run): the only kind it removes |
