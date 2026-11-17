# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/push-after-pass.sh — a push after the review passed: a fix-check runs on it before the merge.
# the push must land before auto-merge merges: the sandbox's required CI takes a minute or more
# (docs/reference/scenarios.md), longer than one pass of the suite
sc_setup() { N=$(new_issue "a push after the pass"); }
push_pr() {
  local b; b=$(jq -r '.prs[] | select(.state == "OPEN") | .headRefName' "$SCENARIO_DIR/world.json" | head -1)
  [ -n "$b" ] && git -C "$CLONE" fetch -q origin "$b" && git -C "$CLONE" checkout -q -B "$b" FETCH_HEAD &&
    mkdir -p "$CLONE/scenario" && echo "after the pass" >> "$CLONE/scenario/$N-late.txt" && git -C "$CLONE" add scenario &&
    git -C "$CLONE" -c user.name=scenario -c user.email=scenario@users.noreply.github.com commit -qm "scenario: a push after the pass" &&
    git -C "$CLONE" push -q origin "$b"
}
sc_tick() {
  # after the review's pass is posted, not while the review runs (a push then voids the review)
  grep -q 'posted as' "$CANCCU_HOME/dispatch.log" 2>/dev/null && q '[.prs[] | select(.state == "OPEN")] | length == 1' && once pushed push_pr
  return 0
}
sc_check() {
  [ -e "$SCENARIO_DIR/once-pushed" ] || { WHY="the suite's push never happened"; return 1; }
  (( $(ran '^fixcheck ') > 0 )) || { WHY="no fix-check after the push"; return 1; }
  expect "the PR did not merge" '[.prs[] | select(merged)] | length == 1'
}
