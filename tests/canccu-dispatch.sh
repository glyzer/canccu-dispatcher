#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-dispatch.sh — offline tests for canccu-dispatch: gating, caps, exits, CI, merges, digest (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- blocked-by gating

env_new blocked CAP=10
{ issue 1 ready; issue 2 ready "Blocked by #6"; issue 3 ready "Blocked by #7"; issue 4 ready
  issue 5 ""; issue 6 ""; issue 8 ready; } | issues
json deps1.json '[{"number": 5, "state": "open"}]'
json deps4.json '[{"number": 9, "state": "closed"}]'
route 'api repos/example-org/web/issues/1/dependencies/blocked_by' deps1.json
route 'api repos/example-org/web/issues/4/dependencies/blocked_by' deps4.json
route 'api repos/example-org/web/issues/8/dependencies/blocked_by' FAIL
dispatch --once
ok "API blocker open → not started" not started 1
ok "Blocked by #x (open) in the body → not started" not started 2
ok "Blocked by #x (closed) → started" started 3
ok "API blocker closed → started" started 4
ok "dependencies API error → treated as blocked" not started 8
ok "start labels in-progress, drops ready, assigns" has gh.log "issue edit 3 -R example-org/web --add-label in-progress --remove-label ready --add-assignee octo"
ok "worker runs with the work budget" grep -q 'turns=250 cost=80 min=150$' "$FAKE/worker.log"
ok "state records phase work" eq "$(st 3 phase)" work
ok "a pass touches the heartbeat (#83)" test -e "$CANCCU_HOME/heartbeat"

# ---------------------------------------------------------------- contracts lock

env_new contracts
{ issue 10 ready,module:contracts; issue 11 ready "edits contracts/screen.yaml"; issue 12 ready; } | issues
dispatch --once
ok "first contracts issue starts" started 10
ok "second contracts issue waits in the same pass" not started 11
ok "a non-contracts issue starts" started 12
ok "contracts flag recorded (as the rules' one-at-a-time lock)" eq "$(st 10 exclusive)" 1

env_new contracts-running
{ issue 10 ready,module:contracts; issue 12 ready; issue 20 in-progress,module:contracts; } | issues
state 20 phase=work exclusive=1 "started=$NOW"; live_lock 20
dispatch --once
ok "contracts issue waits while another one is open" not started 10
ok "other issue still starts" started 12

# ---------------------------------------------------------------- CAP and order

env_new cap CAP=2
{ issue 30 ready; issue 31 ready; issue 32 ready; } | issues
live_lock review-99
dispatch --once
ok "CAP counts the running reviewer: one start" eq "$(grep -c -- '--name #' "$FAKE/worker.log")" 1
ok "lowest number first" started 30

# a check-phase PR reserves a slot only when its CI is green or red (a review or fix-check is
# about to start); pending CI, or no checks at all, holds no slot
env_new wanting-ci
{ issue 5 in-progress; issue 6 in-progress; issue 7 in-progress; issue 8 in-progress; } | issues
{ pr 50 5 $HA none; pr 60 6 $HA green; pr 70 7 $HA red; pr 80 8 $HA pending; } | prs
for n in 5 6 7 8; do state $n phase=check pr=${n}0 "check_at=$NOW"; done
ok "wanting: a check PR with no checks is not counted" eq "$(lib eval 'fetch && wanting 5')" 0
ok "wanting: a check PR with a running check is not counted" eq "$(lib eval 'fetch && wanting 8')" 0
ok "wanting: a check PR with CI green is counted" eq "$(lib eval 'fetch && wanting 6')" 1
ok "wanting: a check PR with CI red is counted" eq "$(lib eval 'fetch && wanting 7')" 1
ok "wanting: all four → the green and the red" eq "$(lib eval 'fetch && wanting 5 6 7 8')" 2

env_new wanting-pending-start CAP=3
{ issue 5 in-progress; issue 6 in-progress; issue 7 in-progress; issue 8 ready; } | issues
{ pr 50 5 $HA pending; pr 60 6 $HA none; pr 70 7 $HA pending; } | prs
for n in 5 6 7; do state $n phase=check pr=${n}0 "check_at=$NOW"; done
dispatch --once
ok "CAP pending-CI PRs (one with no checks) and a ready issue: the issue starts" started 8
ok "… the pending PRs stay in check, no review starts" \
  eq "$(st 5 phase) $(st 6 phase) $(st 7 phase) $(grep -c -- '--key review-' "$FAKE/worker.log")" "check check check 0"

# a check issue labelled needs-work or plan-ok keeps its slot for the resume, whatever its CI
env_new wanting-check-labels
{ issue 5 in-progress,needs-work; issue 6 in-progress,plan-ok; issue 7 in-progress,needs-work; } | issues
{ pr 50 5 $HA pending; pr 60 6 $HA none; pr 70 7 $HA pending; } | prs
for n in 5 6 7; do state $n phase=check pr=${n}0 "check_at=$NOW"; done
live_lock 7
ok "wanting: a pending check PR labelled needs-work is counted" eq "$(lib eval 'fetch && wanting 5')" 1
ok "wanting: a no-checks check PR labelled plan-ok is counted" eq "$(lib eval 'fetch && wanting 6')" 1
ok "wanting: … but not while its worker is alive" eq "$(lib eval 'fetch && wanting 7')" 0

env_new wanting-needs-work-pending CAP=1
{ issue 5 in-progress,needs-work; issue 8 ready; } | issues
pr 50 5 $HA pending | prs
state 5 phase=check pr=50 "check_at=$NOW"
json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json
json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "needs-work on a pending-CI check PR, CAP 1: the resume takes the slot" grep -q 'web 5 Rules for this run: .* The user rejected PR #50' "$FAKE/worker.log"
ok "… and the ready issue does not start" not started 8

# #69: a plan-ok issue whose blocker is open reserves no slot; once the blocker closes it does again
env_new wanting-blocker CAP=1
{ issue 5 in-progress,plan-ok "Blocked by #9"; issue 9 in-progress; issue 6 in-progress,plan-ok; issue 7 in-progress; } | issues
state 5 phase=plan; state 6 phase=plan; state 7 phase=work "started=$NOW"
ok "wanting: a plan-ok issue with an open blocker reserves nothing" eq "$(lib eval 'fetch && wanting 5')" 0
ok "wanting: a plan-ok issue without blockers reserves as today" eq "$(lib eval 'fetch && wanting 6')" 1
: > "$FAKE/gh.log"
lib eval 'fetch && wanting 7' > /dev/null
ok "wanting: a unit with no plan-ok or needs-work makes no blocker read" not grep -q 'dependencies/blocked_by' "$FAKE/gh.log"
{ issue 5 in-progress,plan-ok "Blocked by #9"; issue 6 in-progress,plan-ok; issue 7 in-progress; } | issues
ok "wanting: … the blocker closed: it reserves again" eq "$(lib eval 'fetch && wanting 5')" 1
env_new wanting-blocker-slot CAP=1
{ issue 5 in-progress,plan-ok "Blocked by #9"; issue 9 in-progress; issue 8 ready; } | issues
state 5 phase=plan
dispatch --once
ok "one slot, a plan-ok issue with an open blocker and a ready issue: the ready issue starts" started 8

env_new wanting-green-no-slot CAP=1
{ issue 5 in-progress; issue 8 ready; } | issues
p=$(pr 50 5 $HA green); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=check pr=50 "check_at=$NOW"
live_lock review-99
dispatch --once
ok "a green PR with no free slot: no review, still check" eq "$(st 5 phase) $(grep -c -- '--key review-50' "$FAKE/worker.log")" "check 0"
ok "… and the ready issue does not take its slot either" not started 8
rm -f "$WORKERS_DIR/web-review-99.lock"
dispatch --once
ok "a slot frees up: the green PR's review starts" grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… and nothing else starts past CAP" not started 8

env_new wanting-green-total-cap CAP=3
echo 'TOTAL_CAP=1' > "$CANCCU_ROOT/config"
{ issue 5 in-progress; issue 8 ready; } | issues
p=$(pr 50 5 $HA green); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=check pr=50 "check_at=$NOW"
live_lock review-99
dispatch --once
ok "TOTAL_CAP full: a green PR waits, nothing starts" \
  eq "$(st 5 phase) $(grep -c -- '--name #' "$FAKE/worker.log") $(grep -c -- '--key review-50' "$FAKE/worker.log")" "check 0 0"

env_new cap-refused
{ issue 30 ready; } | issues
touch "$FAKE/refuse"
dispatch --once
ok "engine refusal: nothing labelled" hasnt gh.log "issue edit 30"
ok "engine refusal: no state" eq "$(st 30 phase)" ""

env_new order
{ issue 30 ready; issue 31 ready,fast "" "11 Freeze and switch"; issue 32 ready,fast "" "2 Contracts"
  issue 36 ready,fast "" "Parallel tracks"; issue 37 ready,fast "" "3 Screens"; issue 38 ready,fast "" "1 Skeleton"
  issue 40 ready,fast "" "Someday"; issue 41 ready,fast "" "2 Contracts"; issue 42 ready,fast "" "2 Contracts"
  issue 33 ready; issue 34 ready; issue 39 epic $'Goal\nOrder: #34 → #33 → #42\n'; issue 35 ready,in-progress; } | issues
ok "order: milestone number (Parallel tracks after 2, 11 after 3), epic Order:, number; no milestone last" \
  eq "$(lib eval 'fetch && candidates' | tr '\n' ' ')" "38 42 32 41 36 37 31 40 34 33 30 "

# ---------------------------------------------------------------- exit classification

