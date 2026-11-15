# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/crash.sh — the fake engine dies: one fresh retry, then needs-you.
EXPECT_NEEDS_YOU=1
sc_setup() { N=$(new_issue "a crashing worker"); printf '%s\n' 'worker 1 crash' 'worker 2 crash' > "$SCENARIO_DIR/script"; }
sc_check() {
  expect "#$N is not needs-you" "issue($N) | labelled(\"needs-you\")" &&
    { (( $(ran "^worker [0-9]+ $N crash") == 2 )) || { WHY="not one retry: $(ran "^worker [0-9]+ $N ") runs"; return 1; }; }
}
