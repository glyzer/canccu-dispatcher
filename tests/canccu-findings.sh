#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Review findings (#73): only blocking findings start a fix round; the non-blocking ones go to one
# follow-up issue per wave (the fast lane shares one); canccu-status --findings counts the common ones.
. "$(dirname "$0")/lib/harness.sh"

BLOCK='1. src/a.ts:3 off by one; fix: use <='
NB=$'Non-blocking:\n- src/b.ts:9 the name `x` says nothing; rename it\n- docs/a.md:2 a typo'
# nbenv <name> <verdict> [config...]: PR 50 of issue 5 has a posted review with a blocking finding
# (in a changes verdict) and two non-blocking ones
nbenv() {
  local body
  env_new "$1" "${@:3}"
  { issue 5 in-progress; } | issues
  p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
  if [ "$2" = pass ]; then body="$NB"$'\n\nReview verdict: pass '"$HA"
  else body="$BLOCK"$'\n\n'"$NB"$'\n\nReview verdict: changes '"$HA"; fi
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "$body")")"
  route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
  state 5 phase=review pr=50 review_sha=$HA stage=review
}

# ---------------------------------------------------------------- the parsers

env_new parsers

ok "blocking_of: the findings without the Non-blocking section" eq "$(lib blocking_of "$BLOCK"$'\n\n'"$NB"$'\n\nReview verdict: changes x')" "$BLOCK"$'\n\nReview verdict: changes x'
ok "nonblocking_of: the section's items" eq "$(lib nonblocking_of "$BLOCK"$'\n\n'"$NB"$'\n\nReview verdict: changes x')" "${NB#Non-blocking:$'\n'}"
ok "… a heading (**Non-blocking:**) and items on its line count" eq "$(lib nonblocking_of $'**Non-blocking:** src/c.sh:1 a nit\n\nMaintainer accept: none')" "src/c.sh:1 a nit"
ok "… none is nothing" eq "$(lib nonblocking_of $'Non-blocking: none.\n\nReview verdict: pass x')" ""
ok "… no section is nothing" eq "$(lib nonblocking_of "$BLOCK")" ""
ok "… a later heading ends the section" eq "$(lib nonblocking_of $'## Non-blocking\n- a nit\n## Notes\nnot an item')" "- a nit"

# ---------------------------------------------------------------- a pass with non-blocking findings

nbenv pass-nb pass
dispatch --once
ok "a pass with non-blocking findings merges (no fix round)" eq "$(grep -c 'pr merge 50' "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "1 0"
ok "… a follow-up issue is created for them" eq "$(grep -c '^issue create -R example-org/web --title Follow-ups: non-blocking review findings (fast lane)' "$FAKE/gh.log")" 1
ok "… not ready" not grep -q 'issue create.*ready' "$FAKE/gh.log"
ok "… it names the PR and each finding's file:line" grep -q 'issue create.*PR #50.*src/b.ts:9 the name.*docs/a.md:2 a typo' "$FAKE/gh.log"
ok "… and is recorded" eq "$(cat "$CANCCU_HOME/followups")" $'fast\t900'
ok "… logged" grep -q '#5 PR #50: 2 non-blocking finding(s) filed in #900' "$CANCCU_HOME/dispatch.log"

# another fast-lane PR: the open follow-up issue gains its findings
nbenv pass-nb-shared pass
printf 'fast\t77\n' > "$CANCCU_HOME/followups"
{ issue 5 in-progress; issue 77 ""; } | issues
dispatch --once
ok "the fast lane shares one open follow-up issue: a comment on it" eq "$(grep -c '^issue comment 77 .*PR #50.*src/b.ts:9' "$FAKE/gh.log") $(grep -c 'issue create' "$FAKE/gh.log")" "1 0"

nbenv pass-nb-closed pass
printf 'fast\t77\n' > "$CANCCU_HOME/followups"
dispatch --once
ok "… a closed one is not reused: a new issue" eq "$(grep -c 'issue create' "$FAKE/gh.log") $(tail -1 "$CANCCU_HOME/followups")" $'1 fast\t900'

nbenv pass-nb-once pass
dispatch --once; state 5 phase=review pr=50 review_sha=$HA stage=review "nb_at=$(st 5 nb_at)"
dispatch --once
ok "a verdict's findings are filed once" eq "$(grep -c 'issue create' "$FAKE/gh.log")" 1

nbenv pass-wave pass
state 5 phase=review pr=50 review_sha=$HA stage=review step=12 wave=2 pkg=one members=5
dispatch --once
ok "a package's findings go to its wave's follow-up issue" grep -q '^issue create -R example-org/web --title Follow-ups: non-blocking review findings, step .* wave 2' "$FAKE/gh.log"
ok "… recorded per step and wave" eq "$(cut -f1 "$CANCCU_HOME/followups")" "step-12-wave-2"

