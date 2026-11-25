#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-reviewcli.sh — bin/canccu-review on a PR that closes several issues: which issue's
# branch form and refusal count (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# manyenv <name> <managed issue...>: PR 60 closes #14, #15, #16 from the branch MANY_BRANCH
manyenv() {
  env_new "$1"; shift
  { issue 14 in-progress; issue 15 in-progress; issue 16 in-progress; } | issues
  p=$(PR_BRANCH=${MANY_BRANCH:-16-thing} pr 60 16 $HA | jq '.closingIssuesReferences = [{number: 14}, {number: 15}, {number: 16}]')
  printf '%s\n' "$p" | prs; json pr60.json "$(detail "$p" x)"; route 'pr view 60 *' pr60.json
  for n in "$@"; do state "$n" phase=check "check_at=$NOW" pr=60; done
  PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 60 > "$E/out" 2>&1
}

manyenv many-plain 14 15 16
ok "a branch 16-…: the branch's issue is reviewed, not the lowest" grep -q -- '--key review-60' "$FAKE/worker.log"
MANY_BRANCH=issue-16-thing manyenv many-issue-form 14 15 16
ok "the branch form issue-<n>-…: the branch's issue is taken as well" grep -q -- '--key review-60' "$FAKE/worker.log"
MANY_BRANCH=99-thing manyenv many-elsewhere 15 16
ok "a branch whose issue the PR does not close: the lowest issue's refusal is shown" \
  grep -qF 'refused: not ours: PR #60 branch 99-thing is not 14-…' "$E/out"
ok "… and nothing starts" eq "$(wc -l < "$FAKE/worker.log")" 0

echo "canccu-reviewcli tests: $npass passed, $nfail failed"
(( nfail == 0 ))
