#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-followups3.sh — offline tests for the review follow-ups of #222, third part: the
# code of the PRs merged since (#201, #205, #210, #212) (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- #201: ship and the actions log

# a unit the leader owned when it entered accept: with LEADER=off, every item is the po's
env_new ship-leader-off LEADER=off LEADER_ACCEPTS=technical
issue 5 in-progress,awaiting-accept | issues
pr 50 5 "$HA" | prs
state 5 phase=accept pr=50 accept_sha="$HA" owner=leader
out=$(CANCCU_ACTOR=leader PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 2>&1); rc=$?
ok "CANCCU_ACTOR=leader canccu-ship with LEADER=off: refused, nothing merged" \
  eq "$rc $out $(grep -c '^pr merge' "$FAKE/gh.log")" "1 canccu-ship: refused: LEADER is off 0"

# config set naming a project that does not exist: the refusal's text reaches the actions log
env_new cfg-noproj
out=$(CANCCU_HOME="$CANCCU_ROOT/projects/web" "$root/bin/canccu-dispatcher" config set --project nope CAP=2 2>&1); rc=$?
ok "config set --project nope: refused, the projects named" eq "$rc $out" "1 canccu-dispatcher: no project 'nope'. Projects: web"
ok "… the actions log has the refusal, not the exit status" \
  eq "$(tail -1 "$CANCCU_ROOT/projects/web/actions.log" 2>/dev/null | cut -f2-)" "po	config set CAP	-	no project 'nope'. Projects: web"

# ---------------------------------------------------------------- #205: the body send-backs

