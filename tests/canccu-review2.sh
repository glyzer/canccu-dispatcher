#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-review2.sh — the lead's needs-work after a fix-check left open items: one more fix
# round and a fix-check, or a new full review. Kept apart from tests/canccu-review.sh so each file
# stays well under CI's per-file time limit (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# FINDING, sethead and fxenv: the fix-check fixtures in tests/lib/harness.sh

OPEN=$'1. src/a.ts:3 off by one — not fixed (src/a.ts:3 still uses <)\n\nReview verdict: changes '"$HB"
# nwenv <name> <lead's comment>: the fix-check of HA..HB left open items; the lead labels needs-work
nwenv() {
  fxenv "$1" "$OPEN"
  dispatch --once
  { issue 5 in-progress,needs-you,needs-work; } | issues
  json issue5.json "$(comment 2030-11-05T11:45:00Z "$2" | jq -s '{labels: [{name: "in-progress"}, {name: "needs-you"}, {name: "needs-work"}], comments: .}')"
  : > "$FAKE/gh.log"; : > "$FAKE/worker.log"
}
# fra <comments>: full_review_asked, from the pipeline part the dispatcher sources (lib has only common)
fra() { ( PATH="$fb:$PATH"; . "$root/lib/canccu-common.sh"; . "$root/lib/canccu-pipeline.sh"; full_review_asked "$1" ) 2>/dev/null; }
# fixed_to_hc: the resumed worker pushed its fix (HC), CI is green; the fix-check starts
fixed_to_hc() {
  rm -f "$WORKERS_DIR/web-5.lock"; last 5 "done" 'fixed it, CI green'; sethead "$HC"
  printf '1\t1\tsrc/a.ts\n' > "$FAKE/numstat"; : > "$FAKE/worker.log"
  dispatch --once
}
# fixcheck_passes: that fix-check wrote a pass on HC; the next pass posts and acts on it
fixcheck_passes() {
  rm -f "$WORKERS_DIR/web-review-50.lock"; last review-50 "done" "wrote it"
  printf '%s\n' $'1. fixed\n\nReview verdict: pass '"$HC" > "$CANCCU_HOME/reviews/50/$HC.md"
  touch -d "@$((NOW + 60))" "$CANCCU_HOME/reviews/50/$HC.md"
  : > "$FAKE/gh.log"; dispatch --once
}

# ---------------------------------------------------------------- one more fix round, then a fix-check

nwenv nw-fixcheck 'Only the off-by-one is left: use <= there.'
ok "fix-check changes: the head with open items is kept" eq "$(st 5 open_sha)" "$HB"
ok "… its open items are saved for a later fix-check" grep -qF 'src/a.ts:3 still uses <' "$CANCCU_HOME/reviews/50/$HB.open.md"
ok "… the needs-you names needs-work and the full review line" grep -qF 'with `needs-work`, a line `full review` in your comment asks for a new full review instead' "$CANCCU_HOME/dispatch.log"
dispatch --once
ok "needs-work after the fix-check: the worker resumes for one more fix round" \
  grep -q 'web 5 The user asked for one more fix round on PR #50 (needs-work) for the open items of its fix-check.*src/a.ts:3 still uses <.*Their comments: Only the off-by-one is left' "$FAKE/worker.log"
ok "… a narrow fix-check of this fix follows, the worker is told" grep -qF 'A narrow fix-check of this fix diff against those items follows' "$FAKE/worker.log"
ok "… needs-work removed" has gh.log "issue edit 5 -R example-org/web --remove-label needs-work"
ok "… still in the fix round, from the head with open items" eq "$(st 5 stage) $(st 5 reviewed_sha)" "fixing $HB"
ok "… the lead's comments join the items the fix-check checks" grep -qF 'Only the off-by-one is left' "$CANCCU_HOME/reviews/50/$HB.findings.md"
{ issue 5 in-progress; } | issues   # the labels the resume removed
fixed_to_hc
ok "… then a fix-check of the new diff" grep -qF "git diff $HB..$HC" "$FAKE/worker.log"
ok "… against those open items" grep -qF "The findings of the review of $HB: 1. src/a.ts:3 off by one — not fixed" "$FAKE/worker.log"
ok "… the lead's comments count as blocking items" grep -qF "the user's needs-work comments, each of them is a blocking item" "$FAKE/worker.log"
ok "… never a new full review" not grep -q 'You are the independent reviewer' "$FAKE/worker.log"
ok "… state: fix-check on the new head" eq "$(st 5 review_mode) $(st 5 review_sha)" "fixcheck $HC"
fixcheck_passes
ok "… its pass merges the new head" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HC"

