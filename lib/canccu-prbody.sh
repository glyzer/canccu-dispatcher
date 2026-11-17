# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by lib/canccu-pipeline.sh: the PR-body send-backs of check_pr. Each resumes the worker
# once to edit the body only (a fix kind, not a fix round of FIX_ATTEMPTS) and records the PR, so
# a second pass on the same PR never sends it back again.

# contract_closes <n> <pr> <pr_detail json>: the unit's contract PR is one GitHub links as closing
# an issue (its keywords count anywhere in the body, prose too): its merge would close the issue
# with only the contract done. It never reaches a review or an accept: the worker corrects the
# body once (body_fix; not a fix round of FIX_ATTEMPTS), then the user. 0 when it hit.
contract_closes() {
  local n=$1 pr=$2 j=$3 l
  is_contract_pr "$n" "$(jqr '.headRefName // ""' <<<"$j")" || return 1
  l=$(jqr '[.closingIssuesReferences[]?.number] | unique | map("#\(.)") | join(", ")' <<<"$j")
  [ -n "$l" ] || return 1
  if [ "$(st_get "$n" body_fix)" = "$pr" ]; then
    needs_you "$n" "PR #$pr is the contract PR but GitHub still links it as closing $l: edit the PR body so that no closing keyword stands before an issue number"
    return 0
  fi
  # a resume waits out the usage back-off and the pause, as the review does (0: nothing else runs)
  { backing_off || pause_holds; } && return 0
  room "$n" || return 0
  resume "$n" "PR #$pr is the contract PR, but GitHub links it as closing $l: its merge would close the issue with only the contract done. GitHub reads closing keywords anywhere in a PR body, prose included. Change the PR body only (gh pr edit $pr --body-file <file>): no close, closes, closed, fix, fixes, fixed, resolve, resolves or resolved before an issue number; write \`Refs ${l//, /, Refs }\` and \"the unit's own PR implements $l\". Change no file and push nothing. Then stop." fix || return 0
  st_set "$n" body_fix="$pr"
  log "#$n PR #$pr: the contract PR would close $l; the worker corrects the body"
}

# body_lines_missing <n> <pr> <pr_detail json>: the PR body lacks its Testing: or Revert: line
# (#192). The worker adds it once (body_lines), before any review; the same PR still without it
# goes on to the review, whose prompt names the missing line (a [criterion] finding), never to
# needs-you: a missing line is the worker's job. A contract or plan PR (by its body: Tier: plan)
# has no such lines. 0 when the worker was resumed (or waits for a slot, the back-off or the pause).
body_lines_missing() {
  local n=$1 pr=$2 j=$3 l
  is_contract_pr "$n" "$(jqr '.headRefName // ""' <<<"$j")" && return 1
  l=$(body_lacks "$(jqr '.body // ""' <<<"$j")")
  [ -n "$l" ] && [ "$(st_get "$n" body_lines)" != "$pr" ] || return 1
  # a plan PR by its body, as the review prompt tells it (an implementation PR may edit its plan file)
  is_plan_body "$(jqr '.body // ""' <<<"$j")" && return 1
  { backing_off || pause_holds; } && return 0
  room "$n" || return 0
  resume "$n" "PR #$pr needs \`Testing:\` and \`Revert:\` lines in its body (after Verification run:). Edit the body only (gh pr edit $pr --body-file <file>); no code change, no push. $BODY_LINES_RULE Then stop." fix || return 0
  st_set "$n" body_lines="$pr"
  log "#$n PR #$pr: body lacks Testing:/Revert:; the worker adds them"
}