# benv <name> <body> [files...]: issue 5 in check on its green PR 50 with that body and files (as
# tests/canccu-dispatch2.sh's benv)
benv() {
  local p f fs=''
  env_new "$1"
  issue 5 in-progress | issues
  p=$(PR_LINES=0 PR_BRANCH=5-thing pr 50 5 "$HA" green "" false "$2"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  for f in "${@:3}"; do fs+="${fs:+,}{\"filename\": \"$f\"}"; done
  json files50.json "[${fs:-{\"filename\": \"src/a.ts\"\}}]"; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  state 5 phase=check "check_at=$NOW" pr=50 branch=5-thing
  echo sid > "$WORKERS_DIR/web-5.id"
}
BSEND='PR #50 needs `Testing:` and `Revert:` lines in its body'
NOLINES=$'Closes #5\nVerification run: tests/run, green\nRevert: plain revert'
benv body-backoff "$NOLINES"
echo $((NOW + 3600)) > "$CANCCU_ROOT/backoff"
dispatch --once
ok "body lines during a usage back-off: no run, nothing recorded" \
  eq "$(grep -cF "$BSEND" "$FAKE/worker.log") [$(st 5 body_lines)] $(st 5 phase)" "0 [] check"

benv body-planfile "$NOLINES" src/a.ts docs/plans/issue-5.md
dispatch --once
ok "body lines: an implementation PR that edits its plan file is sent back like any other" \
  eq "$(grep -cF "$BSEND" "$FAKE/worker.log") $(st 5 body_lines)" "1 50"

benv body-nofix "$NOLINES"
st_set_line() { printf '%s\n' "$@" >> "$CANCCU_HOME/state/5"; }
st_set_line stage=fixing "reviewed_sha=$HA" fixes=1 fixes_pr=50
dispatch --once
ok "body lines: a fix round that pushed nothing → its needs-you, no body send-back first" \
  eq "$(grep -cF "$BSEND" "$FAKE/worker.log") $(grep -c 'pushed no fix' "$FAKE/gh.log")" "0 1"

# ---------------------------------------------------------------- #210: the leader kit

# a restarted leader's loop starts with no --ack: the wait goes on from its stored leader_ack
env_new leader-restart LEADER=on
touch -d "@$NOW" "$CANCCU_HOME/heartbeat"
for t in one two three; do lib feed leader ask idle 6 - - "$t" >/dev/null; done
lib kv_set "$CANCCU_HOME/feed.open" feed leader_ack=1
ok "wait --owner leader with no --ack: the first line after the stored ack, not a replay or a skip" \
  eq "$(PATH="$fb:$PATH" timeout 20 "$root/bin/canccu-dispatcher" wait --owner leader | cut -f2,9)" $'2\ttwo'
ok "the leader kit's loop starts with no --ack" \
  grep -qF 'ack=""; while l=$(canccu-dispatcher wait --owner leader ${ack:+--ack "$ack"})' "$root/templates/leader/CLAUDE.leader.md"

# ---------------------------------------------------------------- #212: REVIEW.md as the review reads it

# rvmain <REVIEW.md text|->: the review worktree of PR 50 with origin/main holding that REVIEW.md
rvmain() {
  local d; d=$(lib review_wt 50)
  rm -rf "$d"; mkdir -p "$d"
  "$FAKE_REAL_GIT" -C "$d" -c init.defaultBranch=main init -q
  if [ "$1" != - ]; then printf '%s' "$1" > "$d/REVIEW.md"; else echo a > "$d/a.txt"; fi
  "$FAKE_REAL_GIT" -C "$d" add -A
  "$FAKE_REAL_GIT" -C "$d" -c user.name=octo -c user.email=octo@example.com commit -qm main
  "$FAKE_REAL_GIT" -C "$d" update-ref refs/remotes/origin/main HEAD
  touch "$FAKE/realgit"
}
env_new rvmd-fence
rvmain $'## Also check\n- rule-one\n```sh\n# a shell comment, no heading\nrule-in-fence\n```\n- rule-after\n## Other\nrule-dropped\n'
md=$(lib review_md 50)
ok "REVIEW.md: a # line inside a fence ends no section" eq "$(grep -oE 'rule-(one|in-fence|after|dropped)' <<<"$md" | tr '\n' ' ')" "rule-one rule-in-fence rule-after "

env_new rvmd-crlf
rvmain $'## Also check\r\n- crlf-check\r\n## Never blocks\r\n- crlf-never\r\n'
md=$(lib review_md 50)
ok "REVIEW.md with CRLF lines: its sections are kept, without the \\r" \
  eq "$(grep -oE 'crlf-(check|never)' <<<"$md" | tr '\n' ' ')$(grep -c $'\r' <<<"$md")" "crlf-check crlf-never 0"

env_new rvmd-comments
rvmain "$(sed '1,/^-->$/d' "$root/templates/repo/REVIEW.snippet.md")"$'\n- my-rule <!-- kept: not a comment line -->\n<!--\n  a block comment\n-->\n'
md=$(lib review_md 50)
ok "REVIEW.md: the snippet's <!-- … --> lines reach no reviewer" eq "$(grep -c -e '<!--' -e 'block comment' -e '^-->' -e 'one per line' <<<"$md")" 1
ok "… a rule line is kept" grep -qF 'my-rule' <<<"$md"

env_new rvmd-comment-edge
rvmain $'## Also check\n- before-rule\n<!--\n# a heading in a comment\n-->\n- after-comment-rule\n<!-- one line --> trailing text\n- after-trailing-rule\n'
md=$(lib review_md 50)
ok "REVIEW.md: a # line in a comment resets no section, and text after a closing --> ends the comment" \
  eq "$(grep -oE '(before|after-comment|after-trailing)-rule' <<<"$md" | tr '\n' ' ')" "before-rule after-comment-rule after-trailing-rule "

env_new rvmd-nofile
rvmain -
out=$(lib review_md 50 2>&1)
ok "no REVIEW.md on main: empty, nothing logged" eq "$out$(cat "$CANCCU_HOME/dispatch.log" 2>/dev/null)" ""
env_new rvmd-nomain
rvmain $'## Also check\n- x\n'
"$FAKE_REAL_GIT" -C "$(lib review_wt 50)" update-ref -d refs/remotes/origin/main
out=$(lib review_md 50 2>/dev/null)
ok "origin/main missing: REVIEW.md is empty, the git error logged" \
  eq "$out|$(grep -c 'REVIEW.md: git show origin/main failed' "$CANCCU_HOME/dispatch.log" 2>/dev/null)" "|1"

# ---------------------------------------------------------------- leader: canccu-status, check + conflict

env_new status-conflict
issue 5 in-progress | issues
{ pr 50 5 "$HA" | jq '.mergeStateStatus = "DIRTY"'; pr 60 6 "$HB" | jq '.mergeStateStatus = "CLEAN"'; } | prs
state 5 phase=check pr=50
state 6 phase=check pr=60
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)
ok "canccu-status lists a unit in check whose PR conflicts, auto-merge off" \
  grep -qF '#5 · PR #50 conflicts with main, auto-merge off: the dispatcher merges main in on its next pass' <<<"$out"
