#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-brake.sh — the review brake (#195, contracts §8): the escaped defects against the
# baseline engage it, a review in the brake blocks as before Q1, only the product owner releases
# it; and canccu-status --kpi-review.
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

T0=$(date -u -d 2030-10-01T00:00:00Z +%s)
# merged <from pr> <to pr> [start epoch]: merged.log lines, one PR an hour (issue = pr - 100)
merged() {
  local p t=${3:-$T0}
  for ((p = $1; p <= $2; p++)); do printf '%s\t%s\t%s\tauto\tPR %s\n' "$((t + (p - $1) * 3600))" "$((p - 100))" "$p" "$p"; done >> "$CANCCU_HOME/merged.log"
}
# regress <issues json> <prs json>: the GitHub search for "Regression of:" lines
regress() {
  json regi.json "$1"; json regp.json "$2"
  route 'issue list -R example-org/web -s all *Regression of*' regi.json
  route 'pr list -R example-org/web -s all *Regression of*' regp.json
}
feedline() { tail -1 "$CANCCU_HOME/events" | cut -f3-; }
TRIGGER_TEXT="Reviews block as before Q1 until you run canccu-dispatcher brake release"

# ---------------------------------------------------------------- the trigger

env_new brake-engage
echo "2030-10-15T00:00:00Z 0.10 1.00 10" > "$CANCCU_HOME/brake-baseline"
merged 101 110
regress '[{"number": 90, "body": "It broke.\nRegression of: #103"}, {"number": 91, "body": "no line"}]' \
        '[{"number": 92, "body": "**Regression of:** #107"}]'
dispatch --once
ok "a baseline of 0.1 and a window at 0.2: the brake engages, with the time and the trigger" \
  eq "$(cat "$CANCCU_HOME/brake" 2>/dev/null)" "2030-11-05T12:00:00Z escaped defects 0.20/PR over the last 10 merged PRs, baseline 0.10/PR"
ok "… one feed line for the product owner" \
  eq "$(feedline)" "$(printf 'po\task\tneeds-you\t-\t-\t-\tReview brake on: escaped defects 0.20/PR over the last 10 merged PRs, baseline 0.10/PR. %s' "$TRIGGER_TEXT")"
ok "… and the same text in the log" grep -qF "Review brake on: escaped defects 0.20/PR over the last 10 merged PRs, baseline 0.10/PR. $TRIGGER_TEXT" "$CANCCU_HOME/dispatch.log"
ok "… the regressions are cached in the project's home" eq "$(tail -n +2 "$CANCCU_HOME/regressions")" "$(printf '90\t103\n92\t107')"
n=$(grep -c . "$CANCCU_HOME/events")
dispatch --once
ok "… a second pass writes no second line" eq "$(grep -c . "$CANCCU_HOME/events")" "$n"
ok "canccu-status shows it" grep -qxF "brake: on since 2030-11-05T12:00:00Z (escaped defects 0.20/PR over the last 10 merged PRs, baseline 0.10/PR)" \
  <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"
ok "the snapshot has it for the monitor" eq "$(jq -r .pass.brake "$CANCCU_HOME/status.json")" \
  "on since 2030-11-05T12:00:00Z (escaped defects 0.20/PR over the last 10 merged PRs, baseline 0.10/PR)"

env_new brake-at-baseline
echo "2030-10-15T00:00:00Z 0.10 1.00 10" > "$CANCCU_HOME/brake-baseline"
merged 101 110
regress '[{"number": 90, "body": "Regression of: #103"}]' '[]'
dispatch --once
ok "a window at the baseline: no brake" not test -e "$CANCCU_HOME/brake"
ok "… no feed line" not grep -q 'Review brake' "$CANCCU_HOME/events"
dispatch --once
ok "… GitHub's search is read once an hour at most" eq "$(grep -c 'Regression of' "$FAKE/gh.log")" 2

env_new brake-off REVIEW_BRAKE=off
echo "2030-10-15T00:00:00Z 0.10 1.00 10" > "$CANCCU_HOME/brake-baseline"
merged 101 110
regress '[{"number": 90, "body": "Regression of: #103"}, {"number": 93, "body": "Regression of: #104"}]' '[]'
dispatch --once
ok "REVIEW_BRAKE=off: a window above the baseline never engages" not test -e "$CANCCU_HOME/brake"
ok "… and GitHub is not searched" not grep -q 'Regression of' "$FAKE/gh.log"

env_new brake-window BRAKE_WINDOW=5
echo "2030-10-15T00:00:00Z 0.10 1.00 10" > "$CANCCU_HOME/brake-baseline"
merged 101 110
regress '[{"number": 90, "body": "Regression of: #103"}, {"number": 93, "body": "Regression of: #104"}]' '[]'
dispatch --once
ok "BRAKE_WINDOW=5: regressions of older PRs fall out of the window" not test -e "$CANCCU_HOME/brake"

# ---------------------------------------------------------------- the baseline

