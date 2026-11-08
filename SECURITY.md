<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Security

## Reporting a problem

Please do not open a public issue for a vulnerability. Report it privately through GitHub: the
repo's **Security** tab → **Report a vulnerability**. If that button is not there, open an issue
that only says you have a security problem to report, with no details, and the maintainer will
reach you privately.

Say what an attacker can do, what they need (a PR, an issue comment, access to the host), and how
to reproduce it with invented names. The fix is released before the details are made public,
crediting you if you wish. Only the newest release is supported while the tool is pre-release.

## What the tool never does with tokens

- No Claude session ever holds the reviewer bot's token or its path: the dispatcher reads it in a
  subshell for one `gh` call at a time, and a Claude Code deny rule keeps sessions from reading
  the file.
- No run gets `GH_TOKEN` or `GITHUB_TOKEN`: they are removed before every run and sent empty into
  every tmux window. Runs use the project's narrow `gh` login, by the path of its config dir.
- No token is written to a command line, a log, the state, the status snapshot, a comment or a
  tmux environment.
- It never creates a token, and never changes rulesets, secrets, repo variables or collaborators.
- Each project's token is a fine-grained token for that one repo, without Administration or
  Secrets.

The whole model, with its known limits: [`docs/security.md`](docs/security.md).