env_new exits
rx() { printf 'web#5 · "a · b" · %s · 3 turns · $0.10 · 0m10s\n\n%s\n' "$1" "$2" > "$E/l"; lib run_exit "$E/l"; }
ok "done" eq "$(rx "done" fine)" "done|done"
ok "blocked" eq "$(rx blocked 'Blocked by the permission classifier')" "blocked|blocked"
ok "turn budget" eq "$(rx 'stopped: turn budget 60' x)" "budget|stopped: turn budget 60"
ok "time budget" eq "$(rx 'stopped: time budget 45m' x)" "budget|stopped: time budget 45m"
ok "stalled" eq "$(rx 'stalled: no output for 10m, killed' x)" "stalled|stalled: no output for 10m, killed"
ok "crashed" eq "$(rx 'crashed (exit 1)' boom)" "crashed|crashed (exit 1)"
ok "usage limit" eq "$(rx error "Claude AI usage limit reached|$((NOW + 600))")" "usage|error"
ok "a done run that mentions limits is still done" eq "$(rx "done" 'usage limit reached docs')" "done|done"
ok "no report" eq "$(lib run_exit "$E/missing")" "none|no exit report"
ok "reset from |epoch, plus the margin" eq "$(lib usage_reset "limit reached|$((NOW + 600))")" "$((NOW + 600 + 120))"
ok "reset from 3pm (UTC)" eq "$(lib usage_reset "You've hit your limit · resets 3pm (UTC)")" "$(( $(date -u -d 2030-11-05T15:00:00Z +%s) + 120 ))"
ok "reset in the past → tomorrow" eq "$(lib usage_reset "resets 9am (UTC)")" "$(( $(date -u -d 2030-11-06T09:00:00Z +%s) + 120 ))"
ok "no reset time → 30 min" eq "$(lib usage_reset "usage limit reached")" "$((NOW + 1800))"
# the 5-hour limit's own wording, with and without a reset time
H5="You've hit your 5-hour limit · resets 11:30pm (UTC)"
ok "5-hour limit with a reset → usage" eq "$(rx error "$H5")" "usage|error"
ok "weekly limit without a reset → usage" eq "$(rx error "You've hit your weekly limit")" "usage|error"
ok "a crash whose output names the limit → usage" eq "$(rx 'crashed (exit 1)' "$H5")" "usage|crashed (exit 1)"
ok "a real error is still a crash" eq "$(rx error 'API Error: 500 internal server error')" "crashed|error"
ok "reset 11:30pm (UTC) + margin" eq "$(lib usage_reset "$H5")" "$(( $(date -u -d 2030-11-05T23:30:00Z +%s) + 120 ))"
ok "reset 11:30pm in Europe/Helsinki" eq "$(lib usage_reset "You've hit your 5-hour limit · resets 11:30pm (Europe/Helsinki)")" "$(( $(date -u -d 2030-11-05T21:30:00Z +%s) + 120 ))"
ok "5-hour limit without a reset → 30 min" eq "$(lib usage_reset "You've hit your 5-hour limit")" "$((NOW + 1800))"
ok "a zone with digits (Etc/GMT-2)" eq "$(lib usage_reset "You've hit your 5-hour limit · resets 11:30pm (Etc/GMT-2)")" "$(( $(date -u -d 2030-11-05T21:30:00Z +%s) + 120 ))"
mkdir -p "$CANCCU_ROOT"; echo $((NOW + 7200)) > "$CANCCU_ROOT/backoff"
lib set_backoff $((NOW + 1800))
ok "a shorter back-off never replaces a longer one" eq "$(cat "$CANCCU_ROOT/backoff")" "$((NOW + 7200))"
lib set_backoff $((NOW + 9000))
ok "… a longer one does" eq "$(cat "$CANCCU_ROOT/backoff")" "$((NOW + 9000))"
rm -f "$CANCCU_ROOT/backoff"

env_new reap-budget
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 'stopped: time budget 150m' 'I was still running tests'
dispatch --once
ok "budget stop → needs-you label" has gh.log "issue edit 5 -R example-org/web --add-label needs-you"
ok "comment carries the reason and last message" has gh.log "the worker stopped: stopped: time budget 150m  > I was still running tests"
ok "phase needs-you" eq "$(st 5 phase)" needs-you

env_new reap-usage
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 error "Claude AI usage limit reached|$((NOW + 3600))"
dispatch --once
ok "usage → back-off until the named reset" eq "$(cat "$CANCCU_ROOT/backoff")" "$((NOW + 3600 + 120))"
ok "usage → phase limited, still in-progress" eq "$(st 5 phase)" limited
ok "usage → no needs-you" hasnt gh.log "needs-you"

# the 5-hour limit stops a worker in the fix round: limited until the reset, a fresh
# session after it, limited again on a second hit; never needs-you, never a comment, no new round
env_new reap-usage-5h
{ issue 5 in-progress; issue 6 ready; } | issues
state 5 phase=work "started=$NOW" pr=50 stage=fixing reviewed_sha=$HA; last 5 error "$H5"
dispatch --once
R5=$(( $(date -u -d 2030-11-05T23:30:00Z +%s) + 120 ))
ok "5-hour limit → back-off until 23:30 UTC + margin" eq "$(cat "$CANCCU_ROOT/backoff")" "$R5"
ok "… phase limited" eq "$(st 5 phase)" limited
ok "… no needs-you" hasnt gh.log "needs-you"
ok "… no comment on the issue" hasnt gh.log "issue comment"
ok "… nothing starts while backed off" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… canccu-status shows the usage limit" grep -q "usage limit until $(date -u -d "@$R5" +%FT%TZ)" <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)"
dispatch --once
ok "… still backed off on the next pass: nothing starts" eq "$(wc -l < "$FAKE/worker.log")" 0
echo $((NOW - 1)) > "$CANCCU_ROOT/backoff"
dispatch --once
ok "after the reset → a fresh session from git status (no handoff)" grep -q '^--quiet --name #5 --fresh web 5 Rules for this run: .* The usage limit has reset. Your earlier run was cut off' "$FAKE/worker.log"
ok "… phase work, still the same fix round" eq "$(st 5 phase) $(st 5 stage) $(st 5 reviewed_sha)" "work fixing $HA"
ok "… no needs-you, no comment" eq "$(grep -cE 'needs-you|issue comment 5' "$FAKE/gh.log")" 0
rm -f "$WORKERS_DIR/web-5.lock"; last 5 error "You've hit your 5-hour limit"   # the resumed run ends on the limit
: > "$FAKE/worker.log"; dispatch --once
ok "a second hit after the resume → limited again" eq "$(st 5 phase) $(st 5 stage)" "limited fixing"
ok "… backed off again (no reset time: 30 min)" eq "$(cat "$CANCCU_ROOT/backoff")" "$((NOW + 1800))"
ok "… still no needs-you, no comment" eq "$(grep -cE 'needs-you|issue comment 5' "$FAKE/gh.log")" 0
ok "… nothing starts" eq "$(wc -l < "$FAKE/worker.log")" 0

# a real error is still needs-you, and backs nothing off
env_new reap-real-error
{ issue 5 in-progress; } | issues
state 5 phase=work "started=$NOW"; last 5 error "API Error: 500 internal server error"
dispatch --once
ok "real error → needs-you" has gh.log "issue edit 5 -R example-org/web --add-label needs-you"
ok "… with the reason" has gh.log "the worker stopped: error"
ok "… no back-off" test ! -e "$CANCCU_ROOT/backoff"

env_new reap-done-review
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=work "started=$NOW"; last 5 "done" 'PR ready, CI green'
dispatch --once
ok "done + green PR → reviewer started" grep -q -- '--key review-50 --dir .*/review-50 --name review#50 --untrusted web You are the independent reviewer' "$FAKE/worker.log"
ok "reviewer budget" grep -q 'review#50 .*turns=60 cost=15 min=40$' "$FAKE/worker.log"
ok "phase review at the head" eq "$(st 5 phase) $(st 5 review_sha)" "review $HA"

env_new reap-plan
{ issue 5 in-progress; } | issues
pr 50 5 $HA pending "" true "Tier: plan" | prs
state 5 phase=work "started=$NOW"; last 5 "done" 'plan written'
dispatch --once
ok "draft plan PR → needs-you plan ready" has gh.log "plan ready for OK: https://github.com/example-org/web/pull/50"

env_new reap-review-checks 'REVIEW_CHECKS="review-gate"'
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA green | jq '.statusCheckRollup += [{name: "review-gate", status: "COMPLETED", conclusion: "FAILURE", completedAt: "x"}]')
printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=check "check_at=$NOW" pr=50
dispatch --once
ok "a red REVIEW_CHECKS check does not block the review" grep -q -- '--key review-50' "$FAKE/worker.log"

# ---------------------------------------------------------------- no checks vs CI running

env_new ci-none 'REVIEW_CHECKS="review-gate"'
gate='{name: "review-gate", status: "IN_PROGRESS", conclusion: "", startedAt: "x"}'
{ pr 50 5 $HA none; pr 51 6 $HA pending; pr 52 7 $HA none | jq ".statusCheckRollup += [$gate]"
  pr 53 8 $HA none | jq '.statusCheckRollup += [{context: "ci/x", state: "PENDING"}]'
  pr 54 9 $HA green; pr 55 10 $HA red; } | prs
cs() { lib eval "fetch >/dev/null && ci_state $1"; }
ok "ci_state: no checks at all → none" eq "$(cs 50)" none
ok "ci_state: a check running → pending" eq "$(cs 51)" pending
ok "ci_state: only REVIEW_CHECKS checks → none" eq "$(cs 52)" none
ok "ci_state: a pending commit status → pending" eq "$(cs 53)" pending
ok "ci_state: green and red unchanged" eq "$(cs 54) $(cs 55)" "green red"

# a finished worker's PR with no checks: waits NO_CHECKS_MIN (default 10), never reviewed, then needs-you
env_new ci-none-wait
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA none); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=check "check_at=$((NOW - 9 * 60))" pr=50
dispatch --once
ok "no checks for 9 min: no review (none is never green)" not grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… no needs-you yet" eq "$(st 5 phase) $(grep -c needs-you "$FAKE/gh.log")" "check 0"
ok "… the snapshot shows no-checks" eq "$(jq -r '.running[] | select(.issue == 5) | .pipeline' "$CANCCU_HOME/status.json")" no-checks
state 5 phase=check "check_at=$((NOW - 11 * 60))" pr=50
dispatch --once
ok "no checks for 11 min → needs-you" has gh.log "issue edit 5 -R example-org/web --add-label needs-you"
ok "… with the reason" has gh.log "no CI checks on PR #50: is CI set up for this repo, or did a path filter skip it?"
ok "… still no review" not grep -q -- '--key review-50' "$FAKE/worker.log"