env_new brake-baseline
merged 101 106                                  # before Q1's first review-log line
merged 107 108 "$((T0 + 30 * 86400))"           # after it
printf '%s\t%s\t%s\tfull\tpass\t0\t0\t0\t0\t-\n' "$(lib iso "$((T0 + 29 * 86400))")" 107 "$HA" > "$CANCCU_HOME/reviews.log"
printf '%s\tweb\treview-%s\t1.00\treview\tm\n' "$((T0 - 60))" 101 "$((T0 - 60))" 101 "$((T0 - 60))" 102 "$((T0 + 86400))" 103 > "$WORKERS_DIR/spend.log"
regress '[{"number": 90, "body": "Regression of: #102"}, {"number": 93, "body": "Regression of: #108"}]' '[]'
lib brake_tick
ok "the baseline: the 6 PRs merged before the first review-log line, escaped and rounds per PR" \
  eq "$(cat "$CANCCU_HOME/brake-baseline" 2>/dev/null)" "2030-11-05T12:00:00Z 0.17 0.50 6"
echo "2030-11-05T12:00:00Z 0.90 0.50 6" > "$CANCCU_HOME/brake-baseline"
lib brake_tick
ok "… written once: a later pass keeps it" eq "$(cut -d' ' -f2 "$CANCCU_HOME/brake-baseline")" 0.90

env_new brake-no-baseline
merged 101 104
merged 107 108 "$((T0 + 30 * 86400))"
printf '%s\t%s\t%s\tfull\tpass\t0\t0\t0\t0\t-\n' "$(lib iso "$((T0 + 29 * 86400))")" 107 "$HA" > "$CANCCU_HOME/reviews.log"
regress '[{"number": 90, "body": "Regression of: #108"}, {"number": 91, "body": "Regression of: #107"}]' '[]'
lib brake_tick
ok "fewer than 5 PRs before the first review-log line: no baseline" not test -e "$CANCCU_HOME/brake-baseline"
ok "… so the trigger is off" not test -e "$CANCCU_HOME/brake"
ok "… canccu-status says so" grep -qF "brake: no baseline (4 PRs merged before the first review-log line, 5 needed): the escaped-defect trigger is off" \
  <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"

# ---------------------------------------------------------------- a review in the brake

UNCLASSED=$'1. src/b.ts:4 — no class on this one\n   Evidence: it reads a closed file\n   Fix: open it first'
NOEV=$'2. [correctness] src/c.ts:5 — off by one, no evidence\n   Fix: use <='
STYLE=$'3. [style] src/a.ts:3 — the name says nothing\n   Evidence: the line `let x = 1`\n   Fix: rename it'
PRE='- [correctness] src/old.ts:9 — the old loop skips one'
review() {
  printf 'Read it.\n\nBlocking:\n%s\nNon-blocking:\nnone\nPre-existing:\n%s\nFindings: %s blocking, 0 non-blocking, %s pre-existing\nReview verdict: %s %s\n' \
    "$1" "${2:-none}" "$3" "${4:-0}" "$5" "$HA"
}
env_new brake-review
F=$E/review.md
review "$UNCLASSED"$'\n'"$NOEV"$'\n'"$STYLE" "$PRE" 3 1 changes > "$F"
ok "without the brake: the unclassed, the evidence-less and the style item are demoted" eq "$(lib review_effective "$F" "$HA")" "pass 0 0 1 3 -"
echo "2030-11-05T11:00:00Z escaped defects" > "$CANCCU_HOME/brake"
ok "in the brake: the unclassed, the evidence-less and the pre-existing item block; style does not" \
  eq "$(lib review_effective "$F" "$HA")" "changes 3 0 1 1 unclassed,correctness"
ok "… the fix round gets them" eq "$(lib blocking_of "$(cat "$F")")" "$UNCLASSED"$'\n'"$NOEV"$'\n'"$PRE"

# the dispatcher posts a reviewer's pass with an unclassed blocking item as changes
env_new brake-post
{ issue 5 in-progress; } | issues
p=$(pr 50 5 "$HA"); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "src/b.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
state 5 phase=review pr=50 "review_sha=$HA" "started=$NOW" rounds=0
last review-50 "done" "wrote the review"
echo "2030-11-05T11:00:00Z escaped defects" > "$CANCCU_HOME/brake"
RF=$CANCCU_HOME/reviews/50/$HA.md; mkdir -p "${RF%/*}"
review "$UNCLASSED" "" 1 0 pass > "$RF"; touch -d "@$((NOW + 60))" "$RF"
dispatch --once
ok "a pass in the brake does not demote an unclassed blocking item: posted as changes" eq "$(tail -1 "$FAKE/posted-50")" "Review verdict: changes $HA"
ok "… reviews.log: changes 1, unclassed" eq "$(cut -f5,6,10 "$CANCCU_HOME/reviews.log")" "$(printf 'changes\t1\tunclassed')"

