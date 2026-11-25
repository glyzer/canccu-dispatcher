#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-verdict.sh — the dispatcher decides what blocks (#190, contracts §8): finding classes,
# Evidence:, Pre-existing:, the count line, the rewritten verdict and reviews.log.
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# review <verdict> <"b n p"> [blocking items] [non-blocking items] [pre-existing items]: a review
# file in the shape of §8 for head VH (default HA), with prose above the block
review() {
  printf 'I read the diff and ran the checks.\n\nBlocking:\n%s\nNon-blocking:\n%s\nPre-existing:\n%s\nFindings: %s blocking, %s non-blocking, %s pre-existing\nReview verdict: %s %s\n' \
    "${3:-none}" "${4:-none}" "${5:-none}" $2 "$1" "${VH:-$HA}"
}
DEMOTED=$'1. [style] src/a.ts:3 — the name says nothing\n   Evidence: the line `let x = 1`\n   Fix: rename it\n2. src/b.ts:4 — no class on this one\n   Evidence: it reads a closed file\n   Fix: open it first\n3. [correctness] src/c.ts:5 — off by one, no evidence\n   Fix: use <='
VALID=$'4. [correctness] src/d.ts:6 — the loop skips the last item\n   Evidence: [1,2,3] sums to 3, not 6\n   Fix: loop to <= n'
NBI='- [docs] docs/a.md:2 — a typo'
PRE='- [security] src/old.ts:9 — the token is logged (not in this diff)'