env_new ci-none-min NO_CHECKS_MIN=30
{ issue 5 in-progress; } | issues
pr 50 5 $HA none | prs
state 5 phase=check "check_at=$((NOW - 20 * 60))" pr=50
dispatch --once
ok "NO_CHECKS_MIN=30: no needs-you after 20 min" eq "$(st 5 phase)" check

# CI running is still CI: the snapshot says ci, and CI_WAIT_MIN (90) applies, not NO_CHECKS_MIN
env_new ci-pending-wait
{ issue 5 in-progress; } | issues
pr 50 5 $HA pending | prs
state 5 phase=check "check_at=$((NOW - 20 * 60))" pr=50
dispatch --once
ok "CI running for 20 min: no needs-you" eq "$(st 5 phase) $(grep -c needs-you "$FAKE/gh.log")" "check 0"
ok "… the snapshot shows ci" eq "$(jq -r '.running[] | select(.issue == 5) | .pipeline' "$CANCCU_HOME/status.json")" ci
state 5 phase=check "check_at=$((NOW - 91 * 60))" pr=50
dispatch --once
ok "CI running for 91 min → needs-you, the CI reason" has gh.log "CI on PR #50 is still pending after 90 min"

# a package's stage in the snapshot: no-checks apart from ci
env_new ci-none-pkg
{ pr 50 5 $HA none; pr 51 6 $HA pending; } | prs
state pkg-12-a phase=check pr=50; state pkg-12-b phase=check pr=51
ok "pkg_stage: no checks → no-checks, CI running → ci" \
  eq "$(lib eval '. "$root/lib/canccu-snapshot.sh"; fetch >/dev/null; echo "$(pkg_stage pkg-12-a) $(pkg_stage pkg-12-b)"')" "no-checks ci"

# ---------------------------------------------------------------- classifier

env_new classify
ok "auto" eq "$(c $'src/a.ts\nREADME.md' 'Tier: fix' "" "" example-org/web 0)" auto
ok "plan file" eq "$(c 'docs/plans/issue-7.md' 'Tier: feature' "" "" example-org/web 0)" "manual: plan tier"
ok "Tier: plan" eq "$(c 'src/a.ts' $'x\nTier: plan\n' "" "" example-org/web 0)" "manual: plan tier"
ok "approved plan builds auto-merge" eq "$(c 'docs/plans/issue-7.md' 'Tier: plan' "" "" example-org/web 1)" auto
ok ".github/" eq "$(c $'src/a.ts\n.github/workflows/ci.yml' "" "" "" example-org/web 0)" "manual: changes .github/ (.github/workflows/ci.yml)"
ok "setup/" eq "$(c 'setup/install' "" "" "" example-org/web 0)" "manual: changes setup/ (setup/install)"
ok "a file merely named setup is not setup/" eq "$(c 'docs/setup.md' "" "" "" example-org/web 0)" auto
ok "manual-accept" eq "$(c 'src/a.ts' "" $'module:ui\nmanual-accept' "" example-org/web 0)" "manual: the issue has manual-accept"
ok "Maintainer accept line" eq "$(c 'src/a.ts' "" "" 'destructive migration (drops a column)' example-org/web 0)" "manual: maintainer accept: destructive migration (drops a column)"
ok "another repo" eq "$(c 'src/a.ts' "" "" "" example-org/other 0)" "manual: another repo (example-org/other)"
ok "first reason wins" eq "$(c $'.github/x\ndocs/plans/issue-1.md' "" manual-accept "" example-org/web 0)" "manual: plan tier"
ok "the day before the cutoff: auto" eq "$(CANCCU_NOW=$(date -u -d 2031-02-28T23:59:00Z +%s) c 'src/a.ts' "" "" "" example-org/web 0)" auto
ok "on the cutoff: manual" eq "$(CANCCU_NOW=$(date -u -d 2031-03-01T00:00:00Z +%s) c 'src/a.ts' "" "" "" example-org/web 0)" "manual: on or after AUTO_MERGE_UNTIL (2031-03-01)"
ok "after the cutoff: manual" eq "$(CANCCU_NOW=$(date -u -d 2031-06-01T00:00:00Z +%s) c 'src/a.ts' "" "" "" example-org/web 0)" "manual: on or after AUTO_MERGE_UNTIL (2031-03-01)"
ok "agent config: .claude/" eq "$(c $'src/a.ts\n.claude/settings.json' "" "" "" example-org/web 0)" "manual: changes agent config (.claude/settings.json)"
ok "agent config: .mcp.json" eq "$(c '.mcp.json' "" "" "" example-org/web 0)" "manual: changes agent config (.mcp.json)"
ok "agent config: a nested CLAUDE.md" eq "$(c 'apps/web/CLAUDE.md' "" "" "" example-org/web 0)" "manual: changes agent config (apps/web/CLAUDE.md)"
ok "agent config: AGENTS.md" eq "$(c 'AGENTS.md' "" "" "" example-org/web 0)" "manual: changes agent config (AGENTS.md)"
ok "a file merely named like it is not" eq "$(c 'docs/CLAUDE.md.txt' "" "" "" example-org/web 0)" auto
ok "freeze date not YYYY-MM-DD → manual" eq "$(lib eval 'AUTO_MERGE_UNTIL=2031-3-1; classify_pure src/a.ts "" "" "" example-org/web 0')" "manual: AUTO_MERGE_UNTIL (2031-3-1) is not a YYYY-MM-DD date"
ok "freeze date that is no date → manual" eq "$(lib eval 'AUTO_MERGE_UNTIL=2031-02-30; classify_pure src/a.ts "" "" "" example-org/web 0')" "manual: AUTO_MERGE_UNTIL (2031-02-30) is not a YYYY-MM-DD date"
ok "gh error reading the PR → retry (#94)" eq "$(lib classify 77)" "retry: gh error reading PR #77"
state 5 phase=review pr=51
p=$(pr 51 5 $HB); json pr51.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 51 *' pr51.json
json files51.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/51/files*' files51.json
json issue5.json '{"labels": [{"name": "module:ui"}]}'; route 'issue view 5 *' issue5.json
ok "classify from gh: auto" eq "$(lib classify 51)" auto
ok "canccu-classify prints it" eq "$(PATH="$fb:$PATH" "$root/bin/canccu-classify" 51)" auto
ok "canccu-classify other repo" eq "$(PATH="$fb:$PATH" "$root/bin/canccu-classify" 51 example-org/other)" "manual: another repo (example-org/other)"
json files51.json '[{"filename": "setup/x.sh"}]'
ok "classify from gh: setup/" eq "$(lib classify 51)" "manual: changes setup/ (setup/x.sh)"
json files51.json '[{"filename": "docs/ci.yml", "previous_filename": ".github/workflows/ci.yml"}]'
ok "a rename out of .github/ is manual" eq "$(lib classify 51)" "manual: changes .github/ (.github/workflows/ci.yml)"
jq -n '[range(3000) | {filename: "src/f\(.).ts"}]' > "$FAKE/files51.json"
ok "3000 files (the API's cap) → manual" eq "$(lib classify 51)" "manual: PR #51 lists 3000+ files (the API's cap)"
json files51.json '[{"filename": "src/a.ts"}]'
ok "classify for another issue than the PR closes → manual" eq "$(lib classify 51 6)" "manual: PR #51 closes #5, not #6"
json pr51.json "$(detail "$(jq '.closingIssuesReferences = [{number: 6}, {number: 5}]' <<<"$p")" 2030-11-05T10:00:00Z)"
json issue6.json '{"labels": [{"name": "manual-accept"}]}'; route 'issue view 6 *' issue6.json
ok "a PR closing two issues → manual (one may carry manual-accept)" eq "$(lib classify 51 5)" "manual: PR #51 closes more than one issue (5, 6)"
json pr51.json "$(detail "$(PR_FORK=true pr 51 5 $HB)" 2030-11-05T10:00:00Z)"
ok "a fork PR → manual: not ours" eq "$(lib classify 51)" "manual: not ours: PR #51 is from a fork"
json pr51.json "$(detail "$(PR_AUTHOR=mallory pr 51 5 $HB)" 2030-11-05T10:00:00Z)"
ok "another author → manual: not ours" eq "$(lib classify 51)" "manual: not ours: PR #51 is by mallory, not octo"
json pr51.json "$(detail "$(PR_BRANCH=feature-x pr 51 5 $HB)" 2030-11-05T10:00:00Z)"
ok "a branch not named for the issue → manual: not ours" eq "$(lib classify 51)" "manual: not ours: PR #51 branch feature-x is not 5-…"
json pr51.json "$(detail "$(PR_BRANCH=issue-5-x pr 51 5 $HB)" 2030-11-05T10:00:00Z)"
ok "issue-<n>-… branches are ours too" eq "$(lib classify 51)" auto
rm "$CANCCU_HOME/state/5"
ok "an issue the dispatcher does not manage → manual: not ours" eq "$(lib classify 51)" "manual: not ours: #5 is not managed by the dispatcher"
state 5 phase=review pr=52
route 'api --paginate repos/example-org/web/pulls/52/files*' FAIL
p=$(pr 52 5 $HC); json pr52.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 52 *' pr52.json
ok "files gh error → manual" eq "$(lib classify 52)" "manual: gh error reading the files of PR #52"

# ---------------------------------------------------------------- verdict parsing

