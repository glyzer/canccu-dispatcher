# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The skill names the prompts give, from the host's settings (docs/hosts.md, "Skills"): what a
# host has installed is its own choice, so no prompt names a third-party plugin by default.
# Sourced by lib/canccu-common.sh.

# review_skill / security_skill: REVIEW_SKILLS' first and second word; a missing one keeps the
# built-in skill, so a review never runs without its instruction
review_skill() { local a=(); read -ra a <<<"${REVIEW_SKILLS:-}"; echo "${a[0]:-code-review}"; }
security_skill() { local a=(); read -ra a <<<"${REVIEW_SKILLS:-}"; echo "${a[1]:-security-review}"; }

# WORKER_METHOD: what the workers do without a skills plugin, in plain words; fixed text, not a
# setting: a host with a plugin replaces it whole with WORKER_SKILLS (docs/hosts.md, "Skills")
WORKER_METHOD='Work test first: write a test that fails for the right reason, then the code that makes it pass. When something fails, find the cause before you change code. Run the checks and read their output before you say a thing is done. Keep to the issue or the plan: build nothing it does not ask for.'

# worker_skills: WORKER_SKILLS, else WORKER_METHOD, with a leading space. The health prompt reads
# WORKER_SKILLS itself, so it never gets the method: a pass that changes no behaviour has no test to write
worker_skills() { printf ' %s' "${WORKER_SKILLS:-$WORKER_METHOD}"; }
