# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/single.sh — one issue: its PR is reviewed, passes and merges; the issue closes.
sc_setup() { N=$(new_issue "one issue to merge"); }
sc_check() {
  expect "no PR of #$N merged" "[.prs[] | select(merged)] | length == 1" &&
    expect "#$N is still open" "issue($N) | closed"
}