ok "… not one whose PR merges cleanly" not grep -qF 'PR #60 conflicts' <<<"$out"
state 5 phase=check pr=50 conflict_merge="$HA" conflict_sha="$HA" conflict_paths=src/a.ts
ok "… with the worker's merge run named once it started" \
  grep -qF '#5 · PR #50 conflicts with main, auto-merge off: the worker resolves src/a.ts' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"

# ---------------------------------------------------------------- leader: ready_unpark lifts ny_stage=ci

# a red-CI needs-you whose CI went green (a flaky run re-run): the label removed lifts it
for ci in green red; do
  env_new "unpark-ci-$ci"
  { issue 5 in-progress; } | issues
  p=$(pr 50 5 $HA "$ci"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  json c5.json '{"comments": []}'; route 'issue view 5 *' c5.json
  state 5 phase=needs-you pr=50 "ny_at=$((NOW - 600))" ny_stage=ci "reason=CI is red on PR #50"
  echo finish > "$CANCCU_HOME/paused"
  dispatch --once
  if [ $ci = green ]; then
    ok "needs-you of a red CI lifted, CI green now → the review starts, no worker run" \
      eq "$(grep -c -- '--key review-50' "$FAKE/worker.log")$(started 5 && echo " started")" 1
  else
    ok "… CI still red → it stays needs-you" eq "$(st 5 phase)" needs-you
  fi
done

# ---------------------------------------------------------------- #226: an open checkpoint behind many closed

env_new cps-open-apart
issues </dev/null
json cps-open.json '[{"number": 7, "title": "Checkpoint old", "state": "OPEN", "milestone": null, "labels": [{"name": "checkpoint"}]}]'
json cps-closed.json "$(jq -n '[range(300; 100; -1) | {number: ., title: "C \(.)", state: "CLOSED", milestone: null, labels: [{name: "checkpoint"}]}]')"
route 'issue list -R example-org/web -s open -l checkpoint*' cps-open.json
route 'issue list -R example-org/web -s closed -l checkpoint*' cps-closed.json
cp_read() { fetch_steps && jq -r '[.[] | select(.number == 7) | .state] + [length | tostring] | join(" ")' <<<"$CHECKPOINTS"; }
ok "an open checkpoint behind 200 closed ones is read (its own list), with the closed" eq "$(lib cp_read)" "OPEN 201"

# ---------------------------------------------------------------- #233: --kpi-review's demoted count

# a pre-existing item the brake kept blocks: reviews.log records it (field 11), --kpi-review does
# not count it as demoted
env_new kpi-prekept
F=$E/review.md
printf 'Blocking:\nnone\nNon-blocking:\nnone\nPre-existing:\n%s\n%s\nFindings: 0 blocking, 0 non-blocking, 2 pre-existing\nReview verdict: changes %s\n' \
  '- [correctness] src/old.ts:9 — the old loop skips one' '- [style] src/old.ts:12 — a name' "$HA" > "$F"
echo "2030-11-05T11:00:00Z escaped defects" > "$CANCCU_HOME/brake"
state 5 phase=review pr=50
lib reviews_log 5 50 "$HA" "$F"
ok "in the brake: reviews.log records the pre-existing item kept (2 written, 1 kept)" eq "$(cut -f5,8,11 "$CANCCU_HOME/reviews.log")" "$(printf 'changes\t2\t1')"
rm "$CANCCU_HOME/brake"
lib reviews_log 5 50 "$HA" "$F"
ok "… without the brake, none kept" eq "$(tail -1 "$CANCCU_HOME/reviews.log" | cut -f5,8,11)" "$(printf 'pass\t2\t0')"
echo "2030-10-01T00:00:00Z 0.20 2.00 5" > "$CANCCU_HOME/brake-baseline"
printf '50\t%s\n' "$(lib iso "$NOW")" > "$CANCCU_HOME/merged.log"
ok "--kpi-review: demoted 3, of them pre-existing 3 (the kept one is not demoted)" \
  grep -qF "demoted 3 (pre-existing 3, out of Blocking: 0)" <<<"$(lib _kpi_nums 50 0)"

# a brake release holds until the window moves on: one merged PR more lets the trigger decide again
env_new brake-hold
echo "2030-10-15T00:00:00Z 0.10 1.00 10" > "$CANCCU_HOME/brake-baseline"
for p in $(seq 101 110); do printf '%s\t%s\t%s\tauto\tPR %s\n' "$((NOW - 86400 + p))" "$((p - 100))" "$p" "$p"; done >> "$CANCCU_HOME/merged.log"
json regi.json '[{"number": 90, "body": "Regression of: #103"}, {"number": 92, "body": "Regression of: #107"}]'; json regp.json '[]'
route 'issue list -R example-org/web -s all *Regression of*' regi.json
route 'pr list -R example-org/web -s all *Regression of*' regp.json
lib brake_tick
ok "the brake engages" test -e "$CANCCU_HOME/brake"
CANCCU_HOME=$CANCCU_HOME "$root/bin/canccu-dispatcher" brake release >/dev/null 2>&1
lib brake_tick
ok "… after brake release, the same window does not engage it again" not test -e "$CANCCU_HOME/brake"
printf '%s\t%s\t%s\tauto\tPR 111\n' "$NOW" 11 111 >> "$CANCCU_HOME/merged.log"
lib brake_tick
ok "… a newer merged PR in the window: the trigger decides again (still above: on)" test -e "$CANCCU_HOME/brake"
ok "… and the hold is gone" not test -e "$CANCCU_HOME/brake-released"

# the baseline's rounds: a review run with no verdict (lost, void) is no round; an old line with no
# outcome counts
env_new brake-base-rounds
B0=$((NOW - 40 * 86400))
for p in $(seq 101 105); do printf '%s\t%s\t%s\tauto\tPR %s\n' "$((B0 + p * 60))" "$((p - 100))" "$p" "$p"; done >> "$CANCCU_HOME/merged.log"
printf '%s\t107\t%s\tfull\tpass\t0\t0\t0\t0\t-\n' "$(lib iso "$((NOW - 86400))")" "$HA" > "$CANCCU_HOME/reviews.log"
sl() { printf '%s\tweb\treview-%s\t1.00\treview\tm\t-\tfresh\t0\t0\t0\t0\t-\t-\t%s\t60\n' "$((B0 + $1 * 60 - 30))" "$1" "$2"; }
{ sl 101 verdict=pass,blocking=0; sl 101 verdict=none; sl 102 -; sl 103 verdict=void; sl 104 verdict=changes,blocking=1; } > "$WORKERS_DIR/spend.log"
json regi.json '[]'; json regp.json '[]'
route 'issue list -R example-org/web -s all *Regression of*' regi.json
route 'pr list -R example-org/web -s all *Regression of*' regp.json
ok "the baseline counts the review runs with a verdict (or no outcome): 3 of 5 lines" eq "$(lib brake_baseline | cut -d' ' -f3)" 0.60

# ---------------------------------------------------------------- #235: the review set's runner

# a fake engine: a pass on every case (FAKE/rsf-fail: it fails on the named case instead)
cat > "$fb/rsf" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null; c=${3%/}; c=${c##*/}
grep -qx "$c" "$FAKE/rsf-fail" 2>/dev/null && { echo "claude: not logged in" >&2; exit 1; }
printf 'Blocking:\nnone\nNon-blocking:\nnone\nPre-existing:\nnone\nFindings: 0 blocking, 0 non-blocking, 0 pre-existing\nReview verdict: pass %s\n' "$2" > "$1"
EOF
chmod +x "$fb/rsf"
rsf() { REVIEW_SET_ENGINE=$fb/rsf "$root/tests/review-set/run" "$@" > "$E/out" 2>&1; rc=$?; }
env_new rs-engine-fail
echo defect-test > "$FAKE/rsf-fail"
rsf
ok "review set: an engine failure is an error, exit 2" eq "$rc $(grep -c '^defect-test error' "$E/out")" "2 1"
ok "… no baseline, no log line, no brake" \
  eq "$(find "$CANCCU_HOME" -maxdepth 1 \( -name 'review-set*' -o -name brake \) | grep -c .)" 0
echo "2030-11-01T00:00:00Z 0 default high 0 defect-test" > "$CANCCU_HOME/review-set-baseline"
rsf
ok "… with a baseline: still exit 2, no brake" eq "$rc $(test -e "$CANCCU_HOME/brake" && echo on)" "2 "
env_new rs-model REVIEW_MODEL=rev-model REVIEW_MODEL_LIGHT=light-model
rsf
ok "review set without --model: the project's review model" eq "$(cut -d' ' -f3 "$CANCCU_HOME/review-set-baseline")" rev-model
rsf --light
ok "… --light: its light model" eq "$(cut -d' ' -f3 "$CANCCU_HOME/review-set-baseline-light")" light-model

echo "canccu-followups3 tests: $npass passed, $nfail failed"; (( nfail == 0 ))
