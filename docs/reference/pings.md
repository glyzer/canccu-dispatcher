<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Pings

Part of the reference; the index is [`README.md`](README.md).

## Pings

You learn at once, on your phone, when something needs you: the dispatcher posts one comment as
`REVIEWER_LOGIN` that starts with `@USER_LOGIN`, so the GitHub mobile app sends a push (your own
comments notify nobody). No run, no Claude tokens. `PING=off` turns them off.

The rules' `PING_KINDS` names the states that ping: `all` (the default), or a list. For example
`PING_KINDS='accept checkpoint plan'` pings only what is yours alone to decide, and leaves
questions, CI and failed runs to the lead, who watches the monitor. A state of a kind left out is
not pinged, but stays in `needs-you`, `canccu-status` and the monitor. A word that is no kind
pings nothing and is logged once.

| State | When | The comment's line (on issue n) |
|---|---|---|
| `checkpoint` | An open checkpoint its step waits on, unless `USER_LOGIN` labelled it `checkpoint-ok` after the summary | @USER_LOGIN this checkpoint waits for your `checkpoint-ok`: read the summary (<link>), then label this issue `checkpoint-ok`, or close it. |
| `needs-you` | An open issue labelled `needs-you`, or a managed unit in phase `needs-you` whose label did not land | @USER_LOGIN this issue needs you (`needs-you`): the latest comments say why. |
| `plan` | … whose unit waits on a plan-tier plan, unless it is labelled `plan-ok` already | @USER_LOGIN the plan here waits for your OK: label this issue `plan-ok`, or comment. |
| `question` | … whose worker's question the answerer escalated | @USER_LOGIN the worker's question here needs the product owner: answer it in a comment. |
| `pr-needs-you` | Our open PR labelled `needs-you` (another PR: none) | @USER_LOGIN PR #<pr> needs you (`needs-you`): its latest comments say why. |
| `accept` | A unit in phase `accept` with its PR open and not labelled `accepted` yet | @USER_LOGIN PR #<pr> waits for your accept: label it `accepted`, or `canccu-ship <n>`. |

- **One ping per state.** `pings/<n>` holds the state last pinged. A later pass with the same
  state pings nothing; a pass without it removes the file, so the state coming back (or another
  one) pings again. An issue in two states counts the first row `PING_KINDS` lets through.
- **When.** Each pass, right after reading GitHub and before acting: a state set during a pass is
  pinged on the next one, at most `INTERVAL` seconds later. A state you already answered by label
  (`plan-ok`, `checkpoint-ok`, `accepted`) is not pinged.
- **Always on the issue** (a package's lead issue), never on a PR: the `review-gate` check reads
  the bot's comments there.
- **No content.** Fixed words, the numbers, your login and the checkpoint summary's link only:
  never a reason, a title, a question, a review, a run's output or a token. The comment carries
  `<!-- canccu-dispatch -->`.
- **The token.** A ping is posted like a review: the token reaches only that `gh` call. A missing
  token file (or one not mode 600) or a rejected post is logged once and nothing is recorded, so
  the ping goes out once the token works. A post that timed out may have landed: it is recorded,
  so the mention is never posted twice. A broken reviewer token silences pings too:
  `canccu-status` shows it.
- `--dry-run` prints `would: ping #<n> …` and records nothing.
