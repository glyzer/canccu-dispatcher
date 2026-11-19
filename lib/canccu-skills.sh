# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The skill names the prompts give, from the host's settings (docs/hosts.md, "Skills"): what a
# host has installed is its own choice, so no prompt names a third-party plugin by default.
# Sourced by lib/canccu-common.sh.

# review_skill / security_skill: REVIEW_SKILLS' first and second word; a missing one keeps the
# built-in skill, so a review never runs without its instruction
review_skill() { local a=(); read -ra a <<<"${REVIEW_SKILLS:-}"; echo "${a[0]:-code-review}"; }
security_skill() { local a=(); read -ra a <<<"${REVIEW_SKILLS:-}"; echo "${a[1]:-security-review}"; }

# worker_skills: WORKER_SKILLS with a leading space, nothing when it is empty
worker_skills() { [ -z "${WORKER_SKILLS:-}" ] || printf ' %s' "$WORKER_SKILLS"; }