# a second needs-work in the same extra round (CI red, say): the findings are rebuilt, never appended
nwenv nw-again 'Only the off-by-one is left: use <= there.'
dispatch --once
rm -f "$WORKERS_DIR/web-5.lock"; last 5 "done" 'CI red'
sed -i 's/^phase=.*/phase=needs-you/' "$CANCCU_HOME/state/5"; echo ny_stage=ci >> "$CANCCU_HOME/state/5"
{ issue 5 in-progress,needs-you,needs-work; } | issues
json issue5.json "$(jq -n --argjson a "$(comment 2030-11-05T11:45:00Z 'Only the off-by-one is left: use <= there.')" \
  --argjson b "$(comment 2030-11-05T12:10:00Z 'Also keep the test green.')" '{comments: [$a, $b]}')"
: > "$FAKE/worker.log"; dispatch --once
f="$CANCCU_HOME/reviews/50/$HB.findings.md"
ok "a second needs-work in the round: one more fix round again" eq "$(st 5 stage) $(st 5 reviewed_sha)" "fixing $HB"
ok "… the findings hold each comment once" eq "$(grep -c 'Only the off-by-one' "$f") $(grep -c 'Also keep the test green' "$f") $(grep -c 'still uses <' "$f")" "1 1 1"

# the open items were not saved: the findings point to the fix-check's PR comment
nwenv nw-no-items 'Only the off-by-one is left: use <= there.'
rm -f "$CANCCU_HOME/reviews/50/$HB.open.md"; dispatch --once
ok "open items not saved: the findings point to the fix-check's comment first" \
  grep -qF "Review verdict: changes $HB" <<<"$(head -1 "$CANCCU_HOME/reviews/50/$HB.findings.md")"

# ---------------------------------------------------------------- open_sha ends with a pass

fxenv nw-pass $'1. fixed\n\nReview verdict: pass '"$HB"
echo "open_sha=$HA" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "a pass clears open_sha" eq "$(st 5 open_sha)" ""

# the extra round's fix-check passes but its merge fails: open_sha is gone before the merge step,
# so the lead's later needs-work is a broader one → a new cycle, never a fix-check of old items
nwenv nw-merge-fail 'Only the off-by-one is left: use <= there.'
dispatch --once; { issue 5 in-progress; } | issues
fixed_to_hc
echo 'fail:pr merge' >> "$FAKE/routes"
fixcheck_passes
ok "extra round's fix-check pass, merge fails → needs-you" has gh.log "failed; merge it by hand or check the merge queue"
ok "… open_sha cleared before the merge step" eq "$(st 5 phase)|$(st 5 open_sha)" "needs-you|"
sed -i '/^fail:pr merge$/d' "$FAKE/routes"
{ issue 5 in-progress,needs-you,needs-work; } | issues
json issue5.json "$(comment 2030-11-05T13:00:00Z 'Merge main and look at the layout again.' | jq -s '{comments: .}')"
: > "$FAKE/worker.log"; dispatch --once
ok "… then needs-work: the worker resumes as before" grep -q 'web 5 The user rejected PR #50 (needs-work)' "$FAKE/worker.log"
ok "… not a fix round for the old items" not grep -q 'one more fix round' "$FAKE/worker.log"
ok "… a new cycle: the next review is a full one" eq "$(st 5 stage)|$(st 5 reviewed_sha)|$(st 5 open_sha)" "||"

# a fix-check's own Maintainer accept line, given with its changes, still holds after the extra
# round's fix-check passes without it: the PR waits for the accept, never auto-merges
fxenv nw-maccept $'Maintainer accept: breaking contract (renames screen.title)\n1. src/a.ts:3 still uses <\n\nReview verdict: changes '"$HB"
dispatch --once
ok "fix-check changes with a Maintainer accept line: its reason is kept" eq "$(st 5 review_maccept)" "breaking contract (renames screen.title)"
{ issue 5 in-progress,needs-you,needs-work; } | issues
json issue5.json "$(comment 2030-11-05T11:45:00Z 'Fix the rest.' | jq -s '{labels: [{name: "in-progress"}], comments: .}')"
dispatch --once; { issue 5 in-progress; } | issues
fixed_to_hc
fixcheck_passes
ok "… the extra round's pass without the line: waits for the accept" has gh.log "waits for your accept: maintainer accept: breaking contract (renames screen.title)."
ok "… no auto-merge" hasnt gh.log "pr merge 50 -R example-org/web --auto"