env_new verdicts
HV=abc1234abc1234abc1234abc1234abc1234abcde
p=$(pr 50 5 $HV)
v() { lib verdict_of "$(detail "$p" 2030-11-05T10:00:00Z "$@")"; }
ok "pass with the full head sha, by the bot" eq "$(v "$(vcomment 2030-11-05T11:00:00Z $'Findings: none\n\nReview verdict: pass '"$HV"$'\n')")" pass
ok "older head: does not count" eq "$(v "$(vcomment 2030-11-05T11:00:00Z "Review verdict: pass $HB")")" ""
ok "no sha: does not count" eq "$(v "$(vcomment 2030-11-05T11:00:00Z 'Review verdict: pass')")" ""
ok "short sha: does not count" eq "$(v "$(vcomment 2030-11-05T11:00:00Z 'Review verdict: pass abc1234')")" ""
ok "not the reviewer account: does not count" eq "$(v "$(comment 2030-11-05T11:00:00Z "Review verdict: pass $HV")")" ""
ok "missing verdict line" eq "$(v "$(vcomment 2030-11-05T11:00:00Z $'Looks good to me.\nNo verdict here')")" ""
ok "verdict not on the last line" eq "$(v "$(vcomment 2030-11-05T11:00:00Z $'Review verdict: pass '"$HV"$'\nmore text')")" ""
ok "newest verdict wins" eq "$(v "$(vcomment 2030-11-05T11:00:00Z "Review verdict: pass $HV")" "$(vcomment 2030-11-05T11:30:00Z "Review verdict: changes $HV")")" changes
ok "an older-head verdict after a current one doesn't hide it" eq "$(v "$(vcomment 2030-11-05T11:00:00Z "Review verdict: changes $HV")" "$(vcomment 2030-11-05T11:30:00Z "Review verdict: pass $HB")")" changes
ok "manual is no verdict any more (review-gate: pass or changes)" eq "$(v "$(vcomment 2030-11-05T11:00:00Z "Review verdict: manual — breaking contract $HV")")" ""
ok "a verdict line in backticks counts" eq "$(v "$(vcomment 2030-11-05T11:00:00Z "\`Review verdict: pass $HV\`")")" pass
ok "bold and backticks count" eq "$(v "$(vcomment 2030-11-05T11:00:00Z "**\`Review verdict: changes $HV\`**")")" changes
ok "passed is not pass" eq "$(v "$(vcomment 2030-11-05T11:00:00Z "Review verdict: passed $HV")")" ""
ma() { lib maintainer_accept_of "$(detail "$p" 2030-11-05T10:00:00Z "$@")"; }
ok "Maintainer accept: before the verdict is read" eq "$(ma "$(vcomment 2030-11-05T11:00:00Z $'1. ok\n**Maintainer accept:** breaking contract (drops /v1/screens)\nReview verdict: pass '"$HV")")" "breaking contract (drops /v1/screens)"
ok "no Maintainer accept line → none" eq "$(ma "$(vcomment 2030-11-05T11:00:00Z "Review verdict: pass $HV")")" ""
ok "a Maintainer accept line by someone else does not count" eq "$(ma "$(comment 2030-11-05T11:00:00Z $'Maintainer accept: x\nReview verdict: pass '"$HV")")" ""
ok "a verdict already acted on does not count again" eq "$(lib verdict_of "$(detail "$p" x "$(vcomment 2030-11-05T11:00:00Z "Review verdict: pass $HV")")" 2030-11-05T11:00:00Z)" ""

env_new verdict-missing
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "Review verdict: pass $HB")")"
route 'pr view 50 *' pr50.json
state 5 phase=review pr=50 review_sha=$HA rounds=0
dispatch --once
ok "older-head verdict only → needs-you" has gh.log "left no review ending in \`Review verdict: pass|changes <head sha>\`"
ok "older-head verdict → no merge" hasnt gh.log "pr merge"

# ---------------------------------------------------------------- review loop

review_env loop-1 'Review verdict: changes' review
dispatch --once
ok "changes from the full review → the worker resumes once with the findings" grep -q '^--quiet --name #5 --fresh web 5 Rules for this run: .* The independent reviewer asked for changes on PR #50 (.*This is your one fix round.*src/a.ts:3 off by one.*turns=80 cost=20 min=45$' "$FAKE/worker.log"
ok "… stage fixing, the reviewed sha kept" eq "$(st 5 stage) $(st 5 reviewed_sha) $(st 5 phase)" "fixing $HA work"
ok "… the findings saved for the fix-check" grep -qF 'src/a.ts:3 off by one' "$CANCCU_HOME/reviews/50/$HA.findings.md"
ok "no round counter any more" eq "$(grep -c '^rounds=' "$CANCCU_HOME/state/5")" 0
review_env loop-no-stage 'Review verdict: changes' ''
dispatch --once
ok "an issue with no stage yet (adopted, older state) gets its one fix round too" eq "$(st 5 stage)" fixing
review_env loop-refused 'Review verdict: changes' review
touch "$FAKE/refuse"
dispatch --once
ok "a refused resume leaves the verdict to act on" eq "$(st 5 verdict_at)" ""
ok "… and the stage unchanged" eq "$(st 5 stage)" review
ok "… and no needs-you" hasnt gh.log "needs-you"
rm "$FAKE/refuse"; dispatch --once
ok "next pass: the worker resumes with the review" grep -q 'web 5 Rules for this run: .* The independent reviewer asked for changes on PR #50 ' "$FAKE/worker.log"
ok "… then the fix round is recorded" eq "$(st 5 stage) $(st 5 verdict_at)" "fixing 2030-11-05T11:00:00Z"
review_env pass-auto 'Review verdict: pass' review
dispatch --once
ok "pass + auto → gh pr merge --auto pinned to the head" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
ok "the verdict is marked acted on" eq "$(st 5 verdict_at)" 2030-11-05T11:00:00Z
ok "never --squash or --delete-branch" hasnt gh.log "--squash"
ok "phase merging (auto)" eq "$(st 5 phase) $(st 5 how)" "merging auto"
review_env pass-manual 'Review verdict: pass' review
json issue5.json '{"labels": [{"name": "manual-accept"}], "comments": []}'
dispatch --once
ok "pass + manual → awaiting-accept" has gh.log "issue edit 5 -R example-org/web --add-label awaiting-accept"
ok "pass + manual → PR comment with reason" has gh.log "pr comment 50 -R example-org/web --body Review passed; this PR waits for your accept: the issue has manual-accept."
ok "pass + manual → no merge" hasnt gh.log "pr merge"
review_env maintainer-accept $'Maintainer accept: destructive migration (drops a column)\nReview verdict: pass' review
dispatch --once
ok "pass + Maintainer accept → awaiting-accept" eq "$(st 5 phase)" accept
ok "… with the reason" has gh.log "waits for your accept: maintainer accept: destructive migration (drops a column)."
ok "… and no merge" hasnt gh.log "pr merge"
review_env accept-stale-label 'Review verdict: pass' review
p=$(pr 50 5 $HA green accepted); printf '%s\n' "$p" | prs
json issue5.json '{"labels": [{"name": "manual-accept"}], "comments": []}'
dispatch --once
ok "an accepted label from before the accept request is removed" has gh.log "pr edit 50 -R example-org/web --remove-label accepted"
ok "… before the accept is recorded" eq "$(st 5 phase)" accept
ok "… and nothing merges" hasnt gh.log "pr merge"
review_env pass-cutoff 'Review verdict: pass' review "AUTO_MERGE_UNTIL=2030-11-01"
dispatch --once
ok "after the cutoff a pass waits for accept" has gh.log "awaiting-accept"
review_env merge-fails 'Review verdict: pass' review
echo 'fail:pr merge' >> "$FAKE/routes"
dispatch --once
ok "merge error → needs-you" has gh.log "--add-label needs-you"

# ---------------------------------------------------------------- accept

