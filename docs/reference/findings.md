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
  (`Evidence:`, `Fix:`) are its own. A heading with no finding says `none`.
- **Pre-existing:** the cited line is not in the diff's changed lines and the diff did not make
  its bug reachable. Such a finding never blocks; it goes to the follow-up issue, and a `security`
  one gives that issue the label `security`.
- **The count line** counts the items as written under each heading, before any demotion. A file
  without it, or whose numbers do not match the items, has no valid verdict: like a file without
  one, the reviewer's session is asked once per head to write it again, with the reason `the count
  line does not match the items`; then `needs-you`.

**The dispatcher decides what blocks** (`lib/canccu-verdict.sh`). A `Blocking:` item with a
never-blocking class, no class or no `Evidence:` line is **demoted**: it counts as non-blocking.
The verdict is `changes` only when at least one blocking item is left, whatever the reviewer
wrote. When that differs from the reviewer's verdict, the dispatcher rewrites the file's last line
before posting, with its reason just above it:

```
Dispatcher: no blocking finding left (<d> moved out of Blocking: never-blocking class, no class or no Evidence:); verdict pass.
Review verdict: pass <sha>
```

With no-repeat demotions ([`reviews.md`](reviews.md#no-repeats)), the reason lists each kind with
its count: `<p> never-blocking class, no class or no Evidence:`, `<s> already settled`, `<u>
unchanged since the pass`, separated by `; `. (And, for a `pass` with a blocking item left, `Dispatcher: <b> blocking finding(s) left (a
blocking class and Evidence:); verdict changes.`). The posted comment then carries the effective
verdict, so the state and the PR agree. The fix round gets only the blocking items left; the
demoted, non-blocking and pre-existing items go to the follow-up issue. Each posted verdict adds a
line to `reviews.log` ([`state.md`](state.md)). A verdict comment posted by hand, without a valid
block, is read as before: its whole text without the `Non-blocking:` section blocks.
