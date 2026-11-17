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

echo "canccu-followups3 tests: $npass passed, $nfail failed"; (( nfail == 0 ))
