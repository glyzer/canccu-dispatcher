<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Work packages

Part of the reference; the index is [`README.md`](README.md). A step's lifecycle (the current
step, the health pass, the checkpoint, the budget) is in [`steps.md`](steps.md).

## Work packages per step

Each roadmap step is a GitHub milestone. Its issues run as **work packages**: a planner bundles
the step's ready issues, each package runs through the pipeline as one unit (one worker, one PR,
one review, one fix, one fix-check, the merge), its accept follows its risk class, and the step
ends with a health pass and a checkpoint pause. An issue with no milestone, or labelled `fast`,
runs alone in the **fast lane**: one issue, one PR, any time, in any step.

### Units

The pipeline runs on a unit key K: `<n>` for an issue (the fast lane, and a package of one),
`pkg-<m>-<name>` for a package of several issues, `pkg-<m>-health` for the health pass (m: the
milestone number). A package's labels, comments and your answers live on its **lead issue** (its
first open issue; for the health pass, the step's epic, else its checkpoint); every issue of the
package carries `in-progress`. A package of several issues runs in `worktrees/<repo>/<K>` with
its session kept for a follow-up that `RESUME_ON` resumes; a package of one runs as its issue.

### The planner

It starts when the step has issues to plan and no plan, when a wave is over, or when new ready
issues joined an idle step. **The dispatcher alone decides which issues are eligible**: open, in
the step's milestone, `ready`, not `epic`, `checkpoint`, `fast`, `in-progress` or `needs-you`,
not managed, in no package, with no open blocker. It hands the planner exactly those numbers,
with the earlier waves' packages and the lead's comments on the epic.

The planner is a fresh session (window `plan#<m>`, `--untrusted`, `PLAN_MODEL`, `BUDGET_PLAN`)
in a fresh worktree at `origin/main`. It gets no directory the dispatcher reads: its plan is its
final message, which the dispatcher parses as JSON, validates (`lib/canccu-plan.jq`) and writes
itself to `steps/<m>.plan-<w>.json` (a rejected plan is kept as `….rejected.json` for the lead).
The dispatcher never follows a link or reads a path the planner chose.

The plan:

```json
{"schema": 1, "step": 12, "wave": 1,
 "packages": [{"name": "auth", "issues": [41, 42], "risk": "high",
               "risk_reason": "sign-in", "areas": ["src/auth/"], "depends_on": []}]}
```

Its rules: issues that touch the same files go in one package; high-risk content
(`HIGH_RISK_TEXT`) gets a package of its own; about `PACKAGE_LINES` changed lines at most per
package (and at least `PACKAGE_MIN_ISSUES` issues where they fit); never split or create
issues; the rules' `PLANNER_EXTRA`. The check: valid JSON and schema, the right step and wave,
names `[a-z0-9-]` of at most 30 characters, unique, not `health`, not used earlier in the step;
every issue at most once and only handed issues that are still eligible; a risk class with a
reason; known dependencies, none on itself, no cycle. Issues the plan leaves out join the next
wave. An invalid plan, or none: the step goes to `needs-you` (its epic is labelled with the
reason); removing the label plans again. The plan is shown in one comment on the epic, edited
in place each wave, and in the snapshot and `canccu-status`.

### Package runs

A package whose dependencies are all merged starts while a slot is free, in plan order, after
the fast lane (`CAP` counts packages, one run each). Every issue is checked again right before
the start: a package with an issue that is no longer eligible is `refused`. Branch
`pkg-<m>-<name>` (a package of one keeps `<n>-<slug>`). A contract-first PR is on the branch
plus `-contract`, for a package and a single issue alike ([`merging.md`](merging.md)). Its budget is the issue's times its issue
count, capped by `BUDGET_PACKAGE_MAX`. The worker may use subagents for the package's issues, but
none of their review steps. The PR has a `Closes #<n>` line per issue, `Package:` and `Risk:`
lines, and must close exactly the package's issues (else manual). The reviewer reads every
linked issue and writes `Risk:` before its verdict. A package is finished when all its issues
are closed: one line goes to `steps/<m>.packages`.

### Risk classes

`low`, `normal` or `high`: the highest of the plan's, the PR's `Risk:` line and the reviewer's
(the full review's still counts after the fix-check). `high` makes the PR manual (`manual: risk
high (<source>)`) and the review high effort; a `low` or `normal` package is reviewed at
medium effort ([`reviews.md`](reviews.md)); the other manual rules apply as always
([`merging.md`](merging.md)).

### Waves

A wave is over when every package of its plan is merged, closed, refused, waiting for your accept
or `needs-you`, or blocked behind one; then the planner plans what is left. Issues that join the
step mid-wave wait for the next wave.

**A waiting package holds only its dependants**: one that waits for an accept or `needs-you`
blocks the packages that `depends_on` it, never the rest of the step. The issues of the plan's
*live* packages (running, waiting, could start, or blocked only behind live ones) are held: no
planner gets them. The next wave's plan **carries** the last wave's live packages (with
`carried_from`; the plan comment shows "(from wave N)"), so a later accept merges the package and
its dependants start then. A package blocked behind a closed, refused or unknown one is not live:
its issues go back to the next planner. The health pass and the checkpoint still wait for every
package.
