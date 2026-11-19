# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by lib/canccu-merge.sh: the merge queue's reads and moves for merging_step (in the queue,
# removed from it and why, a stuck entry kicked).

# in_merge_queue <pr>: the PR sits in the merge queue (auto-merge hands it over there). A gh
# error counts as yes: the MERGE_WAIT_MIN bound still catches a PR that never merges.
in_merge_queue() {
  local r
  r=$(ghj api graphql -F o="${REPO%%/*}" -F r="${REPO#*/}" -F p="$1" \
        -f query='query($o: String!, $r: String!, $p: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $p) { mergeQueueEntry { state } } } }' \
        -q '.data.repository.pullRequest.mergeQueueEntry != null') || return 0
  [ "$r" = true ]
}

# queue_removal <pr>: "<reason>\t<createdAt>" of the PR's newest removal from the merge queue;
# nothing when there is none or gh fails
queue_removal() {
  ghj api graphql -F o="${REPO%%/*}" -F r="${REPO#*/}" -F p="$1" \
    -f query='query($o: String!, $r: String!, $p: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $p) { timelineItems(itemTypes: [REMOVED_FROM_MERGE_QUEUE_EVENT], last: 1) { nodes { ... on RemovedFromMergeQueueEvent { reason createdAt } } } } } }' \
    -q '.data.repository.pullRequest.timelineItems.nodes[-1] // empty | "\(.reason // "")\t\(.createdAt // "")"' 2>/dev/null
}

# queue_removed <n> <pr> <head> <merge_at>: auto-merge is off and the PR is out of the queue: act on
# the queue's reason, if it removed the PR after this merge was armed. GitHub's reason is no
# documented enum, so it is matched by substring. Never enqueued again: failed checks in a merge
# group can be a real bug that only shows with the group's other PRs. 1: no such removal.
queue_removed() {
  local n=$1 pr=$2 why at names
  IFS=$'\t' read -r why at <<<"$(queue_removal "$pr")"
  [ -n "$why" ] && [ -n "$at" ] && (( $(iso_epoch "$at") + 0 > $4 )) || return 1
  case ${why,,} in
    *conflict*)
      log "#$n PR #$pr: the merge queue removed it (merge conflict); merging main by script"
      conflict_merge "$n" "$pr" "$3" queue || needs_you "$n" "the merge queue removed PR #$pr for a conflict with main; main was merged in by script once on this head already" ;;
    *check*|*fail*)
      # gh's --jq takes no --arg: the prefix goes in the filter (pr is a number)
      names=$(ghj api "repos/$REPO/actions/runs?event=merge_group&per_page=20" -q '[.workflow_runs[]?
        | select((.head_branch // "") | startswith("gh-readonly-queue/'"$BASE_BRANCH"'/pr-'"$pr"'-"))
        | select(.conclusion | IN("failure", "timed_out", "cancelled")) | "\(.name) \(.html_url)"] | join(", ")' 2>/dev/null)
      needs_you "$n" "the merge queue removed PR #$pr because checks failed in its merge group: ${names:-none found}. Not enqueued again: a failure there can be a real bug that only shows with the other PRs of the group" ;;
    *) needs_you "$n" "the merge queue removed PR #$pr (reason: $why); a manual removal or a queue change. Not enqueued again" ;;
  esac
  return 0
}

# queue_kick <n> <pr> <head>: GitHub sometimes starts no merge_group run for a queue entry, which
# then waits for checks until the queue's own timeout. An entry still waiting NO_CHECKS_MIN after it
# was queued, with no run for its merge group, is dequeued and enqueued again (that starts them),
# once per head: still stuck, MERGE_WAIT_MIN's needs-you follows. A gh error reading decides nothing.
queue_kick() {
  local n=$1 pr=$2 r id at oid c
  r=$(ghj api graphql -F o="${REPO%%/*}" -F r="${REPO#*/}" -F p="$pr" \
        -f query='query($o: String!, $r: String!, $p: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $p) { id mergeQueueEntry { state enqueuedAt headCommit { oid } } } } }' \
        -q '.data.repository.pullRequest | select(.mergeQueueEntry.state == "AWAITING_CHECKS") | "\(.id) \(.mergeQueueEntry.enqueuedAt) \(.mergeQueueEntry.headCommit.oid // "")"') || return 0
  read -r id at oid <<<"$r"
  [ -n "$id" ] && [ -n "$at" ] && (( $(now) - $(iso_epoch "$at") > ${NO_CHECKS_MIN:-10} * 60 )) || return 0
  if [ -n "$oid" ]; then
    c=$(ghj api "repos/$REPO/actions/runs?event=merge_group&head_sha=$oid&per_page=1" -q .total_count) || return 0
    [ "$c" = 0 ] || return 0
  fi
  st_set "$n" queue_kick="$head"
  mut gh api graphql -f id="$id" -f query='mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { clientMutationId } }' >/dev/null ||
    { log "#$n PR #$pr: its merge group has no runs, and the dequeue failed; MERGE_WAIT_MIN still applies"; return 0; }
  if ! mut_out gh api graphql -f id="$id" -f query='mutation($id: ID!) { enqueuePullRequest(input: {pullRequestId: $id}) { clientMutationId } }'; then
    needs_you "$n" "PR #$pr was dequeued to restart its merge group, but could not be enqueued again; add it to the merge queue by hand. gh: $(oneline 300 "$MUT_OUT")"
    return 0
  fi
  log "#$n PR #$pr: the merge queue started no merge_group run in ${NO_CHECKS_MIN:-10} min; dequeued and enqueued again"
}
