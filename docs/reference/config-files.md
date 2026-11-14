<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Config files

Part of the reference; the index is [`README.md`](README.md). Every key with its default is in
[`config.md`](config.md).

## Where the values come from

Every file is shell `KEY=value` lines. A `canccu-*` command reads, in this order:

1. `lib/canccu-config.default`: the defaults, for every project;
2. `hosts/<HOST_PROFILE>.conf`: the host profile, the values that suit the Claude plan and the
   host ([`hosts.md`](hosts.md#host-profiles));
3. `~/.canccu/config`: the global config, a default for every project on this host;
4. `~/.canccu/projects/<name>/rules`: the project's rules ([`rules.md`](rules.md));
5. `~/.canccu/projects/<name>/config`: the project's config.

A later file wins. Two keys are exceptions: `TOTAL_CAP` is read only up to `~/.canccu/config`
(it caps all projects together, so no project may change it), and `HOST_PROFILE` only from
`~/.canccu/config` or `CANCCU_HOST_PROFILE` (a profile never sets it).

`canccu-dispatcher config show --origin` answers "where does this value come from": for every
setting it prints the value, the default and the last of these layers that changed it
([`commands.md`](commands.md#config-show)). The layer is found by comparing the values after
each file, so a file that sets a key to the value it already had is not named.

`install.sh` writes a missing `~/.canccu/config` as a copy of the defaults with every value
commented out. Uncomment only what you change: a later release's new default then still applies
to every key you left alone. `canccu-init` writes a project's `config` (`REPO`, `CLONE`,
`DIGEST_ISSUE`) and `rules` from a template, `profiles/default/` or your own in
`~/.canccu/profiles/<template>/`.

**When a change applies.** A running dispatcher reads the files again at the start of the next
pass when one of the four you edit (the host profile, `~/.canccu/config`, the rules, the project's
config) has a newer modification time; the log says `config read again`. `INTERVAL` follows too.
A file with a syntax error is not read: the dispatcher keeps every value it has, says so once in
the log, and the pass runs; the corrected file applies at the pass after. `REPO`, `CLONE`,
`GH_CONFIG_DIR`, `HOST_PROFILE` and the project's name need a restart of the dispatcher: a changed
`REPO`, `CLONE` or `GH_CONFIG_DIR` keeps its old value, with a warning in the log. Every other
`canccu-*` command reads the files when it starts.
