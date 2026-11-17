# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/denied-push.sh — the worker's push is refused: needs-you naming the denied command.
EXPECT_NEEDS_YOU=1
sc_setup() { N=$(new_issue "a denied push"); printf '%s\n' 'worker 1 push-denied' > "$SCENARIO_DIR/script"; }
sc_check() {
  expect "#$N is not needs-you" "issue($N) | labelled(\"needs-you\")" &&
    expect "the needs-you does not name the denied push" "issue($N) | said(\"git push\")"
}
