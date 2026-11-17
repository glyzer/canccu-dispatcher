<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Pings

Part of the reference; the index is [`README.md`](README.md).

## Pings

You learn at once, on your phone, when something needs you: the dispatcher posts one comment as
`REVIEWER_LOGIN` that starts with `@USER_LOGIN` and carries [the ask form](#the-ask-form), so the
GitHub mobile app sends a push (your own comments notify nobody). Only items whose owner is the product owner ping: one of owner `leader`
([`leader.md`](leader.md#the-owner-of-a-waiting-item)) is the leader's to read. No run, no Claude tokens. `PING=off` turns them off.

The rules' `PING_KINDS` names the states that ping: `all` (the default), or a list. For example
`PING_KINDS='accept checkpoint plan'` pings only what is yours alone to decide, and leaves
questions, CI and failed runs to the leader, who watches the monitor. A state of a kind left out is
not pinged, but stays in `needs-you`, `canccu-status` and the monitor. A word that is no kind
pings nothing and is logged once.

| State | When | The form's first line (on issue n), after `For the product owner:` |
|---|---|---|
| `checkpoint` | An open checkpoint its step waits on, unless `USER_LOGIN` labelled it `checkpoint-ok` after the summary | this checkpoint waits for your `checkpoint-ok`: read the summary (<link>), then label this issue `checkpoint-ok`, or close it. |
| `needs-you` | An open issue labelled `needs-you`, or a managed unit in phase `needs-you` whose label did not land | this issue needs you (`needs-you`): the latest comments say why. |
| `plan` | … whose unit waits on a plan-tier plan, unless it is labelled `plan-ok` already | the plan here waits for your OK: label this issue `plan-ok`, or comment. |
| `question` | … whose worker's question the answerer escalated | the worker's question here needs the product owner: answer it in a comment. |
| `pr-needs-you` | Our open PR labelled `needs-you` (another PR: none) | PR #<pr> needs you (`needs-you`): its latest comments say why. |
| `accept` | A unit in phase `accept` with its PR open and not labelled `accepted` yet | PR #<pr> waits for your accept: label it `accepted`, or `canccu-ship <n>` (in a repo without auto-merge, only the label). |

- **One comment per issue, edited in place.** `pings/<n>` holds `<kind> <comment id>`. A later
  pass with the same state sends nothing. A changed kind edits that comment (`gh api -X PATCH`)
  instead of posting a new one; a settled item edits its first line to `Closed: For the product
  owner: …`, and the record goes, so the state coming back posts a new comment. An old one-word
  record (no id) posts a new comment for the next state. An issue in two states counts the first
  row `PING_KINDS` lets through.
- **When.** Each pass, right after reading GitHub and before acting: a state set during a pass is
  pinged on the next one, at most `INTERVAL` seconds later. A state you already answered by label
  (`plan-ok`, `checkpoint-ok`, `accepted`) is not pinged.
- **Always on the issue** (a package's lead issue), never on a PR: the `review-gate` check reads
  the bot's comments there.
- **Checked content only.** The form's facts come from the dispatcher's shell code; the three
  change lines from the independent reviewer's file, cut and stripped; nothing from the worker,
  the issue or the PR body. The comment carries `<!-- canccu-dispatch -->`.
- **The token.** A ping is posted like a review: the token reaches only that `gh` call. A missing
  token file (or one not mode 600) or a rejected post is logged once and nothing is recorded, so
  the ping goes out once the token works. A post that timed out may have landed: it is recorded,
  so the mention is never posted twice. A broken reviewer token silences pings too:
  `canccu-status` shows it.
- `--dry-run` prints `would: ping #<n> …` and records nothing.

## The ask form

Every ask to the product owner, the ping's comment and the block at the top of an accept's PR
body, is the same form ([`contracts.md`](../plan/contracts.md) §4), line for line:

```
For the product owner: <the kind's line from the table above>
Why you: <the owner reason>
Change (reviewer's summary):
  - <line 1>
  - <line 2>
  - <line 3>
Review: <pass|changes> on <short sha> · CI: <green|red|running|none>
Recommended: <accept, review passed and CI is green | do not accept, <why> | answer needed, <the kind's line>>
If you accept: <what happens>
No answer: this waits.
<link> · head <short sha>
```

- **Why you**: an accept's reason (`maintainer accept: …`, the `manual: ` prefix dropped); for a
  checkpoint, `a checkpoint is always the product owner's`; for the other kinds the rule that
  made the item yours (`no leader runs for this project (LEADER=off)`, an escalated question, a
  `manual-accept` label).
- **Change**: the three `- ` lines of the `Change:` section of the PR's newest review file
  ([`reviews.md`](reviews.md)), each cut at 160 characters and stripped of links, `@` mentions,
  backticks, `*`, `_`, `#`, `<` and `>`. No such section, or not exactly three lines: `  - (the
  reviewer gave no summary)` three times. An item with no PR leaves the section out.
- **If you accept**: `it merges at <short sha> once CI is green` (accept, followed by its
  `Accept:` and `Reject:` lines), `the build starts` (plan), `the next step starts` (checkpoint),
  `the worker resumes with your answer` (the others).
- **In the PR body.** When a unit reaches `accept`, the form goes between `<!-- canccu:ask -->`
  and `<!-- /canccu:ask -->` at the top of the PR body (`gh pr edit --body-file`); on a new head
  what is between the markers is replaced and the rest of the body stays. A gh error logs
  `#<n> PR #<pr>: gh error writing the ask block; tried again next pass`; the accept goes on.
- **`NOTIFY_CONTENT=link`** (project config, locked; default `full`): the comment and the PR
  block carry only the first line, the last line and the link.
