#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-reviewfix.sh — one full review per PR cycle (#325): a full review's `changes` with no
# review fix run left is owed, and the lead's comment continues it as a fix run and a fix-check;
# review fixes have their own budget, REVIEW_FIX_ATTEMPTS, apart from red-CI fixes (#326)
# (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# FINDING, sethead: the fix-check fixtures in tests/lib/harness.sh
fixround() { grep -c 'This is your one fix round' "$FAKE/worker.log"; }
# owed <name> [config...]: the full review of HA asked for changes with no review fix run left;
# the pass parked it at needs-you
owed() {
  review_env "$1" 'Review verdict: changes' review REVIEW_FIX_ATTEMPTS=0 FIX_MODEL=claude-sonnet-5-5 MODEL=claude-opus-5-5 "${@:2}"
  dispatch --once
}
# lead_says <comment>: the lead comments on the issue after the needs-you
lead_says() {
  { issue 5 in-progress,needs-you; } | issues
  json issue5.json "$(comment 2030-11-05T12:10:00Z "$1" | jq -s '{labels: [{name: "in-progress"}, {name: "needs-you"}], comments: .}')"
  : > "$FAKE/gh.log"; : > "$FAKE/worker.log"; : > "$FAKE/worker.envdump"
  CANCCU_NOW=$((NOW + 1200)) dispatch --once
}
# pushed <head> <numstat>: the resumed worker pushed head, CI green; the next pass reviews it
pushed() {
  { issue 5 in-progress; } | issues
  rm -f "$WORKERS_DIR/web-5.lock"; last 5 "done" 'fixed it, CI green'; sethead "$1"
  printf '%s\n' "$2" > "$FAKE/numstat"; : > "$FAKE/worker.log"
  touch -d "@$((NOW + 1800))" "$WORKERS_DIR/web-5.last"
  CANCCU_NOW=$((NOW + 1800)) dispatch --once
}
fullreview() { grep -c 'You are the independent reviewer' "$FAKE/worker.log"; }
fixcheck() { grep -c 'You run the FIX-CHECK' "$FAKE/worker.log"; }

# ---------------------------------------------------------------- #325: the owed round

owed owed-comment
ok "changes, no review fix run left → needs-you, no fix run" eq "$(st 5 phase) $(fixround)" "needs-you 0"
ok "… the round is owed: fix stage on the reviewed head" eq "$(st 5 stage) $(st 5 reviewed_sha) $(st 5 fix_owed)" "fixing $HA 1"
ok "… its blocking findings saved" grep -qF 'src/a.ts:3 off by one' "$CANCCU_HOME/reviews/50/$HA.findings.md"
ok "… the needs-you says what a comment does" has gh.log 'the worker fixes the review'"'"'s blocking findings and your comment'"'"'s items, then a fix-check'
lead_says 'Keep the old name for the flag.'
ok "the lead's comment → a fix run on FIX_MODEL (run type fix)" \
  eq "$(grep -c -- '^--quiet --model claude-sonnet-5-5 .*this is the review'"'"'s fix round' "$FAKE/worker.log") $(grep -c '^WORKER_RUN_TYPE=fix$' "$FAKE/worker.envdump")" "1 1"
ok "… with the saved findings and the comment" grep -q 'The blocking findings: 1. src/a.ts:3 off by one.*The user'"'"'s comments: Keep the old name for the flag.' "$FAKE/worker.log"
ok "… not the plain answer resume" not grep -q 'The user answered' "$FAKE/worker.log"
ok "… still the fix round of HA, no longer owed, counted as a review fix" \
  eq "$(st 5 stage) $(st 5 reviewed_sha) [$(st 5 fix_owed)] $(st 5 fix_cont) $(st 5 rfixes) [$(st 5 fixes)]" "fixing $HA [] 1 1 [0]"
ok "… the comment joins the items the fix-check checks" grep -qF 'Keep the old name for the flag.' "$CANCCU_HOME/reviews/50/$HA.findings.md"
pushed "$HC" $'3\t1\tsrc/a.ts'
ok "its push → a fix-check of HA..HC, no full review" eq "$(fixcheck) $(fullreview) $(grep -c "git diff $HA..$HC" "$FAKE/worker.log")" "1 0 1"
ok "… the fix-check's prompt has the findings and the lead's comment as items" \
  grep -q "The findings of the review of $HA: 1. src/a.ts:3 off by one.*Keep the old name for the flag." "$FAKE/worker.log"