accept_env() {   # accept_env <name> <accept_sha> <head> <pr labels> [who labelled] [when]
  env_new "$1"
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 "$3" green "$4" | prs
  state 5 phase=accept pr=50 "accept_sha=$2" rounds=0 "accept_at=$((NOW - 3600))"
  jq -n --arg u "${5:-octo}" --arg t "${6:-2030-11-05T11:30:00Z}" \
    '[{event: "labeled", label: {name: "needs-you"}, actor: {login: "octo"}, created_at: "2030-11-05T11:40:00Z"},
      {event: "labeled", label: {name: "accepted"}, actor: {login: $u}, created_at: $t}]' > "$FAKE/events50.json"
  route 'api --paginate repos/example-org/web/issues/50/events' events50.json
}
accept_env accepted $HA $HA accepted
dispatch --once
ok "accepted → gh pr merge --auto pinned to the accepted head" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
ok "accepted → phase merging (accepted)" eq "$(st 5 phase) $(st 5 how)" "merging accepted"
accept_env accepted-by-bot $HA $HA accepted "$BOT"
dispatch --once
ok "accepted added by the reviewer bot → no merge" hasnt gh.log "pr merge"
ok "… said once in the log" grep -q 'was not added by octo after the accept request' "$CANCCU_HOME/dispatch.log"
accept_env accepted-before $HA $HA accepted octo 2030-11-05T10:30:00Z
dispatch --once
ok "accepted added before the accept request → no merge" hasnt gh.log "pr merge"
accept_env accepted-events-error $HA $HA accepted
: > "$FAKE/routes"; route 'api --paginate repos/example-org/web/issues/50/events' FAIL
dispatch --once
ok "events gh error → no merge" hasnt gh.log "pr merge"
accept_env not-accepted $HA $HA ""
dispatch --once
ok "no accepted label → nothing" hasnt gh.log "pr merge"
accept_env accepted-push $HA $HB accepted
dispatch --once
ok "push after accept → accepted removed" has gh.log "pr edit 50 -R example-org/web --remove-label accepted"
ok "push after accept → no merge" hasnt gh.log "pr merge"
ok "push after accept → review again" eq "$(st 5 phase)" check
ok "push after accept → awaiting-accept dropped" has gh.log "issue edit 5 -R example-org/web --remove-label awaiting-accept"
env_new merging-push
{ issue 5 in-progress; } | issues
pr 50 5 $HB green accepted | prs
state 5 phase=merging pr=50 merge_sha=$HA how=accepted
dispatch --once
ok "push while merging → auto-merge disabled" has gh.log "pr merge 50 -R example-org/web --disable-auto"
ok "push while merging → accepted removed" has gh.log "--remove-label accepted"
merging_env() {   # merging_env <name> <merge_at> [autoMergeRequest json] [config...]
  env_new "$1" "${@:4}"
  { issue 5 in-progress; } | issues
  pr 50 5 $HA green | jq --argjson a "${3:-null}" '.autoMergeRequest = $a' | prs
  state 5 phase=merging pr=50 merge_sha=$HA how=auto "merge_at=$2"
  json mq.json '{"data": {"repository": {"pullRequest": {"mergeQueueEntry": null}}}}'
  route 'api graphql *' mq.json
}
merging_env merging-armed $((NOW - 600)) '{"enabledAt": "2030-11-05T11:50:00Z"}'
dispatch --once
ok "armed and waiting: nothing happens" hasnt gh.log "needs-you"
ok "… still merging" eq "$(st 5 phase)" merging
merging_env merging-off $((NOW - 600))
dispatch --once
ok "auto-merge switched off and not in the queue → needs-you" has gh.log "auto-merge was disabled or the merge queue rejected PR #50"
merging_env merging-queued $((NOW - 600))
json mq.json '{"data": {"repository": {"pullRequest": {"mergeQueueEntry": {"state": "QUEUED"}}}}}'
dispatch --once
ok "in the merge queue: no needs-you" hasnt gh.log "needs-you"
merging_env merging-just-armed $((NOW - 30))
dispatch --once
ok "just armed (GitHub may lag): no needs-you" hasnt gh.log "needs-you"
merging_env merging-too-long $((NOW - 241 * 60)) '{"enabledAt": "x"}'
dispatch --once
ok "armed past MERGE_WAIT_MIN → auto-merge disabled" has gh.log "pr merge 50 -R example-org/web --disable-auto"
ok "… and needs-you" has gh.log "has not merged 240 min after auto-merge was enabled"
merging_env merging-no-merge-at "" '{"enabledAt": "x"}'
dispatch --once
ok "a merging state from before merge_at gets one now" eq "$(st 5 merge_at)" "$NOW"
# a repo without auto-merge (allow_auto_merge false, or the --auto error) merges directly, with
# --squash --match-head-commit <full sha>, once CI is green on the reviewed head; else nothing
review_env direct-green 'Review verdict: pass' review
json repo.json '{"allow_auto_merge": false}'
dispatch --once
ok "no auto-merge, pass, green → merged directly, pinned to the full head" has gh.log "pr merge 50 -R example-org/web --squash --match-head-commit $HA"
ok "… never --auto" hasnt gh.log "--auto"
ok "… one merge only in the pass" eq "$(grep -c '^pr merge 50 ' "$FAKE/gh.log")" 1
ok "… logged as merged directly" grep -q '#5 PR #50: merged directly (auto)' "$CANCCU_HOME/dispatch.log"
ok "… merging, done" eq "$(st 5 phase) $(st 5 how) $(st 5 merge_mode)" "merging auto merged"
ok "… the verdict is acted on" eq "$(st 5 verdict_at)" 2030-11-05T11:00:00Z
ok "… the setting is read once in the pass" eq "$(grep -c '^api repos/example-org/web --jq .allow_auto_merge' "$FAKE/gh.log")" 1
dispatch --once
ok "the next pass (the PR still listed open) merges nothing again" eq "$(grep -c '^pr merge 50 ' "$FAKE/gh.log")" 1
ok "… and no needs-you" hasnt gh.log "needs-you"
review_env direct-auto-error 'Review verdict: pass' review
touch "$FAKE/no-auto-merge"
dispatch --once
ok "setting unknown: --auto tried first" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
ok "… its 'not allowed' error → merged directly" has gh.log "pr merge 50 -R example-org/web --squash --match-head-commit $HA"
ok "… logged as merged directly" grep -q '#5 PR #50: merged directly (auto)' "$CANCCU_HOME/dispatch.log"
ok "… no needs-you" hasnt gh.log "needs-you"
review_env direct-allowed 'Review verdict: pass' review
json repo.json '{"allow_auto_merge": true}'
dispatch --once
ok "auto-merge allowed → auto-merge, as before" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
ok "… never --squash" hasnt gh.log "--squash"
ok "… logged as auto-merge enabled" grep -q '#5 PR #50: auto-merge enabled (auto)' "$CANCCU_HOME/dispatch.log"
review_env direct-other-error 'Review verdict: pass' review
echo 'fail:pr merge' >> "$FAKE/routes"
dispatch --once
ok "another --auto error → needs-you, as before; no direct merge" eq "$(grep -c -- '--squash' "$FAKE/gh.log")/$(grep -c 'add-label needs-you' "$FAKE/gh.log")" 0/1
review_env direct-head-changed 'Review verdict: pass' review
json repo.json '{"allow_auto_merge": false}'
pr 50 5 $HB | prs
dispatch --once
ok "no auto-merge, head changed since the review → nothing merges" hasnt gh.log "pr merge 50 -R example-org/web --squash"
ok "… review again" eq "$(st 5 phase)" check
review_env direct-red 'Review verdict: pass' review
json repo.json '{"allow_auto_merge": false}'
pr 50 5 $HA red | prs
dispatch --once
ok "no auto-merge, CI red → nothing merges" hasnt gh.log "pr merge 50 -R example-org/web --squash"
ok "… needs-you" has gh.log "CI is red on PR #50 at aaaaaaa; not merged"
review_env direct-pending 'Review verdict: pass' review
json repo.json '{"allow_auto_merge": false}'
pr 50 5 $HA pending | prs
dispatch --once
ok "no auto-merge, CI pending → nothing merges yet" hasnt gh.log "pr merge 50 -R example-org/web --squash"
ok "… waits in merging, direct" eq "$(st 5 phase) $(st 5 merge_mode) $(st 5 merge_sha)" "merging direct $HA"
ok "… no needs-you" hasnt gh.log "needs-you"
pr 50 5 $HA green | prs
dispatch --once
ok "… CI green on the next pass → merged directly" has gh.log "pr merge 50 -R example-org/web --squash --match-head-commit $HA"
ok "… no auto-merge checks while waiting" hasnt gh.log "--disable-auto"
direct_env() {   # direct_env <name> <head> <ci> <merge_at> [config...]: waiting to merge HA directly
  env_new "$1" "${@:5}"
  { issue 5 in-progress; } | issues
  pr 50 5 "$2" "$3" | prs
  json repo.json '{"allow_auto_merge": false}'
  state 5 phase=merging pr=50 merge_sha=$HA how=accepted merge_mode=direct "merge_at=$4"
}
direct_env direct-wait-status $HA pending $((NOW - 600))
ok "canccu-status: a PR waiting to merge directly says so" \
  eq "$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1 | grep -c '#5 · PR #50 · merges directly once CI is green (accepted)')" 1
# the owner (#70): the leader's items follow under their own heading
owner_env() {
  env_new "$@"
  { issue 5 in-progress; issue 6 in-progress; issue 7 in-progress; issue 8 in-progress; } | issues
  state 5 phase=accept pr=50 "reason=manual: plan tier" owner=leader
  state 6 phase=accept pr=60 "reason=manual: users see it: web/a.tsx" owner=po
  state 7 phase=needs-you "reason=the worker stopped: crashed" "ny_at=$NOW" owner=leader
  state 8 phase=needs-you "reason=the worker finished without an open PR" "ny_at=$NOW" owner=po
}
waits() { PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1 | sed -n '/^awaiting accept/,/^not ours/p' | sed '$d'; }
a=$(lib ago "$NOW")
owner_env status-owner LEADER=on LEADER_ACCEPTS=technical
ok "canccu-status: the product owner's items first, the leader's under 'leader has it:'" eq "$(waits)" "awaiting accept (label the PR \`accepted\`, or canccu-ship <n>):
  #6 · PR #60 · manual: users see it: web/a.tsx
  leader has it:
    #5 · PR #50 · manual: plan tier
needs you:
  #8 · the worker finished without an open PR · $a
  leader has it:
    #7 · the worker stopped: crashed · $a"
owner_env status-owner-off
ok "canccu-status: LEADER=off: the lists of today, whatever owner a state holds" eq "$(waits)" "awaiting accept (label the PR \`accepted\`, or canccu-ship <n>):
  #5 · PR #50 · manual: plan tier
  #6 · PR #60 · manual: users see it: web/a.tsx
needs you:
  #7 · the worker stopped: crashed · $a
  #8 · the worker finished without an open PR · $a"

