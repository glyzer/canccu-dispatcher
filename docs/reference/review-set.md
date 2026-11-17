<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Review set

`tests/review-set/run` runs the real reviewer prompt, on the real model, against fixed cases: some
with a planted defect, some with none. It shows whether a change to the review prompt, the
verdict handling or the model still finds what it should and still passes what is clean. It
costs model tokens, so neither `tests/run` nor CI runs it. Its own test, with a fake reviewer, is
in `tests/canccu-brake.sh`. A release whose diff touches the review needs it to pass
([`release.md`](release.md)).

## The cases

One directory per case under `tests/review-set/`:

| File | Holds |
|---|---|
| `issue.md` | the issue the change is for (number 7): the spec and its acceptance criteria |
| `pr.md` | the PR body (PR 8, closing #7) |
| `base/` | the project before the change: a small shell tool with a documented file format |
| `diff.patch` | the change under review |
| `expect` | `clean`, or `defect <class> <file>:<line>` |
| `history` | optional: the PR's review history ([`findings.md`](findings.md)), for a settled finding |

The first line of `issue.md` and `pr.md` is the licence comment; the reviewer never sees it.

There are 12 cases:

- 6 with a planted defect, one per class: `defect-correctness`, `defect-security`,
  `defect-criterion`, `defect-contract`, `defect-data-loss` and `defect-test`;
- 3 clean: `clean-reset-all`, `clean-show-missing`, `clean-help`;
- 2 clean, with a bug in lines the change does not touch: `preexisting-get-prefix` and
  `preexisting-del-regex`. Their findings belong under `Pre-existing:` and must not block;
- 1 clean, with a finding raised and answered before (`settled-add-output`): raised again, the
  no-repeat rules demote it.

## Running it

```sh
tests/review-set/run [--model <m>] [--effort low|medium|high|xhigh|max] [--light]
```

- Each case gets its own temp dispatcher home (project `tools`, repo `example-user/tools`, the
  default rules). The host's projects are never touched. The case repo sits where the dispatcher
  keeps a PR's review worktree.
- The prompt is `review_prompt` at the given effort (default `high`), or `light_review_prompt`
  with `--light` (always low effort; `--light` with `--effort` is a usage error).
- The engine is `claude -p` with the untrusted-run flags ([`engine.md`](engine.md)) and the
  budget of `BUDGET_REVIEW`. It runs in the foreground, one case at a time. Its `gh` answers only
  `issue view`, `pr view` and `pr diff`, from the case. `--model` passes a model; without it,
  the engine's default.
- The verdict file is judged as the dispatcher judges one: `review_ctx`, then `review_effective`.
  - A defect case is `found` when a kept blocking finding is on the planted file, within 5 lines
    of the planted line, whatever its class. Otherwise it is `missed`.
  - A clean case is `clean` when the effective verdict is pass. Otherwise it is `blocked`.
- It prints `<case> found|missed|clean|blocked` per case, then
  `found N · missed N · clean N · blocked N`.
- Exit 0 green (or the baseline written), 1 red, 2 a usage error.

## The log and the baseline

Both are in the project's home (`CANCCU_PROJECT`, as for every command).

- `review-set.log`: one line per run,
  `<time> <short sha> <model> <effort> <found> <missed> <clean-blocked> <cases>`. The model is
  `default` without `--model`; the effort is `light` with `--light`. The cases are the missed
  defect cases and the blocked clean ones, comma-separated, or `-`.
- `review-set-baseline` (with `--light`: `review-set-baseline-light`): written by the first run,
  `<time> <short sha> <model> <effort> <clean-blocked> <found cases>`. To take a new baseline,
  delete the file.
- **Red**: a case the baseline found is missed, or more clean cases are blocked than at the
  baseline. The run prints `red: <cases>`. With `REVIEW_BRAKE=auto`, a red run engages the review
  brake with the trigger `review set missed <cases>`
  ([`review-depth.md`](review-depth.md#the-review-brake)). A brake already on keeps its trigger.

## The release gate

A release PR's body needs `Review set: pass at <short sha>` when the diff since the last tag
changes any of these:

- `review_prompt` (`lib/canccu-runs.sh`);
- `light_review_prompt` or `LIGHT_REVIEW_TEXT` (`lib/canccu-depth.sh`);
- `norepeat_prompt` (`lib/canccu-norepeat.sh`: the settled findings and the pass rule);
- `lib/canccu-verdict.sh` (the verdict, the demotions and the REVIEW.md text);
- `REVIEW_MODEL`'s default (`lib/canccu-config.default`).

Without an earlier tag the line is needed too. `.github/scripts/release check` enforces it in CI,
as with `Scenarios: pass at`.
