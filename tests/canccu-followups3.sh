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

echo "canccu-followups3 tests: $npass passed, $nfail failed"; (( nfail == 0 ))
