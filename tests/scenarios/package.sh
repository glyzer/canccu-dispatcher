# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/package.sh — three issues of one step: the planner bundles them, one PR closes all three.
# a step is a milestone: the planner runs on its ready issues (docs/reference/packages.md)
sc_setup() {
  local t="9 Scenario package"
  M=$(gh api "repos/$REPO/milestones?state=all" --jq ".[] | select(.title == \"$t\") | .number" 2>/dev/null)
  [ -n "$M" ] || M=$(must gh api "repos/$REPO/milestones" -f title="$t" --jq .number) || return 1
  A=$(new_issue "package part a" --milestone "$t") && B=$(new_issue "package part b" --milestone "$t") &&
    C=$(new_issue "package part c" --milestone "$t") || return 1
  # the fake planner names its package "scenario": the unit key pkg-<m>-scenario
  echo "$A $B $C" > "$SCENARIO_DIR/closes-pkg-$M-scenario"
}
sc_check() {
  (( $(ran '^plan ') > 0 )) || { WHY="the planner never ran"; return 1; }
  expect "not one merged PR closing #$A, #$B and #$C" \
    "[.prs[] | select(merged) | select([\"Closes #$A\", \"Closes #$B\", \"Closes #$C\"] - [.body | scan(\"Closes #[0-9]+\")] | length == 0)] | length == 1" &&
    expect "not all three issues closed" '[.mine[] as $n | issue($n) | closed] | (all and length == 3)'
}