direct_env direct-wait-push $HB green $((NOW - 600))
dispatch --once
ok "a push while waiting to merge directly → nothing merges" hasnt gh.log "pr merge 50"
ok "… review again" eq "$(st 5 phase)" check
direct_env direct-wait-red $HA red $((NOW - 600))
dispatch --once
ok "CI turns red while waiting → nothing merges, needs-you" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/needs-you
direct_env direct-wait-long $HA pending $((NOW - 241 * 60))
dispatch --once
ok "CI pending past MERGE_WAIT_MIN → needs-you, nothing merges" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/needs-you
ok "… with the reason" has gh.log "PR #50 has not merged 240 min after the review passed; CI is not green on aaaaaaa"
direct_env direct-wait-green $HA green $((NOW - 600))
dispatch --once
ok "accepted, waiting, CI green → merged directly" has gh.log "pr merge 50 -R example-org/web --squash --match-head-commit $HA"
ok "… logged with how" grep -q '#5 PR #50: merged directly (accepted)' "$CANCCU_HOME/dispatch.log"
direct_env direct-merge-fails $HA green $((NOW - 600))
echo 'fail:pr merge' >> "$FAKE/routes"
dispatch --once
ok "the direct merge fails (e.g. a push just now) → needs-you" has gh.log "\`gh pr merge 50 --squash --match-head-commit aaaaaaa\` failed"
accept_env direct-accepted $HA $HA accepted
json repo.json '{"allow_auto_merge": false}'
dispatch --once
ok "no auto-merge, accepted by the user, green → merged directly" has gh.log "pr merge 50 -R example-org/web --squash --match-head-commit $HA"
ok "… never --auto" hasnt gh.log "--auto"
SH=aaaaaaa
review_env direct-short-sha 'Review verdict: pass' review
json repo.json '{"allow_auto_merge": false}'
p=$(pr 50 5 $SH); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "Review verdict: pass $SH")")"
lib eval "fetch; merge_auto 5 50 auto $SH"
ok "a head that is not a full 40-char sha → nothing merges" hasnt gh.log "pr merge"
ok "… needs-you" has gh.log "is not a full commit sha; not merged"
direct_env direct-short-state $HA green $((NOW - 600))
state 5 phase=merging pr=50 merge_sha=$SH how=accepted merge_mode=direct "merge_at=$((NOW - 600))"
pr 50 5 $SH | prs
lib eval "fetch; merge_direct 5 50"
ok "merge_direct with a short merge_sha in the state → nothing merges" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/needs-you
ok "is_full_sha: 40 hex chars only" eq "$(for x in $HA $SH ${HA^^} "${HA}0" ""; do lib is_full_sha "$x" && echo y || echo n; done | tr -d '\n')" ynnnn
# review fixes: a stale merge_mode never keeps auto-merge armed on an unreviewed head
env_new direct-stale-ship
{ issue 5 in-progress,awaiting-accept; } | issues
json repo.json '{"allow_auto_merge": true}'
pr 50 5 $HA | prs
state 5 phase=accept pr=50 accept_sha=$HA merge_mode=direct
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 > "$E/out" 2>&1
ok "canccu-ship clears an earlier merge_mode" eq "$(st 5 phase) $(st 5 merge_mode)" "merging "
pr 50 5 $HB | jq '.autoMergeRequest = {"enabledAt": "x"}' | prs
dispatch --once
ok "… a push after it → auto-merge disabled" has gh.log "pr merge 50 -R example-org/web --disable-auto"
ok "… review again" eq "$(st 5 phase)" check
direct_env direct-stale-armed $HB green $((NOW - 600))
pr 50 5 $HB | jq '.autoMergeRequest = {"enabledAt": "x"}' | prs
dispatch --once
ok "direct mode, a push, auto-merge armed on GitHub → disabled" has gh.log "pr merge 50 -R example-org/web --disable-auto"
direct_env direct-stale-merged $HB green $((NOW - 600))
state 5 phase=merging pr=50 merge_sha=$HA how=accepted merge_mode=merged "merge_at=$((NOW - 600))"
pr 50 5 $HB | jq '.autoMergeRequest = {"enabledAt": "x"}' | prs
dispatch --once
ok "merge_mode merged, yet a new head and armed → disabled, review again" eq "$(grep -c -- '--disable-auto' "$FAKE/gh.log")/$(st 5 phase)" 1/check
direct_env direct-merged-open $HA green $((NOW - 241 * 60))
state 5 phase=merging pr=50 merge_sha=$HA how=auto merge_mode=merged "merge_at=$((NOW - 241 * 60))"
dispatch --once
ok "merged directly but the PR still open past MERGE_WAIT_MIN → needs-you" has gh.log "PR #50 is still open 240 min after the direct merge"
direct_env direct-merged-recent $HA green $((NOW - 600))
state 5 phase=merging pr=50 merge_sha=$HA how=auto merge_mode=merged "merge_at=$((NOW - 600))"
dispatch --once
ok "… before that: nothing" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/merging
env_new direct-needs-work
{ issue 5 in-progress,awaiting-accept,needs-work; } | issues
pr 50 5 $HA green accepted | prs
state 5 phase=merging pr=50 merge_sha=$HA how=accepted merge_mode=direct "accept_at=$NOW"
json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json
json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "needs-work while waiting to merge directly → accepted removed" has gh.log "pr edit 50 -R example-org/web --remove-label accepted"
ok "… nothing armed, nothing disarmed" hasnt gh.log "--disable-auto"
direct_env direct-gate-running $HA green $((NOW - 600)) 'REVIEW_CHECKS="review-gate"'
pr 50 5 $HA | jq '.statusCheckRollup += [{name: "review-gate", status: "IN_PROGRESS", conclusion: "", startedAt: "2030-11-05T11:59:00Z"}]' | prs
dispatch --once
ok "a REVIEW_CHECKS check still running on the head → wait, nothing merges" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/merging
pr 50 5 $HA | jq '.statusCheckRollup += [{name: "review-gate", status: "COMPLETED", conclusion: "SUCCESS", completedAt: "2030-11-05T11:59:30Z"}]' | prs
dispatch --once
ok "… once it completed → merged directly" has gh.log "pr merge 50 -R example-org/web --squash --match-head-commit $HA"
direct_env direct-gate-long $HA green $((NOW - 241 * 60)) 'REVIEW_CHECKS="review-gate"'
pr 50 5 $HA | jq '.statusCheckRollup += [{name: "review-gate", status: "IN_PROGRESS", conclusion: "", startedAt: "2030-11-05T11:59:00Z"}]' | prs
dispatch --once
ok "… still running past MERGE_WAIT_MIN → needs-you" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/needs-you
direct_env direct-no-checks $HA none $((NOW - 11 * 60))
dispatch --once
ok "no checks on the head past NO_CHECKS_MIN → needs-you, nothing merges" eq "$(grep -c '^pr merge' "$FAKE/gh.log")/$(st 5 phase)" 0/needs-you
ok "… with the reason" has gh.log "no CI checks on PR #50 at aaaaaaa 10 min after the review passed"
review_env direct-accept-hint 'Review verdict: pass' review
json issue5.json '{"labels": [{"name": "manual-accept"}], "comments": []}'
json repo.json '{"allow_auto_merge": false}'
dispatch --once
ok "no auto-merge: the accept request names the label only, not canccu-ship" eq "$(grep -c 'add the label `accepted` to this PR' "$FAKE/gh.log")/$(grep -c 'canccu-ship' "$FAKE/gh.log")" 1/0
env_new ship
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 $HA | prs
state 5 phase=accept pr=50 accept_sha=$HA
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 > "$E/out" 2>&1
ok "canccu-ship → gh pr merge --auto pinned to the head" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
ok "canccu-ship → merging (accepted)" eq "$(st 5 phase) $(st 5 how)" "merging accepted"
ship_env() {   # ship_env <name>: PR 50 of managed issue 5 waits for the accept
  env_new "$1"
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 $HA | prs
  state 5 phase=accept pr=50 accept_sha=$HA
}
ship_env ship-squash
json settings.json '{"data": {"repository": {"mergeQueue": null, "squashMergeAllowed": true, "mergeCommitAllowed": false, "rebaseMergeAllowed": false}}}'
route 'api graphql *mergeQueue {*' settings.json
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 > "$E/out" 2>&1
ok "canccu-ship in a squash-only repo → --auto --squash pinned to the head" has gh.log "pr merge 50 -R example-org/web --auto --squash --match-head-commit $HA"
ship_env ship-direct
json repo.json '{"allow_auto_merge": false}'
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 > "$E/out" 2>&1
ok "canccu-ship without auto-merge → merged directly" has gh.log "pr merge 50 -R example-org/web --squash --match-head-commit $HA"
ok "… never --auto" hasnt gh.log "--auto"
ok "… the state as merge_auto leaves it" eq "$(st 5 phase) $(st 5 how) $(st 5 merge_mode)" "merging accepted merged"
env_new ship-unmanaged
{ issue 5 in-progress; } | issues
pr 50 5 $HA | prs
json settings.json '{"data": {"repository": {"mergeQueue": null, "squashMergeAllowed": false, "mergeCommitAllowed": true, "rebaseMergeAllowed": false}}}'
route 'api graphql *mergeQueue {*' settings.json
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 > "$E/out" 2>&1
ok "canccu-ship on a PR not managed yet → --auto with the repo's method" has gh.log "pr merge 50 -R example-org/web --auto --merge --match-head-commit $HA"
ok "… no state written" eq "$(test -e "$CANCCU_HOME/state/5" && echo managed)" ""

# ---------------------------------------------------------------- resume

env_new resume-plan-ok
{ issue 5 in-progress,needs-you,plan-ok; } | issues
state 5 phase=needs-you pr=50 "ny_at=$NOW"
json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json; json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "plan-ok → label removed" has gh.log "issue edit 5 -R example-org/web --remove-label plan-ok"
ok "plan-ok → resumed" grep -q 'web 5 The user approved the plan. Execute it.' "$FAKE/worker.log"
ok "plan-ok recorded" eq "$(st 5 plan_ok)" 1
ok "plan-ok, no comment → no answer in the resume" not grep -q 'answered the questions' "$FAKE/worker.log"
env_new resume-plan-ok-answer
{ issue 5 in-progress,needs-you,plan-ok; } | issues
state 5 phase=needs-you pr=50 "ny_at=$NOW"
json issue5.json "$(jq -n --argjson a "$(comment 2030-11-05T12:30:00Z 'split; build package 1 only')" \
  --argjson c "$(comment 2030-11-05T11:00:00Z 'old note')" '{comments: [$a, $c]}')"
route 'issue view 5 *' issue5.json
json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "plan-ok + an answer → the resume carries it" grep -q 'web 5 The user approved the plan. .*The user answered the questions of the plan: split; build package 1 only Do not review' "$FAKE/worker.log"
ok "… and not the comments from before the needs-you" not grep -q 'old note' "$FAKE/worker.log"
env_new resume-plan-ok-gh-error
{ issue 5 in-progress,needs-you,plan-ok; } | issues
state 5 phase=needs-you pr=50 "ny_at=$NOW"
route 'issue view 5 *' FAIL
dispatch --once
ok "plan-ok, gh error on the comments → not resumed, plan-ok kept" eq "$(grep -c 'approved the plan' "$FAKE/worker.log")/$(grep -c 'remove-label plan-ok' "$FAKE/gh.log")" 0/0
env_new resume-answer
{ issue 5 in-progress,needs-you; } | issues
state 5 phase=needs-you "ny_at=$NOW"
json issue5.json "$(jq -n --argjson a "$(comment 2030-11-05T12:30:00Z 'Use port 8080.')" \
  --argjson b "$(comment 2030-11-05T12:31:00Z 'note <!-- canccu-dispatch -->')" \
  --argjson c "$(comment 2030-11-05T11:00:00Z 'old answer')" '{comments: [$a, $b, $c]}')"
route 'issue view 5 *' issue5.json
dispatch --once
ok "user comment → resumed with it" grep -q 'web 5 Rules for this run: .* The user answered: Use port 8080. This run is a fresh session.* Do not review your own work; run the checks only. turns=' "$FAKE/worker.log"
ok "needs-you dropped on resume" has gh.log "issue edit 5 -R example-org/web --remove-label needs-you"
env_new resume-paused-backoff
{ issue 5 in-progress; issue 6 ready; } | issues
state 5 phase=limited
echo $((NOW + 600)) > "$CANCCU_ROOT/backoff"
dispatch --once
ok "back-off: nothing starts" eq "$(wc -l < "$FAKE/worker.log")" 0
echo $((NOW - 1)) > "$CANCCU_ROOT/backoff"; touch "$CANCCU_HOME/paused"
dispatch --once
ok "paused: no new issue" not started 6
ok "paused: a limited worker resumes after the back-off" grep -q 'web 5 Rules for this run: .* The usage limit has reset' "$FAKE/worker.log"