# ---------------------------------------------------------------- a new full review

# a gh error reading the lead's comments decides nothing: needs-work stays for the next pass
nwenv nw-gh-error $'Broader problems.\n\nFull review'
sed -i "1i issue view 5 -R example-org/web --json comments*\tFAIL" "$FAKE/routes"
dispatch --once
ok "gh error reading the comments: no resume" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… needs-work kept" hasnt gh.log "--remove-label needs-work"
ok "… the state is untouched" eq "$(st 5 phase) $(st 5 stage) $(st 5 open_sha)" "needs-you fixcheck $HB"
sed -i '1d' "$FAKE/routes"; dispatch --once
ok "… next pass: the full review line is read, a new cycle" eq "$(grep -c 'The user rejected PR #50' "$FAKE/worker.log")|$(st 5 stage)|$(st 5 open_sha)" "1||"

# the lead forces a full review with a `full review` line in the comment
nwenv nw-force $'Broader problems with the layout.\n\nFull review'
dispatch --once
ok "needs-work with a full review line: the worker resumes as before" grep -q 'web 5 The user rejected PR #50 (needs-work)' "$FAKE/worker.log"
ok "… a new cycle: the next review is a full one" eq "$(st 5 stage)|$(st 5 reviewed_sha)|$(st 5 open_sha)" "||"
# a quote-reply of the fix-check: its verdict line is quoted, the comment ends in the lead's own words
nwenv nw-quoted $'> 1. src/a.ts:3 still uses <\n>\n> Review verdict: changes '"$HB"$'\n\nFull review'
dispatch --once
ok "a quoted verdict line, then full review: the comment counts, a new cycle" \
  eq "$(grep -c 'The user rejected PR #50 (needs-work).*Full review' "$FAKE/worker.log")|$(st 5 stage)|$(st 5 open_sha)" "1||"
# a comment that ends in a verdict line is a verdict (posted as the user), never the lead's words
nwenv nw-verdict $'Full review\n\nReview verdict: changes '"$HB"
dispatch --once
ok "a comment ending in a verdict line is dropped: one more fix round" eq "$(st 5 stage) $(st 5 reviewed_sha)" "fixing $HB"
for m in 'full review' '**Full review.**' '`full review`' '  _FULL REVIEW!_  '; do
  ok "full review marker: '$m'" fra $'Something else.\n'"$m"
done
# the words inside a sentence are no marker
ok "full review marker: not inside a sentence" not fra 'No need for a full review, just fix it.'
nwenv nw-no-force 'No need for a full review, just fix the off-by-one.'
dispatch --once
ok "'full review' inside a sentence is no marker: one more fix round" eq "$(st 5 stage) $(st 5 reviewed_sha)" "fixing $HB"

# a merge that stopped after the fix round (needs-you at merge) is no fix-check's open items
fxenv nw-merge -
state 5 phase=needs-you ny_stage=merge pr=50 stage=fixcheck review_mode=fixcheck reviewed_sha=$HB open_sha=$HB \
  merge_sha=$HB "merge_at=$NOW" verdict_at=2030-11-05T11:30:00Z
{ issue 5 in-progress,awaiting-accept,needs-you,needs-work; } | issues
dispatch --once
ok "needs-work after a stopped merge: the worker resumes as before" grep -q 'web 5 The user rejected PR #50 (needs-work)' "$FAKE/worker.log"
ok "… a new cycle: the next review is a full one" eq "$(st 5 stage)|$(st 5 reviewed_sha)|$(st 5 open_sha)" "||"
ok "… awaiting-accept removed" has gh.log "issue edit 5 -R example-org/web --remove-label awaiting-accept"

# an accept refused for broader reasons still gets a new full review
fxenv nw-accept $'1. fixed\n\nReview verdict: pass '"$HB"
state 5 phase=accept pr=50 accept_sha=$HB "accept_at=$NOW" stage=fixcheck review_mode=fixcheck reviewed_sha=$HA \
  open_sha=$HB verdict_at=2030-11-05T11:30:00Z
{ issue 5 in-progress,awaiting-accept,needs-work; } | issues
dispatch --once
ok "needs-work on a refused accept: the worker resumes as before" grep -q 'web 5 The user rejected PR #50 (needs-work)' "$FAKE/worker.log"
ok "… a new cycle: the next review is a full one" eq "$(st 5 stage)|$(st 5 reviewed_sha)|$(st 5 open_sha)" "||"

echo "canccu-review2 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
