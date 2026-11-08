<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# canccu-dispatcher docs

## Guides

| Guide | For |
|---|---|
| [`getting-started.md`](getting-started.md) | From nothing to a first merged PR, step by step |
| [`install.md`](install.md) | Requirements, the installer, releases, rollback, uninstall, `doctor` |
| [`repo-contract.md`](repo-contract.md) | What a target repo needs: the bot, the variable, CI, the review gate, the ruleset, the `CLAUDE.md` and `AGENTS.md` snippets |
| [`upgrading.md`](upgrading.md) | The pause → stop → wait → install → restart → resume sequence |
| [`hosts.md`](hosts.md) | Several hosts: one repo per host, one Claude account, host profiles |
| [`troubleshooting.md`](troubleshooting.md) | What each message means and what to do |
| [`security.md`](security.md) | Reviewer token isolation, untrusted checkouts, prompt injection, posted paths, known limits |
| [`canccu-dispatch.md`](canccu-dispatch.md) | Where the sections the code cites went |

## Reference

[`reference/README.md`](reference/README.md): every setting and behaviour, one short file per
topic (config and rules, projects, the pipeline, merging, reviews, packages and steps, the usage
throttle, pings, the run engine, state, the snapshot, the monitor). Read only the topic you need.