owed owed-full
lead_says $'Rethink the parser.\nfull review'
ok "a \`full review\` line → no fix run of the owed round" eq "$(grep -c "review's fix round" "$FAKE/worker.log") $(grep -c 'The user answered' "$FAKE/worker.log")" "0 1"
ok "… the round is dropped" eq "[$(st 5 fix_owed)] $(st 5 stage) [$(st 5 reviewed_sha)] $(st 5 review_asked)" "[] review [] 1"
pushed "$HC" $'3\t1\tsrc/a.ts'
ok "… its push → a full review" eq "$(fullreview) $(fixcheck)" "1 0"

owed owed-big
lead_says 'Rename it everywhere.'
pushed "$HC" $'150\t20\tsrc/a.ts'
ok "the continued round's fix over FIXCHECK_FULL_LINES → a full review" eq "$(fullreview) $(fixcheck)" "1 0"
ok "… logged with the count" grep -qF '#5 PR #50: the fix after the review changed 170 changed lines, over FIXCHECK_FULL_LINES=100; full review' "$CANCCU_HOME/dispatch.log"

owed owed-needs-work
{ issue 5 in-progress,needs-you,needs-work; } | issues
json issue5.json "$(comment 2030-11-05T12:10:00Z 'Use the shared helper.' | jq -s '{labels: [{name: "in-progress"}, {name: "needs-you"}, {name: "needs-work"}], comments: .}')"
: > "$FAKE/worker.log"; CANCCU_NOW=$((NOW + 1200)) dispatch --once
ok "needs-work on the owed round → the same fix run, needs-work removed" \
  eq "$(grep -c "review's fix round.*Use the shared helper" "$FAKE/worker.log") $(grep -c 'issue edit 5 -R example-org/web --remove-label needs-work' "$FAKE/gh.log") $(st 5 stage)" "1 1 fixing"

# ---------------------------------------------------------------- #325: merges of main never count