nbenv pass-none pass
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z $'Non-blocking: none\n\nReview verdict: pass '"$HA")")"
dispatch --once
ok "no non-blocking findings: no follow-up issue" eq "$(grep -c 'issue create\|issue comment' "$FAKE/gh.log")" 0

# the unit is the recorded follow-up issue (#111): a comment there would be closed with it by the merge
nbenv pass-nb-self pass
p=$(pr 50 5 $HA | jq -c '.closingIssuesReferences = []'); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "$NB"$'\n\nReview verdict: pass '"$HA")")"
printf 'fast\t5\n' > "$CANCCU_HOME/followups"
dispatch --once
ok "the unit is the recorded follow-up issue: a new issue, no comment on itself" eq "$(grep -c 'issue create' "$FAKE/gh.log") $(grep -c '^issue comment 5 ' "$FAKE/gh.log")" "1 0"
ok "… the new one is recorded" eq "$(cat "$CANCCU_HOME/followups")" $'fast\t900'

nbenv pass-nb-closes pass
p=$(pr 50 5 $HA | jq -c '.closingIssuesReferences += [{number: 77}]'); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "$NB"$'\n\nReview verdict: pass '"$HA")")"
printf 'fast\t77\n' > "$CANCCU_HOME/followups"
{ issue 5 in-progress; issue 77 ""; } | issues
dispatch --once
ok "the PR closes the recorded follow-up issue: a new issue, no comment on it" eq "$(grep -c 'issue create' "$FAKE/gh.log") $(grep -c '^issue comment 77 ' "$FAKE/gh.log")" "1 0"
ok "… the new one is recorded" eq "$(cat "$CANCCU_HOME/followups")" $'fast\t900'

# the log counts items, not lines: an item's indented Fix: line is part of it
NB5=$'Non-blocking:'; for i in 1 2 3 4 5; do NB5+=$'\n'"$i. src/b.ts:$i a nit"$'\n   - Fix: rename it'; done
nbenv pass-nb-count pass
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "$NB5"$'\n\nReview verdict: pass '"$HA")")"
dispatch --once
ok "5 numbered items with a Fix: line each: 5 findings logged" grep -q '#5 PR #50: 5 non-blocking finding(s) filed in #900' "$CANCCU_HOME/dispatch.log"

# ---------------------------------------------------------------- changes: only the blocking ones

nbenv changes-nb changes
dispatch --once
l=$(grep -- '--name #5 ' "$FAKE/worker.log" | tail -1)
ok "a changes verdict sends the blocking findings to the fix run" grep -qF 'src/a.ts:3 off by one' <<<"$l"
ok "… not the non-blocking ones" not grep -qF 'src/b.ts:9' <<<"$l"
ok "… the fix-check checks only the blocking ones" eq "$(grep -c 'src/b.ts' "$CANCCU_HOME/reviews/50/$HA.findings.md") $(grep -c 'src/a.ts:3' "$CANCCU_HOME/reviews/50/$HA.findings.md")" "0 1"
ok "… the non-blocking ones go to the follow-up issue" grep -q 'issue create.*src/b.ts:9' "$FAKE/gh.log"

# ---------------------------------------------------------------- the report

env_new report
mkdir -p "$CANCCU_HOME/reviews/50" "$CANCCU_HOME/reviews/51" "$CANCCU_HOME/reviews/52"
printf '1. **Missing test** — src/a.ts:3 the new branch has no test\n\nNon-blocking:\n- src/b.ts:9 Comment restates the code.\n\nReview verdict: changes %s\n' "$HA" > "$CANCCU_HOME/reviews/50/$HA.md"
printf '1. src/c.ts:12 missing test: the error path\n- lib/x.sh:4: comment restates the code\n\nReview verdict: changes %s\n' "$HB" > "$CANCCU_HOME/reviews/51/$HB.md"
printf 'Non-blocking:\n- src/a.ts:8 comment restates the code\n\nReview verdict: pass %s\n' "$HC" > "$CANCCU_HOME/reviews/52/$HC.md"
echo 'not a review' > "$CANCCU_HOME/reviews/50/$HA.findings.md"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" --findings 2>&1)
ok "canccu-status --findings: the most common finding first, with its count and PRs" grep -qx '  3× comment restates the code (#50, #51, #52)' <<<"$(sed -n 2p <<<"$out")"
ok "… then the next" grep -qx '  2× missing test (#50, #51)' <<<"$(sed -n 3p <<<"$out")"
ok "… the files cited most" grep -qx '  2× src/a.ts' <<<"$out"
ok "… the review records only (not the saved findings)" not grep -q 'not a review' <<<"$out"
env_new report-empty
ok "… no review records: says so" grep -q 'no review records' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" --findings 2>&1)"

echo "canccu-findings tests: $npass passed, $nfail failed"
(( nfail == 0 ))