# venv <name> <file content | -> [config...]: the review run of PR 50 (issue 5) at VH (default
# HA) has ended and left that review file; venv_at the same in the environment already made
venv() { env_new "$1" "${@:3}"; venv_at "$2"; }
venv_at() {
  local h=${VH:-$HA}
  { issue 5 in-progress; } | issues
  p=$(pr 50 5 "$h"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
  state 5 phase=review pr=50 "review_sha=$h" "started=$NOW" rounds=0
  last review-50 "done" "wrote the review"
  RF=$CANCCU_HOME/reviews/50/$h.md; mkdir -p "${RF%/*}"
  if [ "$1" != - ]; then printf '%s\n' "$1" > "$RF"; touch -d "@$((NOW + 60))" "$RF"; fi
}

# ---------------------------------------------------------------- the parser and the effective verdict

env_new parse
F=$E/review.md
review changes "3 0 0" "$DEMOTED" > "$F"
ok "review_parse: each item with its section, class, file, line and Evidence:, then the count line" \
  eq "$(lib review_parse "$F")" "$(printf 'blocking\tstyle\tsrc/a.ts\t3\t1\nblocking\t-\tsrc/b.ts\t4\t1\nblocking\tcorrectness\tsrc/c.ts\t5\t0\ncount\t3\t0\t0')"
ok "a style item, an unclassed one and one without Evidence: → pass, all 3 demoted" \
  eq "$(lib review_effective "$F" "$HA")" "pass 0 0 0 3 -"
ok "… file_verdict reads the effective verdict" eq "$(lib file_verdict "$F" "$HA")" pass
ok "… blocking_of has nothing left" eq "$(lib blocking_of "$(cat "$F")")" ""
ok "… the demoted items go to the follow-up with the rest" eq "$(lib nonblocking_of "$(cat "$F")")" "$DEMOTED"

review changes "4 1 1" "$DEMOTED"$'\n'"$VALID" "$NBI" "$PRE" > "$F"
ok "one valid [correctness] item with Evidence: → changes 1, the classes left" \
  eq "$(lib review_effective "$F" "$HA")" "changes 1 1 1 3 correctness"
ok "… blocking_of returns only it" eq "$(lib blocking_of "$(cat "$F")")" "$VALID"
ok "… nonblocking_of: the demoted, the non-blocking and the pre-existing items" \
  eq "$(lib nonblocking_of "$(cat "$F")")" "$DEMOTED"$'\n'"$NBI"$'\n'"$PRE"
ok "… a pre-existing security item is seen" lib preexisting_security "$(cat "$F")"
ok "… findings_count: the blocking left, then every other item" eq "$(lib findings_count "$F" "$HA")" "1 5"

review pass "0 0 1" "" "" "$PRE" > "$F"
ok "a Pre-existing: [security] item → pass" eq "$(lib review_effective "$F" "$HA")" "pass 0 0 1 0 -"
review pass "1 0 0" "$VALID" > "$F"
ok "a reviewer's pass with a blocking item left → changes" eq "$(lib review_effective "$F" "$HA")" "changes 1 0 0 0 correctness"

review changes "2 0 0" "$VALID" > "$F"
ok "a count line that does not match the items → nothing" eq "$(lib review_effective "$F" "$HA")" ""
ok "… so no file verdict" eq "$(lib file_verdict "$F" "$HA")" ""
printf 'Blocking:\n%s\nReview verdict: changes %s\n' "$VALID" "$HA" > "$F"
ok "no count line → nothing" eq "$(lib review_effective "$F" "$HA")" ""
review changes "1 0 0" "$VALID" > "$F"
ok "a verdict for another head → nothing" eq "$(lib review_effective "$F" "$HB")" ""
printf '**Blocking:** none\n**Non-blocking:**\n- [style] a.sh:1 — x\n**Findings:** 0 blocking, 1 non-blocking, 0 pre-existing\n**Review verdict: pass %s**\n' "$HA" > "$F"
ok "markdown marks around the headings and the lines count" eq "$(lib review_effective "$F" "$HA")" "pass 0 1 0 0 -"

# ---------------------------------------------------------------- the dispatcher rewrites and posts

venv demote "$(review changes "3 0 0" "$DEMOTED")"
dispatch --once
ok "a changes whose blocking items are all demoted is posted as pass" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: pass $HA"
ok "… with the dispatcher line above the verdict line" \
  eq "$(tail -2 "$FAKE/posted-50" | head -1)" "Dispatcher: no blocking finding left (3 moved out of Blocking: never-blocking class, no class or no Evidence:); verdict pass."
ok "… the file says the same" eq "$(cat "$RF")" "$(cat "$FAKE/posted-50")"
ok "… acted on as a pass: auto-merge, no fix round" eq "$(grep -c '^pr merge 50' "$FAKE/gh.log") $(grep -c 'asked for changes' "$FAKE/worker.log")" "1 0"
ok "… reviews.log: one line, 11 tab-separated columns" eq "$(awk -F '\t' '{ print NF }' "$CANCCU_HOME/reviews.log")" 11
ok "… in the format of §8" eq "$(cat "$CANCCU_HOME/reviews.log")" "$(printf '2030-11-05T12:00:00Z\t50\t%s\tfull\tpass\t0\t0\t0\t3\t-\t0' "$HA")"

NOEV=$'1. [correctness] src/c.ts:5 — off by one, no evidence\n   Fix: use <='
venv brake-line "$(review pass "1 0 0" "$NOEV")"
touch "$CANCCU_HOME/brake"
dispatch --once
ok "the brake on: the dispatcher line does not ask for Evidence:" \
  eq "$(tail -2 "$FAKE/posted-50" | head -1)" "Dispatcher: 1 blocking finding(s) left (a blocking class); verdict changes."

venv valid "$(review changes "4 0 0" "$DEMOTED"$'\n'"$VALID")"
dispatch --once
ok "one valid blocking item: posted as the reviewer wrote it" eq "$(cat "$FAKE/posted-50")" "$(review changes "4 0 0" "$DEMOTED"$'\n'"$VALID")"
# numbered as the first finding left, its list mark dropped (#229)
VALIDN="Finding 1: ${VALID#4. }"
ok "… the fix round gets only that item" grep -qF "The blocking findings: $(lib oneline 999 "$VALIDN") (also in" "$FAKE/worker.log"
ok "… none of the demoted ones" not grep -q 'src/a.ts:3\|src/c.ts:5' "$FAKE/worker.log"
ok "… the findings file holds only it" eq "$(cat "$CANCCU_HOME/reviews/50/$HA.findings.md")" "$VALIDN"
ok "… the demoted items go to the follow-up issue" grep -q '^issue create .*src/a.ts:3.*src/b.ts:4.*src/c.ts:5' "$FAKE/gh.log"
ok "… reviews.log: changes 1, the class left" eq "$(cut -f4- "$CANCCU_HOME/reviews.log")" "$(printf 'full\tchanges\t1\t0\t0\t3\tcorrectness\t0')"

venv pre-security "$(review pass "0 1 1" "" "$NBI" "$PRE")"
printf '901\n900\n' > "$FAKE/new-issues"
dispatch --once
ok "a Pre-existing: [security] item: the PR passes" eq "$(grep -c '^pr merge 50' "$FAKE/gh.log")" 1
ok "… the item gets an issue of its own, labelled security (#223)" \
  grep -q '^issue create -R example-org/web --title Security (pre-existing): \[security\] src/old.ts:9 .*--label security --body .*PR #50' "$FAKE/gh.log"
ok "… the follow-up ticket's line links it; the ticket's label is follow-up, not security" \
  eq "$(grep -cxF -- "- [ ] ${PRE#- } (security: #901)" "$FAKE/created-900") $(grep -c -- '--title Follow-ups.*--label follow-up' "$FAKE/gh.log") $(grep -c -- '--title Follow-ups.*--label security' "$FAKE/gh.log")" "1 1 0"
ok "security is one of the dispatcher's labels" grep -qw security <<<"$(lib eval 'echo $CANCCU_LABELS')"

venv pre-security-comment "$(review pass "0 0 1" "" "" "$PRE")"
printf 'fast\t77\n' > "$CANCCU_HOME/followups"
{ issue 5 in-progress; issue 77 ""; } | issues
dispatch --once
ok "… an open follow-up ticket: its line links the item's issue, no label on the ticket" \
  eq "$(grep -cxF -- "- [ ] ${PRE#- } (security: #900)" "$FAKE/body-77") $(grep -c -- '--add-label security' "$FAKE/gh.log")" "1 0"

venv no-security "$(review pass "0 1 0" "" "$NBI")"
dispatch --once
ok "no pre-existing security item: no security label" not grep -q -- '--label security\|--add-label security' "$FAKE/gh.log"

venv count-mismatch "$(review changes "2 0 0" "$VALID")"
dispatch --once
ok "a count line 2 blocking with one item: nothing posted" hasnt gh.log "pr comment"
ok "… one file retry, with the reason" \
  eq "$(grep -c -- '--keep-session .*the count line does not match the items' "$FAKE/worker.log") $(st 5 file_retry)" "1 $HA"
ok "… logged as no valid verdict's reason" grep -qF "the reviewer left a file: the count line does not match the items; asked once to write the review file" "$CANCCU_HOME/dispatch.log"
ok "… no reviews.log line" eq "$(test -e "$CANCCU_HOME/reviews.log" && echo log)" ""

venv postpass "$(review pass "0 0 0")"
echo review_mode=postpass >> "$CANCCU_HOME/state/5"
dispatch --once
ok "a post-pass check is logged as fixcheck" eq "$(cut -f4 "$CANCCU_HOME/reviews.log")" fixcheck

# ---------------------------------------------------------------- no repeats (#191)

# item <class> <file:line>: one blocking item with its Evidence:
item() { printf '1. [%s] %s — the guard is missing\n   Evidence: an empty list crashes\n   Fix: check it first' "$1" "$2"; }
HIST=$'%s\tcorrectness\ta.sh\t10-12\tfixed\n'

env_new parse-range
F=$E/review.md
review changes "1 0 0" "$(item correctness a.sh:10-12)" > "$F"
ok "review_parse: a line range a-b is kept whole" eq "$(lib review_parse "$F" | head -1)" "$(printf 'blocking\tcorrectness\ta.sh\t10-12\t1')"

venv settled "$(review changes "1 0 0" "$(item correctness a.sh:11)")"
printf "$HIST" "$HB" > "$CANCCU_HOME/reviews/50/history"
dispatch --once
ok "a [correctness] a.sh:10-12 fixed earlier, raised again at a.sh:11: posted as pass" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: pass $HA"
ok "… the dispatcher line names it already settled" \
  eq "$(tail -2 "$FAKE/posted-50" | head -1)" "Dispatcher: no blocking finding left (1 moved out of Blocking: 1 already settled); verdict pass."
ok "… no fix round, auto-merge" eq "$(grep -c '^pr merge 50' "$FAKE/gh.log") $(grep -c 'asked for changes' "$FAKE/worker.log")" "1 0"
ok "… reviews.log counts it demoted" eq "$(cut -f5- "$CANCCU_HOME/reviews.log")" "$(printf 'pass\t0\t0\t0\t1\t-\t0')"
ok "… the history keeps the settled line and adds none" eq "$(cat "$CANCCU_HOME/reviews/50/history")" "$(printf "$HIST" "$HB")"

venv settled-elsewhere "$(review changes "1 0 0" "$(item correctness a.sh:40)")"
printf "$HIST" "$HB" > "$CANCCU_HOME/reviews/50/history"
dispatch --once
ok "the same finding at a.sh:40 still blocks: posted as changes" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: changes $HA"
ok "… the fix round starts" grep -q 'asked for changes' "$FAKE/worker.log"
ok "… the history gets its open line" eq "$(tail -1 "$CANCCU_HOME/reviews/50/history")" "$(printf '%s\tcorrectness\ta.sh\t40\topen' "$HA")"

venv settled-other-class "$(review changes "1 0 0" "$(item security a.sh:11)")"
printf "$HIST" "$HB" > "$CANCCU_HOME/reviews/50/history"
printf '%s\tcorrectness\ta.sh\t11\topen\n' "$HB" >> "$CANCCU_HOME/reviews/50/history"
dispatch --once
ok "another class on the same lines, and an open line, do not settle it" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: changes $HA"

# the pass rule: the PR passed at MB_B; MB_PC appends line 5 of a.txt
env_new unchanged; mmrepo; VH=$MB_PC venv_at "$(VH=$MB_PC review changes "1 0 0" "$(item correctness a.txt:2)")"
echo "pass_sha=$MB_B" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "after a pass, a full review's finding on a line unchanged since: posted as pass" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: pass $MB_PC"
ok "… the dispatcher line names it unchanged since the pass" \
  eq "$(tail -2 "$FAKE/posted-50" | head -1)" "Dispatcher: no blocking finding left (1 moved out of Blocking: 1 unchanged since the pass); verdict pass."

env_new unchanged-security; mmrepo; VH=$MB_PC venv_at "$(VH=$MB_PC review changes "1 0 0" "$(item security a.txt:2)")"
echo "pass_sha=$MB_B" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "… the same as [security] blocks" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: changes $MB_PC"

env_new changed-line; mmrepo; VH=$MB_PC venv_at "$(VH=$MB_PC review changes "1 0 0" "$(item correctness a.txt:5)")"
echo "pass_sha=$MB_B" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "… a finding on the line changed since the pass blocks" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: changes $MB_PC"

env_new unchanged-fixcheck; mmrepo; VH=$MB_PC venv_at "$(VH=$MB_PC review changes "1 0 0" "$(item correctness a.txt:2)")"
printf 'pass_sha=%s\nreview_mode=postpass\nstage=fixcheck\n' "$MB_B" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "… a fix-check is not under the pass rule" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: changes $MB_PC"

# the history's outcomes
env_new history
H=$CANCCU_HOME/reviews/50/history; mkdir -p "${H%/*}"
printf '%s\tcorrectness\ta.sh\t10-12\topen\n%s\ttest\tb.sh\t3\topen\n' "$HA" "$HA" > "$H"
state 5 phase=review pr=50 review_mode=fixcheck
lib history_record 5 50 "$HB" "$(VH=$HB review changes "1 0 0" "$(item test b.sh:3)")" 2030-11-05T11:00:00Z
ok "a fix-check: the earlier item it does not raise again is fixed, the one it raises stays open, its own is added" \
  eq "$(cat "$H")" "$(printf '%s\tcorrectness\ta.sh\t10-12\tfixed\n%s\ttest\tb.sh\t3\topen\n%s\ttest\tb.sh\t3\topen' "$HA" "$HA" "$HB")"
lib history_record 5 50 "$HB" "$(VH=$HB review changes "1 0 0" "$(item test b.sh:3)")" 2030-11-05T11:00:00Z
ok "… once per verdict" eq "$(wc -l < "$H")" 3
lib history_answer 50
ok "an accept or a needs-work answers every open item" eq "$(cut -f5 "$H" | tr '\n' ' ')" "fixed answered answered "

# both prompts carry the history as data, and the rule
venv prompts -
printf "$HIST" "$HB" > "$CANCCU_HOME/reviews/50/history"
for kind in review fixcheck; do
  if [ $kind = review ]; then out=$(lib review_prompt 50 5 "$HA" /f high); else out=$(lib fixcheck_prompt 50 5 "$HA" "$HB" /f low "x"); fi
  ok "the $kind prompt has the PR's history with its outcomes" grep -qF "${HB:0:7} [correctness] a.sh:10-12 fixed" <<<"$out"
  ok "… and the no-repeat rule" grep -qF 'same class and file on overlapping lines as one there that is `fixed` or `answered` is not raised again' <<<"$out"
done
echo "pass_sha=$HB" >> "$CANCCU_HOME/state/5"
ok "after a pass, the full review's prompt has the pass rule" \
  grep -qF "raise nothing new on lines git diff $HB..$HA did not change, except a \`security\` bug" <<<"$(lib review_prompt 50 5 "$HA" /f high)"

echo "canccu-verdict tests: $npass passed, $nfail failed"
(( nfail == 0 ))