env_new merge-lines
d=$E/code/web
_g() { GIT_AUTHOR_DATE=2030-11-05T10:00:00Z GIT_COMMITTER_DATE=2030-11-05T10:00:00Z \
       "$FAKE_REAL_GIT" -C "$d" -c user.name=octo -c user.email=octo@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
rev() { "$FAKE_REAL_GIT" -C "$d" rev-parse "$1"; }
rm -rf "$d"; mkdir -p "$d"; _g init
seq 1 10 > "$d/a.txt"; echo b > "$d/b.txt"; _g add .; _g commit -m root
_g checkout -b pr; sed -i 's/^1$/pr-one/' "$d/a.txt"; _g commit -am "the PR"; P=$(rev HEAD)
# main: 200 lines into the PR's own file, clean against the PR's change
_g checkout main; seq 101 300 >> "$d/a.txt"; _g commit -am "main grows"; M1=$(rev HEAD)
_g checkout pr; _g merge --no-edit main; C1=$(rev HEAD)
# main again: its first line too, so the next merge conflicts; resolved keeping both, plus 200 lines
_g checkout main; sed -i 's/^1$/main-one/' "$d/a.txt"; seq 301 500 >> "$d/a.txt"; _g commit -am "main again"
_g checkout pr; _g merge --no-edit main; sed -i '/^<<<<<<<\|^=======\|^>>>>>>>/d' "$d/a.txt"; _g commit -am "merge main, resolved"; C2=$(rev HEAD)
_g update-ref refs/remotes/origin/main main
# the PR's own change: 150 lines
seq 1 150 > "$d/c.txt"; _g add c.txt; _g commit -m "a big fix"; C3=$(rev HEAD)
touch "$FAKE/realgit"
# FIXCHECK_COUNT_RESOLVED=1: its default (lib/canccu-config.default), which the harness does not load
mm() { lib eval ". '$root/lib/canccu-merge.sh'; FIXCHECK_COUNT_RESOLVED=1; $1 $2 $3"; }
ok "a clean merge of main (200 lines) after a pass → no full review" eq "[$(mm postpass_full "$P" "$C1")]" "[]"
ok "… after a review's changes → none either" eq "[$(mm own_lines_over "$P" "$C1")]" "[]"
ok "a merge of main with its conflict resolved (400 lines in all) after a pass → no full review" eq "[$(mm postpass_full "$P" "$C2")]" "[]"
ok "… after a review's changes → none either" eq "[$(mm own_lines_over "$P" "$C2")]" "[]"
ok "the PR's own 150 lines since the review → a full review" eq "$(mm own_lines_over "$C2" "$C3")" "150 changed lines, over FIXCHECK_FULL_LINES=100"
ok "… after a pass too, as before" eq "$(mm postpass_full "$C2" "$C3")" "150 changed lines, over FIXCHECK_FULL_LINES=100"
: "$M1"

# ---------------------------------------------------------------- #326: the review fix budget

review_env ci-spent 'Review verdict: changes' review FIX_MODEL=claude-sonnet-5-5 MODEL=claude-opus-5-5
state 5 phase=review pr=50 review_sha=$HA stage=review fixes=2 fixes_pr=50
dispatch --once
ok "2 CI fix runs, then a review's changes → its fix run on FIX_MODEL, no needs-you" \
  eq "$(grep -c -- '^--quiet --model claude-sonnet-5-5 .*This is your one fix round' "$FAKE/worker.log") $(grep -c 'needs-you' "$FAKE/gh.log")" "1 0"
ok "… counted as a review fix, the CI count kept" eq "$(st 5 rfixes) $(st 5 fixes) $(st 5 fixes_pr)" "1 2 50"
sethead "$HC"; printf '1\t1\tsrc/a.ts\n' > "$FAKE/numstat"; : > "$FAKE/worker.log"
rm -f "$WORKERS_DIR/web-5.lock"; last 5 "done" 'fixed it'; dispatch --once
ok "… then a fix-check" eq "$(fixcheck) $(fullreview)" "1 0"

review_env review-zero 'Review verdict: changes' review REVIEW_FIX_ATTEMPTS=0
state 5 phase=review pr=50 review_sha=$HA stage=review
dispatch --once
ok "REVIEW_FIX_ATTEMPTS=0: a review's changes → needs-you as before" eq "$(fixround) $(st 5 phase)" "0 needs-you"
ok "… naming the setting" has gh.log "no automatic review fix run is left (0 per PR, REVIEW_FIX_ATTEMPTS)"

review_env review-other-pr 'Review verdict: changes' review
state 5 phase=review pr=50 review_sha=$HA stage=review fixes=2 rfixes=1 fixes_pr=49
dispatch --once
ok "the counts are per PR: another PR's runs don't count, both reset" eq "$(fixround) $(st 5 rfixes) $(st 5 fixes) $(st 5 fixes_pr)" "1 1 0 50"

env_new status-counts
{ issue 5 in-progress; } | issues
pr 50 5 $HA | prs
state 5 phase=review pr=50 review_sha=$HA stage=review fixes=2 fixes_pr=50
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "canccu-status: 2 CI fixes, no review fix yet → ci 2/2 · review 0/1" grep -qF '#5 · PR #50 · fixes: ci 2/2 · review 0/1' "$E/status"

env_new config-range
"$root/bin/canccu-dispatcher" config set REVIEW_FIX_ATTEMPTS=3 > "$E/out" 2>&1; rc=$?
ok "canccu-config accepts REVIEW_FIX_ATTEMPTS=3" eq "$rc $(grep -c "^REVIEW_FIX_ATTEMPTS='3'" "$CANCCU_HOME/config")" "0 1"
"$root/bin/canccu-dispatcher" config set REVIEW_FIX_ATTEMPTS=11 > "$E/out" 2>&1; rc=$?
ok "… and refuses 11" eq "$rc $(cat "$E/out")" "2 canccu-dispatcher: REVIEW_FIX_ATTEMPTS must be a whole number from 0 to 10"

echo "canccu-reviewfix tests: $npass passed, $nfail failed"; (( nfail == 0 ))
