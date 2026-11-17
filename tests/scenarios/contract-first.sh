# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/contract-first.sh — the worker opens a contract PR and its own as a draft: the contract PR merges first, then the unit's.
sc_setup() { N=$(new_issue "a contract change first"); printf '%s\n' 'worker 1 contract' > "$SCENARIO_DIR/script"; }
sc_check() {
  expect "the contract PR did not merge" '[.prs[] | select(merged and (.headRefName | endswith("-contract")))] | length == 1' &&
    expect "the unit's PR did not merge" '[.prs[] | select(merged and (.headRefName | endswith("-contract") | not))] | length == 1' &&
    expect "the unit's PR merged before the contract PR" '[.prs[] | select(merged)] | sort_by(.mergedAt) | .[0].headRefName | endswith("-contract")' &&
    expect "#$N is still open" "issue($N) | closed"
}
