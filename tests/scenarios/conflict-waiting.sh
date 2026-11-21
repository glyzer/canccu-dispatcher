# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/conflict-waiting.sh — main moves while the PR waits for its accept: main is merged into it, then the accept merges it.
# the review's "Maintainer accept:" line makes the PR wait for an accept; while it waits, a commit
# on main touches the PR's own file, so GitHub marks the PR conflicting. The worker's merge run
# (git cannot merge an add/add by script) resolves it with the PR's side.
sc_setup() {
  N=$(new_issue "conflict while waiting for accept")
  printf '%s\n' 'review 1 pass-accept' 'worker 2 merge-main' > "$SCENARIO_DIR/script"
}
sc_tick() {
  local b
  q "issue($N) | labelled(\"awaiting-accept\")" || return 0
  # the fake worker's file is scenario/<its branch>.txt
  b=$(jq -r '.prs[] | select(.state == "OPEN") | .headRefName' "$SCENARIO_DIR/world.json" | head -1)
  [ -n "$b" ] && once main-moved push_main "scenario/$b.txt" "main's side"
  # the accept, once the PR holds a merge of main: the product owner's label on the PR
  if q '[.prs[] | select(.state == "OPEN") | .commits[].messageHeadline | startswith("Merge")] | any'; then
    once accepted gh pr edit "$(jq -r '.prs[] | select(.state == "OPEN") | .number' "$SCENARIO_DIR/world.json" | head -1)" \
      -R "$REPO" --add-label accepted
  fi
  return 0
}
sc_check() {
  expect "the PR got no merge of main" '[.prs[] | .commits[].messageHeadline | startswith("Merge")] | any' &&
    expect "the PR did not merge" '[.prs[] | select(merged)] | length == 1' &&
    expect "#$N is still open" "issue($N) | closed"
}