env_new brake-norepeat
mkdir -p "$CANCCU_HOME/reviews/50"
printf '%s\tcorrectness\tsrc/c.ts\t5\tfixed\n' "$HB" > "$CANCCU_HOME/reviews/50/history"
state 5 phase=review pr=50 review_mode=review "pass_sha=$HB"
ctx() { lib eval 'review_ctx 5 50 '"$HA"'; printf "%s|%s" "$REVIEW_SETTLED" "$REVIEW_PASSRULE"'; }
ok "outside the brake: the settled findings are the no-repeat context" eq "$(ctx)" "$(printf 'correctness\tsrc/c.ts\t5|0')"
echo "2030-11-05T11:00:00Z escaped defects" > "$CANCCU_HOME/brake"
ok "in the brake: no-repeat is off (no settled findings, no pass rule)" eq "$(ctx)" "|0"
ok "… and the prompts do not promise it" eq "$(lib norepeat_prompt 50)" ""
ok "… nor the pass rule" not grep -qF 'raise nothing new on lines' <<<"$(lib review_prompt 50 5 "$HA" /f high)"

env_new brake-effort REVIEW_LIGHT=1
ok "outside the brake: high stays high" eq "$(lib brake_effort high)" "high"
echo "2030-11-05T11:00:00Z escaped defects" > "$CANCCU_HOME/brake"
ok "in the brake: the full review's effort is one step higher" eq "$(lib brake_effort medium) / $(lib brake_effort high)" "high / xhigh"
ok "… still capped at REVIEW_EFFORT_MAX" eq "$(REVIEW_EFFORT_MAX=high lib brake_effort high)" "high capped"
state 5 phase=check pkg=p1 risk=low
ok "… and REVIEW_LIGHT is off" not lib review_light_class 50 5 "src/a.ts"

# ---------------------------------------------------------------- the release

env_new brake-release
echo "2030-11-05T11:00:00Z escaped defects 0.20/PR" > "$CANCCU_HOME/brake"
bk() { out=$(PATH="$fb:$PATH" "$root/bin/canccu-dispatcher" brake "$@" 2>&1); rc=$?; }
bk
ok "brake with no argument prints the state" eq "$rc $out" "0 brake: on since 2030-11-05T11:00:00Z (escaped defects 0.20/PR)"
for a in leader run; do
  CANCCU_ACTOR=$a bk release
  ok "brake release as $a is refused, as a locked setting" eq "$rc $out" "3 canccu-dispatcher: refused: only the product owner releases the review brake"
  ok "… the brake stays" test -e "$CANCCU_HOME/brake"
done
ok "… the refusals are in the actions log" eq "$(cut -f2- "$CANCCU_HOME/actions.log")" "$(printf 'leader\tbrake release\t-\trefused\nrun\tbrake release\t-\trefused')"
bk release
ok "as po it releases" eq "$rc $out" "0 review brake released"
ok "… the file goes" not test -e "$CANCCU_HOME/brake"
ok "… the actions-log line" eq "$(tail -1 "$CANCCU_HOME/actions.log")" "$(printf '2030-11-05T12:00:00Z\tpo\tbrake release\t-\treleased')"
bk
ok "… brake prints off" eq "$rc $out" "0 brake: off"
bk release
ok "a release with no brake on says so" eq "$rc $out" "0 the review brake is not on"

# ---------------------------------------------------------------- canccu-status --kpi-review

env_new brake-kpi BRAKE_WINDOW=4
merged 101 105
merged 106 109 "$((T0 + 31 * 86400 + 3600))"
echo "2030-10-15T00:00:00Z 0.20 2.00 5" > "$CANCCU_HOME/brake-baseline"
{ q() { printf '2030-11-0%sT00:00:00Z\t%s\t%s\t%s\t%s\t%s\t0\t%s\t%s\t%s\n' "$@"; }
  q 1 106 "$HA" full changes 2 0 1 correctness,test
  q 1 106 "$HB" fixcheck pass 0 1 0 -
  q 2 107 "$HA" full pass 0 0 2 -
  q 3 108 "$HA" full changes 1 0 0 correctness
  q 3 108 "$HB" fixcheck pass 0 0 0 -
  q 4 109 "$HA" full pass 0 0 0 -; } > "$CANCCU_HOME/reviews.log"
regress '[{"number": 90, "body": "Regression of: #107"}, {"number": 93, "body": "Regression of: #102"}]' '[]'
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" --kpi-review 2>&1)
ok "--kpi-review: the last BRAKE_WINDOW merged PRs, the four numbers" grep -qxF \
  "last 4 merged PRs: rounds 1.50/PR · blocking by class: correctness 2, test 1 · demoted 4 (pre-existing 1, out of Blocking: 3) · escaped 0.25/PR" <<<"$out"
ok "… since the baseline" grep -qxF \
  "since the baseline (4 merged PRs): rounds 1.50/PR · blocking by class: correctness 2, test 1 · demoted 4 (pre-existing 1, out of Blocking: 3) · escaped 0.25/PR" <<<"$out"
ok "… at the baseline" grep -qxF \
  "at the baseline (5 merged PRs, 2030-10-15T00:00:00Z): rounds 2.00/PR · blocking by class: - · demoted - · escaped 0.20/PR" <<<"$out"
ok "… three lines" eq "$(grep -c . <<<"$out")" 3

echo "canccu-brake tests: $npass passed, $nfail failed"
(( nfail == 0 ))
