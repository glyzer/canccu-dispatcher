<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# The finding block: classes, evidence, pre-existing, the count line

Part of the reference; the index is [`README.md`](README.md). The reviewer and the fix-check that
write this block are in [`reviews.md`](reviews.md).

## The finding block

Every review and fix-check file ends with this block, in this order (the shape of
`docs/plan/contracts.md` §8; the prompts quote it with its class lists and its `Pre-existing:` rule):

```
Blocking:
1. [<class>] <file>:<line> — <what is wrong, one line>
   Evidence: <the input or state and the wrong result, or the rule broken and the quoted line>
   Fix: <the concrete change>
Non-blocking:
- [<class>] <file>:<line> — <what>
Pre-existing:
- [<class>] <file>:<line> — <what>
Maintainer accept: <what>            (only for a breaking contract or a destructive migration)
Risk: <low|normal|high> — <why>      (packages)
Findings: <b> blocking, <n> non-blocking, <p> pre-existing
Review verdict: <pass|changes> <sha>
```

- **Classes.** Blocking: `correctness`, `security`, `criterion` (an acceptance criterion not met),
  `contract` (a fixed name, default, text or format not used as written), `data-loss`, `test` (a
  behaviour change without a test that failed before it). Never blocking: `style`, `docs`,
  `simplify`, `test-gap`, `other`; a class not in either list counts as no class.
- **An item** starts at column 0 with a list mark (`1.`, `-`, `*`); its indented lines
  (`Evidence:`, `Fix:`) are its own. A heading with no finding says `none`: on its line, as a
  list item (`- none`) or in brackets (`(none)`); `none`, `n/a` and `nothing` are no item.
- **Pre-existing:** the cited line is not in the diff's changed lines and the diff did not make
  its bug reachable. Such a finding never blocks; it goes to the follow-up ticket, and a `security`
  one also gets an issue of its own, labelled `security`, that the ticket's line links.
- **The count line** counts the items as written under each heading, before any demotion. A file
  without it, or whose numbers do not match the items, has no valid verdict: like a file without
  one, the reviewer's session is asked once per head to write it again, with the reason `no finding
  block or count line` or `the count line does not match the items`; then `needs-you`.

**The dispatcher decides what blocks** (`lib/canccu-verdict.sh`). A `Blocking:` item with a
never-blocking class, no class or no `Evidence:` line is **demoted**: it counts as non-blocking.
The verdict is `changes` only when at least one blocking item is left, whatever the reviewer
wrote. When that differs from the reviewer's verdict, the dispatcher rewrites the file's last line
before posting, with its reason just above it:

```
Dispatcher: no blocking finding left (<d> moved out of Blocking: never-blocking class, no class or no Evidence:); verdict pass.
Review verdict: pass <sha>
```

With no-repeat demotions ([below](#no-repeats)), the reason lists each kind with
its count: `<p> never-blocking class, no class or no Evidence:`, `<s> already settled`, `<u>
unchanged since the pass`, separated by `; `. (And, for a `pass` with a blocking item left, `Dispatcher: <b> blocking finding(s) left (a
blocking class and Evidence:); verdict changes.`). The posted comment then carries the effective
verdict, so the state and the PR agree. The fix round gets only the blocking items left; the
demoted, non-blocking and pre-existing items go to the follow-up ticket. Each posted verdict adds a
line to `reviews.log` ([`state.md`](state.md)). A verdict comment posted by hand, without a valid
block, is read as before: its whole text without the `Non-blocking:` section blocks.

## No repeats

A settled finding is not raised again (`lib/canccu-norepeat.sh`; the key of contracts §8: the
class and the file path, the lines overlapping; no matching of the text).

- **The history.** Each verdict acted on adds its blocking findings left to
  `reviews/<pr>/history` as `open` ([`state.md`](state.md)). A fix-check (it checks the earlier
  findings, and its `Blocking:` lists only what is still open) marks every `open` line it does
  not raise again `fixed`. Your accept, or your `needs-work` that starts a new cycle (not the
  one more fix round of a fix-check's open items), marks every `open` line `answered`; a
  `needs-work` with a `full review` line leaves them `open`, for the new full review to check.
- **The prompts.** Every full review and fix-check prompt carries the history with its outcomes,
  as data, and the rule: a finding with the same class and file on overlapping lines as a
  `fixed` or `answered` one is not raised again. After a pass, the full review's prompt adds the
  pass rule below.
- **The dispatcher checks it.** A `Blocking:` item whose key and lines match a `fixed` or
  `answered` line is demoted (`already settled`); it does not go to the follow-up ticket either.
  A `security` item is never settled: one that comes back blocks again.
  When `pass_sha` is set and the full review is of a later head, a blocking item on lines that
  `git diff <pass_sha>..<head>` did not change is demoted (`unchanged since the pass`), unless its
  class is `security`; it goes to the follow-up ticket. A fix-check is never under the pass rule,
  nor is an item without `file:line`. When that diff cannot be read, the pass rule is off for
  the review (logged), so its findings still block. Both demotions count in `<demoted>` of
  `reviews.log`, and the dispatcher line names them:

```
Dispatcher: no blocking finding left (2 moved out of Blocking: 1 already settled; 1 unchanged since the pass); verdict pass.
```

## The follow-up ticket

The non-blocking, demoted and pre-existing items of a verdict go to one ticket per step (#223):
`Follow-ups: step <title>`, in the step's milestone, for its waves, its health pass, its deep
review and its cadence rounds; `Follow-ups: fast lane`, without a milestone, for every issue
outside a step. They go into the ticket's body, never into comments: one heading
`### PR #<pr> (<what it closes>, <head7>)` per verdict, and under it one `- [ ] <finding>` line
per item (its own indented lines stay under it). The first findings make the ticket (not labelled
`ready`: you decide what gets built). A body that would pass 60000 characters opens
`Follow-ups: step <title> (part 2)` (and so on), and the full one gets `Continued in #<n>.`. A
closed ticket is never edited: the next findings make a new one, and so does a PR that closes the
ticket. A pre-existing `security` finding gets an issue of its own,
`Security (pre-existing): <finding>`, labelled `security`; its ticket line ends
`(security: #<n>)`. The tickets are recorded in `followups` ([`project-dir.md`](project-dir.md)).

## Recurring findings

A finding that comes back PR after PR is fixed where it comes from, not once more in each PR.
When a managed PR merges, the dispatcher reads its posted verdicts (the `reviews.log` lines of
the PR, their review files) and writes one line per key to `findings.log`. The key is the
item's class and file (`[correctness] lib/a.sh:12 …` gives `correctness lib/a.sh`), never its
wording; an item without a class or a file has none. Every heading counts: `Blocking:`,
`Non-blocking:` and `Pre-existing:`. A merge seen again records nothing, and a dry run nothing.

When a key was raised on `FINDINGS_RECUR` merged PRs (3) within `FINDINGS_RECUR_DAYS` days (30),
the dispatcher files one issue `Recurring finding: <class> in <file>`, not `ready`: the PRs with
the first line of each finding (200 characters at most), the proposal to fix it at the source (a
rule in `AGENTS.md` or `REVIEW.md`, a line in the worker prompt, a lint or a test), and who
decides what is built of it (the leader, or the product owner with `LEADER=off`). The issue is
recorded in `recurring`; a later PR that raises the key again comments on it while it is open, and
a closed one makes a new issue. A `gh` error is logged and the merge goes on; the key is tried
again by the next PR that raises it. `FINDINGS_RECUR=0` files and counts nothing.
`canccu-status` lists the open ones on one line: `recurring findings (a person decides): #900
correctness in lib/a.sh`.
