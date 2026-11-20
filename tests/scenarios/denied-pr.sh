# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/denied-pr.sh — the worker pushed its branch but its gh pr create is denied: the
# dispatcher opens the PR (#237), the review passes, it merges and the issue closes.
sc_setup() { N=$(new_issue "a denied PR create"); printf '%s\n' 'worker 1 pr-denied' > "$SCENARIO_DIR/script"; }
sc_check() {
  expect "no PR of #$N merged" "[.prs[] | select(merged)] | length == 1" &&
    expect "the PR does not say the dispatcher opened it" "[.prs[] | select(merged) | .body | contains(\"The dispatcher opened this PR\")] | any" &&
    expect "#$N is still open" "issue($N) | closed"
}