# needs-work on the PR of a unit in accept moves to the lead issue, where the issue's path handles it (#154)
nw_pr_env() {   # nw_pr_env <name> <issue labels> <pr labels>
  env_new "$1"
  { issue 5 "$2"; } | issues
  pr 50 5 $HA green "$3" | prs
  state 5 phase=accept pr=50 "accept_sha=$HA" rounds=0 "accept_at=$((NOW - 3600))"
  json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json
  json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
}
nw_pr_env needs-work-on-pr in-progress,awaiting-accept needs-work
dispatch --once
ok "needs-work on the PR → added to the lead issue" has gh.log "issue edit 5 -R example-org/web --add-label needs-work"
ok "… removed from the PR" has gh.log "pr edit 50 -R example-org/web --remove-label needs-work"
ok "… logged" grep -qF '#5 PR #50: `needs-work` was on the PR; moved to issue #5' "$CANCCU_HOME/dispatch.log"
ok "… and the fix run starts on the same pass" grep -q 'web 5 Rules for this run: .* The user rejected PR #50' "$FAKE/worker.log"
ok "… then needs-work leaves the issue" has gh.log "issue edit 5 -R example-org/web --remove-label needs-work"
nw_pr_env needs-work-on-pr-gh-error in-progress,awaiting-accept needs-work
echo 'fail:issue edit' >> "$FAKE/routes"
dispatch --once
ok "needs-work on the PR, gh error on the move → the PR keeps it" hasnt gh.log "pr edit 50 -R example-org/web --remove-label needs-work"
ok "… logged as a retry" grep -qF '#5 PR #50: gh error moving `needs-work`; retrying next pass' "$CANCCU_HOME/dispatch.log"
ok "… no run starts" not grep -q 'The user rejected PR #50' "$FAKE/worker.log"
nw_pr_env needs-work-on-issue in-progress,awaiting-accept,needs-work ""
dispatch --once
ok "needs-work on the issue → the fix run starts as before" grep -q 'web 5 Rules for this run: .* The user rejected PR #50' "$FAKE/worker.log"
ok "… nothing moved" eq "$(grep -c 'add-label needs-work\|pr edit 50 .*--remove-label needs-work' "$FAKE/gh.log")" 0
ok "… needs-work leaves the issue" has gh.log "issue edit 5 -R example-org/web --remove-label needs-work"

# ---------------------------------------------------------------- after merge

env_new after-merge
{ issue 6 blocked "Blocked by #5"; issue 7 blocked "Blocked by #5"$'\n'"Blocked by #8"; issue 8 ""
  issue 9 epic $'Order: #5 → #6'; } | issues
state 5 phase=merging pr=50 how=auto merge_sha=$HA
json pr50.json '{"state": "MERGED", "title": "feat: thing"}'; route 'pr view 50 *' pr50.json
json issue5.json '{"state": "CLOSED", "labels": [{"name": "in-progress"}]}'; route 'issue view 5 *' issue5.json
json subs9.json '[{"number": 5, "state": "closed"}, {"number": 6, "state": "closed"}]'
route 'api --paginate repos/example-org/web/issues/9/sub_issues' subs9.json
mkdir -p "$CANCCU_HOME/blocked"; for b in 6 7; do : > "$CANCCU_HOME/blocked/$b"; done   # the dispatcher's own labels
echo sid > "$WORKERS_DIR/web-5.id"
dispatch --once
ok "merge logged" grep -qP "^$NOW\t5\t50\tauto\tfeat: thing$" "$CANCCU_HOME/merged.log"
ok "state cleared" test ! -e "$CANCCU_HOME/state/5"
ok "in-progress dropped" has gh.log "issue edit 5 -R example-org/web --remove-label in-progress"
ok "session id cleared" test ! -e "$WORKERS_DIR/web-5.id"
ok "unblocked dependent → ready" has gh.log "issue edit 6 -R example-org/web --remove-label blocked --add-label ready"
ok "still-blocked dependent stays" hasnt gh.log "issue edit 7"
ok "epic with all sub-issues closed → closed" has gh.log "issue close 9 -R example-org/web"

# ---------------------------------------------------------------- unblock, whatever closed the blockers

env_new unblock-any
{ issue 6 blocked "Blocked by #5"; issue 7 blocked; issue 8 blocked; issue 9 blocked "Blocked by #10"; issue 10 ""
  issue 11 blocked; issue 12 blocked "Blocked by #13"; issue 14 blocked; issue 15 blocked "Blocked by #5"; } | issues
json issue5.json '{"state": "CLOSED"}'; route 'issue view 5 *' issue5.json
route 'issue view 13 *' FAIL
json deps8.json '[{"number": 20, "state": "closed"}, {"number": 21, "state": "closed"}]'
route 'api repos/example-org/web/issues/8/dependencies/blocked_by' deps8.json
json deps11.json '[{"number": 20, "state": "closed"}, {"number": 22, "state": "open"}]'
route 'api repos/example-org/web/issues/11/dependencies/blocked_by' deps11.json
route 'api repos/example-org/web/issues/14/dependencies/blocked_by' FAIL
json deps15.json '[{"number": 22, "state": "open"}]'
route 'api repos/example-org/web/issues/15/dependencies/blocked_by' deps15.json
mkdir -p "$CANCCU_HOME/blocked"; for b in 6 7 8 9 11 12 14 15; do : > "$CANCCU_HOME/blocked/$b"; done   # the dispatcher's own labels
dispatch --once
ok "unblock: a body blocker closed by hand (no merge) → ready" has gh.log "issue edit 6 -R example-org/web --remove-label blocked --add-label ready"
ok "… logged as unblocked" grep -q '#6 unblocked: blocked → ready' "$E/out"
ok "unblock: API blockers all closed (an epic, a checkpoint) → ready" has gh.log "issue edit 8 -R example-org/web --remove-label blocked --add-label ready"
ok "unblock: no blocked-by link → left alone" hasnt gh.log "issue edit 7 "
ok "unblock: a body blocker still open → stays blocked" hasnt gh.log "issue edit 9 "
ok "unblock: one API blocker still open → stays blocked" hasnt gh.log "issue edit 11 "
ok "unblock: a body blocker off the open list that cannot be confirmed closed → stays blocked" hasnt gh.log "issue edit 12 "
ok "unblock: dependencies API error → stays blocked" hasnt gh.log "issue edit 14 "
ok "unblock: body blocker closed, API blocker open → stays blocked" hasnt gh.log "issue edit 15 "
env_new unblock-start
{ issue 6 blocked "Blocked by #5"; } | issues
json issue5.json '{"state": "CLOSED"}'; route 'issue view 5 *' issue5.json
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/6"   # the dispatcher's own labels
dispatch --once
ok "unblock: the issue is ready in this very pass (it starts)" started 6
env_new unblock-edit-fails
{ issue 6 blocked "Blocked by #5"; } | issues
json issue5.json '{"state": "CLOSED"}'; route 'issue view 5 *' issue5.json
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/6"   # the dispatcher's own labels
echo 'fail:issue edit' >> "$FAKE/routes"
dispatch --once
ok "unblock: a failed label edit → not logged as unblocked, nothing starts" eq "$(grep -c '#6 unblocked' "$E/out")$(started 6 && echo started)" 0

# ---------------------------------------------------------------- adoption

