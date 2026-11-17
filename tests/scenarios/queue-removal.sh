# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # read by tests/scenarios/run
# tests/scenarios/queue-removal.sh — the merge queue drops the PR once: the dispatcher queues it again and it merges.
sc_setup() { N=$(new_issue "dropped by the merge queue"); }
# dequeue <pr>: what GitHub does to a queue entry whose checks fail, done once by the suite
dequeue() {
  local id
  id=$(gh api graphql -f query="query { repository(owner: \"${REPO%/*}\", name: \"${REPO#*/}\") { pullRequest(number: $1) { id isInMergeQueue } } }" \
         --jq '.data.repository.pullRequest | select(.isInMergeQueue) | .id') && [ -n "$id" ] || return 1
  gh api graphql -f query="mutation { dequeuePullRequest(input: {id: \"$id\"}) { clientMutationId } }" >/dev/null
}
sc_tick() {
  local p; p=$(jq -r '.prs[] | select(.state == "OPEN") | .number' "$SCENARIO_DIR/world.json" | head -1)
  [ -n "$p" ] && once dequeued dequeue "$p"
  return 0
}
sc_check() {
  [ -e "$SCENARIO_DIR/once-dequeued" ] || { WHY="the PR never reached the merge queue"; return 1; }
  expect "the PR did not merge after it was dropped" '[.prs[] | select(merged)] | length == 1' &&
    expect "#$N is still open" "issue($N) | closed"
}
