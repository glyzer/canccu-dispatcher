<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Reference

Every setting and behaviour of canccu-dispatcher, one short file per topic. **Read only the topic
your question or change touches**, and when a change alters a behaviour, update only that topic.
The guides (getting started, install, upgrading, security, …) are in [`../README.md`](../README.md).

| Topic | Covers |
|---|---|
| [`commands.md`](commands.md) | Roles, every command, the labels, whose PRs the dispatcher acts on |
| [`config.md`](config.md) | Where the values come from, every config key with its default |
| [`hosts.md`](hosts.md) | Host profiles, environment variables |
| [`rules.md`](rules.md) | A project's rules: risky and gated paths, extra prompt text, the freeze, the one-at-a-time lock, pings |
| [`projects.md`](projects.md) | Projects, adding one, a narrow token per project |
| [`lead.md`](lead.md) | The lead's session, how to write issues, steps and epics, clearing what waits for you |
| [`pipeline.md`](pipeline.md) | One pass of the dispatcher, the phases |
| [`merging.md`](merging.md) | The merge policy (auto or manual), your accept, the guards |
| [`reviews.md`](reviews.md) | The reviewer, the fix-check, the verdict line, the answerer, the worker prompt |
| [`packages.md`](packages.md) | Work packages per step: units, the planner and its plan, package runs, risk classes, waves |
| [`steps.md`](steps.md) | The current step, the health pass, the checkpoint, stops, notes, the step budget |
| [`usage.md`](usage.md) | The usage throttle and the usage-limit back-off |
| [`pings.md`](pings.md) | The @mentions that tell your phone something needs you |
| [`engine.md`](engine.md) | The run engine, untrusted runs, locks |
| [`state.md`](state.md) | Where the state lives, a unit's state, colours |
| [`snapshot.md`](snapshot.md) | The status snapshot's schema |
| [`monitor.md`](monitor.md) | canccu-monitor's layout and self-test |

## Sections

The code's comments cite sections as `docs/canccu-dispatch.md, "<section>"`. Each lives here:

| Section | Topic |
|---|---|
| Projects | [`projects.md`](projects.md#projects) |
| Adding a project | [`projects.md`](projects.md#adding-a-project) |
| A narrow token per project | [`projects.md`](projects.md#a-narrow-token-per-project) |
| Fair share of TOTAL_CAP | [`projects.md`](projects.md#fair-share-of-total_cap) |
| Rules | [`rules.md`](rules.md#rules) |
| Merge policy | [`merging.md`](merging.md#merge-policy) |
| Work packages per step | [`packages.md`](packages.md#work-packages-per-step) |
| Usage throttle | [`usage.md`](usage.md#usage-throttle) |
| Pings | [`pings.md`](pings.md#pings) |
| Status snapshot | [`snapshot.md`](snapshot.md#status-snapshot) |
| Moving to the command-center layout | [`monitor.md`](monitor.md#moving-to-the-command-center-layout) |
| One pass | [`pipeline.md`](pipeline.md#one-pass) |
| Run engine | [`engine.md`](engine.md#run-engine) |
| Reviewer | [`reviews.md`](reviews.md#reviewer) |
| Fix-check | [`reviews.md`](reviews.md#fix-check) |
| Answerer | [`reviews.md`](reviews.md#answerer) |
| Worker prompt | [`reviews.md`](reviews.md#worker-prompt) |
| Colour per issue | [`state.md`](state.md#colour-per-issue) |
| Guards | [`merging.md`](merging.md#guards) |