env_new adopt
{ issue 5 in-progress,manual-accept; issue 6 ready; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
pr 51 6 $HB >> "$FAKE/prs.json"; jq -s '.[0] + [.[1]]' "$FAKE/prs.json" > "$FAKE/p.tmp" 2>/dev/null && mv "$FAKE/p.tmp" "$FAKE/prs.json"
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "canccu-status: an adoptable PR is not listed as not ours" not grep -q '^  PR #50 ' "$E/status"
ok "canccu-status: our PR for an issue nobody started is not ours" grep -qF 'PR #51 · #6 is not managed by the dispatcher' "$E/status"
dispatch --once
ok "in-progress PR without a worker is adopted and reviewed" grep -q -- '--key review-50' "$FAKE/worker.log"

# ---------------------------------------------------------------- digest

env_new digest DIGEST_HOUR_UTC=6
printf '%s\t5\t50\tauto\tfeat: thing\n%s\t4\t40\taccepted\told one\n' "$((NOW - 3600))" "$((NOW - 90000))" > "$CANCCU_HOME/merged.log"
{ issue 8 needs-you; } | issues
json runs.json '[{"headSha": "x", "status": "completed", "conclusion": "success", "workflowName": "ci"}]'
dispatch --once
f="$CANCCU_HOME/digest/2030-11-05.md"
ok "digest file written" test -s "$f"
ok "digest lists the merge of the last 24 h" grep -qF -- '- #5 feat: thing · PR #50 · auto' "$f"
ok "digest leaves out older merges" not grep -qF 'old one' "$f"
ok "digest lists needs-you" grep -qF -- '- #8 Issue 8' "$f"
ok "digest CI on main" grep -qF '**CI on main:** green' "$f"
ok "digest comment on DIGEST_ISSUE" has gh.log "issue comment 42 -R example-org/web --body-file $f"
: > "$FAKE/gh.log"; dispatch --once
ok "digest once a day" hasnt gh.log "issue comment 42"
env_new digest-quiet DIGEST_HOUR_UTC=6
json runs.json '[{"headSha": "x", "status": "completed", "conclusion": "success", "workflowName": "ci"}]'
dispatch --once
ok "quiet day: file written" test -s "$CANCCU_HOME/digest/2030-11-05.md"
ok "quiet day: no comment" hasnt gh.log "issue comment 42"
env_new digest-early DIGEST_HOUR_UTC=13
printf '%s\t5\t50\tauto\tfeat\n' "$((NOW - 60))" > "$CANCCU_HOME/merged.log"
dispatch --once
ok "before DIGEST_HOUR_UTC: no digest" test ! -e "$CANCCU_HOME/digest/2030-11-05.md"

# ---------------------------------------------------------------- dry run

env_new dry DIGEST_HOUR_UTC=6
{ issue 1 ready; issue 5 in-progress; issue 6 in-progress,plan-ok; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "Review verdict: pass $HA")")"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
json issue5.json '{"labels": [{"name": "in-progress"}]}'; route 'issue view 5 *' issue5.json
state 6 phase=needs-you
before=$(find "$CANCCU_HOME" -type f -printf '%p %s %T@\n' | sort)
dispatch --dry-run
ok "dry-run prints the queue" grep -qx '  #1' "$E/out"
ok "dry-run prints PR classification" grep -qF 'PR #50 (closes #5) · draft false · CI green · auto' "$E/out"
ok "dry-run shows the would-be merge" grep -qF 'would: gh pr merge 50 -R example-org/web --auto' "$E/out"
ok "dry-run makes no GitHub writes" not grep -qE '^(issue (edit|comment|close)|pr (edit|merge|comment)|label create)' "$FAKE/gh.log"
ok "dry-run starts nothing" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "dry-run writes no file" eq "$(find "$CANCCU_HOME" -type f -printf '%p %s %T@\n' | sort)" "$before"

# ---------------------------------------------------------------- failure paths

env_new plan-ok-refused
{ issue 5 in-progress,needs-you,plan-ok; } | issues
state 5 phase=needs-you "ny_at=$NOW"
touch "$FAKE/refuse"
dispatch --once
ok "failed resume keeps plan-ok for the next pass" hasnt gh.log "--remove-label plan-ok"
ok "failed resume keeps the phase" eq "$(st 5 phase)" needs-you

env_new needs-work-merging
{ issue 5 in-progress,awaiting-accept,needs-work; } | issues
pr 50 5 $HA green accepted | prs
state 5 phase=merging pr=50 merge_sha=$HA how=accepted "accept_at=$NOW"
json issue5.json '{"comments": []}'; route 'issue view 5 *' issue5.json
json pr50.json '{"comments": []}'; route 'pr view 50 *' pr50.json
dispatch --once
ok "needs-work on an armed PR → auto-merge disabled" has gh.log "pr merge 50 -R example-org/web --disable-auto"
ok "needs-work on an armed PR → accepted removed" has gh.log "pr edit 50 -R example-org/web --remove-label accepted"
ok "needs-work → worker resumed" grep -q 'web 5 Rules for this run: .* The user rejected PR #50' "$FAKE/worker.log"
ok "needs-work removed after the start" has gh.log "issue edit 5 -R example-org/web --remove-label needs-work"

env_new stale-lock
{ issue 30 ready; } | issues
printf 'repo=web\nkey=30\nkind=worker\npid=999999999\nwindow=\n' > "$WORKERS_DIR/web-30.lock"
dispatch --once
ok "a stale lock is cleared before the start" grep -q '^--unlock web 30$' "$FAKE/worker.log"
ok "then the issue starts" started 30

env_new stale-review-report
{ issue 5 in-progress; } | issues
p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=review pr=50 review_sha=$HA "started=$((NOW + 120))"
last review-50 error "usage limit reached · resets 3pm (UTC)"   # written before this review started
dispatch --once
ok "an older review report is not this review's result" test ! -e "$CANCCU_ROOT/backoff"
ok "no verdict → needs-you" has gh.log "left no review ending in \`Review verdict: pass|changes <head sha>\`"

env_new issue-not-in-list
echo '[]' > "$FAKE/issues.json"
state 5 phase=work pr=50 "started=$NOW"
json issue5.json '{"state": "OPEN", "labels": []}'; route 'issue view 5 *' issue5.json
dispatch --once
ok "an issue missing from the capped list is not finished" test -e "$CANCCU_HOME/state/5"

env_new canccu-stop-idle
state 5 phase=accept pr=50
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-stop" 5 > "$E/out" 2>&1
ok "canccu-stop with nothing running keeps the phase" eq "$(st 5 phase)" accept
live_lock 5
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-stop" 5 > "$E/out" 2>&1
ok "canccu-stop kills the run" grep -q '^--kill web 5$' "$FAKE/worker.log"
ok "canccu-stop marks it stopped" eq "$(st 5 phase)" stopped

env_new canccu-run-ship
{ issue 5 in-progress; } | issues
state 5 phase=needs-you
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-run" 5 ship it after the fix > "$E/out" 2>&1
ok "canccu-run never hands the engine a leading word" grep -q 'web 5 Rules for this run: .* The user says: ship it after the fix This run is a fresh session.* Do not review your own work; run the checks only. turns=' "$FAKE/worker.log"

# ---------------------------------------------------------------- contract-first for a single issue (#87)

env_new issue-branch
{ issue 5 ready; } | issues
dispatch --once
ok "start_issue keeps the issue's branch, the one its prompt names" \
  eq "$(st 5 branch) $(grep -c -- 'Create your branch 5-issue-5 from origin/main' "$FAKE/worker.log")" "5-issue-5 1"

# cenv <name> <pr json>: managed #5 (branch 5-issue-5) in check with that PR 50
cenv() {
  env_new "$1"
  { issue 5 in-progress; } | issues
  printf '%s\n' "$2" | prs
  json pr50.json "$(detail "$2" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "docs/plans/issue-5.md"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
  state 5 phase=check pr=50 branch=5-issue-5
}
cenv classify-contract "$(PR_BRANCH=5-issue-5-contract pr 50 5 $HA green "" false 'Closes #5')"
ok "classify: a single issue's PR on <branch>-contract that closes it → manual" \
  eq "$(lib eval 'fetch; classify 50')" "manual: PR #50 closes 5 on the contract branch 5-issue-5-contract"
cenv classify-names-none "$(pr 50 5 $HA green "" false 'A fix.' | jq '.closingIssuesReferences = []')"
ok "classify: a PR on branch 5-… with no Closes and no Plan for → manual: closes no issue" \
  eq "$(lib eval 'fetch; classify 50')" "manual: PR #50 closes no issue"
cenv classify-plan-for "$(pr 50 5 $HA green "" false $'Plan for #5\n\nTier: plan' | jq '.closingIssuesReferences = []')"
ok "… with a Plan for #5 line before plan-ok: classified as before (plan tier)" eq "$(lib eval 'fetch; classify 50')" "manual: plan tier"

env_new contract-prompts
{ issue 5 ready; issue 101 ready; } | issues
state 5 phase=work branch=5-issue-5
state pkg-12-a pkg=a step=12 members=101 branch=pkg-12-a risk=low risk_reason=x
ok "the single-issue prompt has the contract rule for its branch" grep -qF -- "$(lib contract_rule 5-issue-5)" <<<"$(lib eval 'fetch; unit_prompt 5')"
ok "… the package prompt for its own" grep -qF -- "$(lib contract_rule pkg-12-a)" <<<"$(lib eval 'fetch; unit_prompt pkg-12-a')"
ok "… which names the contract branch" grep -qF 'from the branch pkg-12-a-contract with `Refs #<n>`' <<<"$(lib contract_rule pkg-12-a)"
NOKW='Never write a closing keyword (close, fix, resolve, in any form) before an issue number anywhere in the contract PR'
ok "… the single-issue prompt forbids a closing keyword in the contract PR's body (#98)" grep -qF -- "$NOKW" <<<"$(lib eval 'fetch; unit_prompt 5')"
ok "… the package prompt too" grep -qF -- "$NOKW" <<<"$(lib eval 'fetch; unit_prompt pkg-12-a')"
SR=$(lib eval 'echo "$SKILL_RULES"')
ok "both prompts have the one skill rule, which forbids subagents (#88)" eq "$(grep -c dispatching-parallel-agents <<<"$SR") $(grep -cF -- "$SR" <<<"$(lib eval 'fetch; unit_prompt 5')") $(grep -cF -- "$SR" <<<"$(lib eval 'fetch; unit_prompt pkg-12-a')")" "1 1 1"
ok "… the package prompt no longer allows them" not grep -q 'You may use the superpowers skills subagent' <<<"$(lib eval 'fetch; unit_prompt pkg-12-a')"

# #107: an empty key names the state directory, not a file: nothing, and no read error
# ---------------------------------------------------------------- stale run temp dirs (#155)

# at start: a temp dir whose run is gone and that is over an hour old goes; a live run's stays,
# and so does a young one (a run that is just starting)
env_new tmp-sweep
sleep 30 & sp=$!
mkdir -p "$WORKERS_DIR/tmp/web-5.999999/ro/d" "$WORKERS_DIR/tmp/web-6.$sp" "$WORKERS_DIR/tmp/web-7.999998" "$WORKERS_DIR/tmp/web-8.999997"
chmod 555 "$WORKERS_DIR/tmp/web-5.999999/ro/d"   # a read-only dir (a Go module cache) goes too
printf 'repo=web\nkey=6\nkind=worker\npid=%s\npstart=%s\nwindow=\n' "$sp" "$(lib proc_start "$sp")" > "$WORKERS_DIR/web-6.lock"
printf 'repo=web\nkey=8\nkind=worker\npid=1\nwindow=\n' > "$WORKERS_DIR/web-8.lock"   # another run's pid: not this dir's
touch -d '2 hours ago' "$WORKERS_DIR/tmp/web-5.999999" "$WORKERS_DIR/tmp/web-6.$sp" "$WORKERS_DIR/tmp/web-8.999997"
dispatch --once
ok "tmp sweep: a stale dir with no live run is removed at start" eq "$(ls "$WORKERS_DIR/tmp" | tr '\n' ' ')" "web-6.$sp web-7.999998 "
ok "… logged once with the count" eq "$(grep -c 'removed 2 stale run temp dirs' "$CANCCU_HOME/dispatch.log")" 1
dispatch --once
ok "… nothing left to remove: no line" eq "$(grep -c 'stale run temp dirs' "$CANCCU_HOME/dispatch.log")" 1
kill "$sp"; wait "$sp" 2>/dev/null

env_new st-get-empty
ok "st_get with an empty key prints nothing and returns 0" eq "$( ( PATH="$fb:$PATH"; . "$root/lib/canccu-common.sh"; set -u; st_get "" phase; echo "rc=$?" ) 2>&1)" "rc=0"

echo "canccu-dispatch tests: $npass passed, $nfail failed"
(( nfail == 0 ))
