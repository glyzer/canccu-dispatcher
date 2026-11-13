#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-pings.sh — pings (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- ping the product owner

# pings <glob>: the comments posted as the reviewer bot whose gh.log line matches (one per line)
pings() { grep -cE -- "$1" <(paste <(cut -f2 "$FAKE/gh.env") "$FAKE/gh.log" | grep -P '^reviewer\t' | cut -f2-); }
NYLINE='@octo this issue needs you (`needs-you`): the latest comments say why.'

env_new ping-needs-you PING_KINDS=all
{ issue 8 needs-you; issue 9 ""; } | issues
dispatch --once
ok "needs-you → one comment as the reviewer bot" eq "$(pings '^issue comment 8 -R example-org/web --body ')" 1
ok "… starting with @USER_LOGIN, one line saying what is needed" has gh.log "issue comment 8 -R example-org/web --body $NYLINE"
ok "… on nothing else" eq "$(pings '^(issue|pr) comment')" 1
ok "… recorded in the state dir" eq "$(cat "$CANCCU_HOME/pings/8" 2>/dev/null)" needs-you
ok "… and logged" grep -q '#8 pinged @octo as review-bot: needs-you' "$CANCCU_HOME/dispatch.log"
dispatch --once
ok "a second pass, unchanged: no new ping" eq "$(pings '^issue comment 8 ')" 1
{ issue 8 ""; issue 9 ""; } | issues
dispatch --once
ok "needs-you cleared: no ping, the record goes" eq "$(pings '^issue comment 8 ') $(test -e "$CANCCU_HOME/pings/8"; echo $?)" "1 1"
{ issue 8 needs-you; issue 9 ""; } | issues
dispatch --once
ok "cleared, then needs-you again: a new ping" eq "$(pings '^issue comment 8 ')" 2

env_new ping-accept
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 $HA green | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual: changes .github/ (.github/workflows/ci.yml)"
dispatch --once
ok "waiting for accept → one ping, on the issue" eq "$(pings '^issue comment 5 -R example-org/web --body @octo PR #50 waits for your accept')" 1
ok "… saying how to accept, without the classifier's reason" \
  has gh.log 'issue comment 5 -R example-org/web --body @octo PR #50 waits for your accept: label it `accepted`, or `canccu-ship 5`.'
ok "… never on the PR (the review-gate reads the bot's comments there)" eq "$(pings '^pr comment')" 0
ok "… nothing else pinged" eq "$(pings '^(issue|pr) comment')" 1
ok "… recorded" eq "$(cat "$CANCCU_HOME/pings/5" 2>/dev/null)" accept
dispatch --once
ok "… a second pass: none" eq "$(pings '^(issue|pr) comment')" 1

# the owner (#70): a mention goes only to the product owner's items
env_new ping-owner PING_KINDS=all LEADER=on LEADER_ACCEPTS=technical
{ issue 5 in-progress,awaiting-accept; issue 6 in-progress,awaiting-accept; } | issues
{ pr 50 5 $HA green; pr 60 6 $HB green; } | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual: plan tier"
state 6 phase=accept pr=60 accept_sha=$HB "accept_at=$((NOW - 60))" "reason=manual: users see it: web/pages/a.tsx"
dispatch --once
ok "owner: an accept of owner leader is not pinged" eq "$(pings '^issue comment 5 ') $(test -e "$CANCCU_HOME/pings/5"; echo $?)" "0 1"
ok "… one of owner po is" eq "$(pings '^issue comment 6 -R example-org/web --body @octo PR #60 waits for your accept')" 1

# a step's epic labelled needs-you by STEP_BUDGET or an invalid plan: po's, as the snapshot shows it
env_new ping-owner-step PING_KINDS=all LEADER=on LEADER_ACCEPTS=technical
{ issue 90 epic,needs-you; issue 91 epic,needs-you; issue 92 epic,needs-you; } | issues
mkdir -p "$CANCCU_HOME/steps"
printf 'phase=running\ntitle=3 Events\nepic=90\nbudget_ny=1\n' > "$CANCCU_HOME/steps/12"
printf 'phase=needs-you\ntitle=4 More\nepic=91\nny_reason=the plan of wave 2 is invalid: x\n' > "$CANCCU_HOME/steps/13"
printf 'phase=running\ntitle=5 Last\nepic=92\n' > "$CANCCU_HOME/steps/14"
ok "owner: LEADER=on, a STEP_BUDGET stop and an invalid plan are still pinged; another step needs-you is the leader's" \
  eq "$(lib eval "ISSUES=\$(cat '$FAKE/issues.json'); PRS='[]'; ping_states" | tr '\n' ' ')" "90 needs-you - 91 needs-you - END "

env_new ping-plan-question PING_KINDS=all
{ issue 5 in-progress,needs-you; issue 6 in-progress,needs-you; issue 7 in-progress,needs-you; } | issues
state 5 phase=needs-you "ny_at=$NOW" "reason=plan ready for OK: https://github.com/example-org/web/pull/50" ny_kind=plan
state 6 phase=needs-you "ny_at=$NOW" "reason=the worker's question needs the product owner (SECRET-QUESTION-TEXT)" ny_kind=question
state 7 phase=needs-you "ny_at=$NOW" "reason=the worker stopped: SECRET-WORKER-OUTPUT"
dispatch --once
ok "a plan waiting for approval → its own ping" \
  has gh.log 'issue comment 5 -R example-org/web --body @octo the plan here waits for your OK: label this issue `plan-ok`, or comment.'
ok "an escalated question → its own ping" \
  has gh.log 'issue comment 6 -R example-org/web --body @octo the worker'"'"'s question here needs the product owner: answer it in a comment.'
ok "any other needs-you → the plain ping" has gh.log "issue comment 7 -R example-org/web --body $NYLINE"
ok "… one each" eq "$(pings '^issue comment')" 3
ok "no event content in a ping" eq "$(grep -cE 'SECRET-|pull/50' <(grep -E '^issue comment [567] ' "$FAKE/gh.log"))" 0
ok "… and no secret: the token is in no gh argument, log or record" \
  eq "$(cat "$FAKE/gh.log" "$CANCCU_HOME/dispatch.log" "$CANCCU_HOME"/pings/* | grep -c "$FAKE_TOKEN")" 0

env_new ping-pr-needs-you PING_KINDS=all
{ issue 5 in-progress; issue 6 ""; } | issues
{ pr 50 5 $HA green needs-you; PR_AUTHOR=someone pr 60 6 $HB green needs-you; } | prs
state 5 phase=check pr=50 "check_at=$NOW"
route 'pr view 50 *' FAIL
dispatch --once
ok "our PR labelled needs-you → one ping, on its issue" eq "$(pings "^issue comment 5 -R example-org/web --body @octo PR #50 needs you")" 1
ok "… a PR that is not ours: none" eq "$(pings '^(issue|pr) comment (6|60) ')" 0
ok "… nothing on a PR" eq "$(pings '^pr comment')" 0

env_new ping-no-token PING_KINDS=all
{ issue 8 needs-you; issue 3 ready; } | issues
rm -f "$E/reviewer-token"
dispatch --once
ok "no bot token: no ping" eq "$(grep -cE '^(issue|pr) comment' "$FAKE/gh.log")" 0
ok "… logged" grep -q 'ping: no reviewer token file' "$CANCCU_HOME/dispatch.log"
ok "… the pass goes on (a worker starts, the snapshot is written)" eq "$(started 3 && echo y) $(test -e "$CANCCU_HOME/.pass-written" && echo y)" "y y"
ok "… nothing recorded: pinged once the token works" test ! -e "$CANCCU_HOME/pings/8"
dispatch --once
ok "… logged once, not every pass" eq "$(grep -c 'ping: no reviewer token file' "$CANCCU_HOME/dispatch.log")" 1
printf '%s\n' "$FAKE_TOKEN" > "$E/reviewer-token"; chmod 600 "$E/reviewer-token"
echo 'fail:issue comment' >> "$FAKE/routes"
dispatch --once
ok "a rejected token: logged" grep -q 'ping as review-bot failed (gh: ' "$CANCCU_HOME/dispatch.log"
ok "… nothing recorded" test ! -e "$CANCCU_HOME/pings/8"
ok "… the pass goes on" test -e "$CANCCU_HOME/.pass-written"
sed -i '/^fail:issue comment$/d' "$FAKE/routes"; : > "$FAKE/gh.log"; : > "$FAKE/gh.env"
dispatch --once
ok "… the token works again: the ping goes out" eq "$(pings '^issue comment 8 ')" 1
ok "… recorded" eq "$(cat "$CANCCU_HOME/pings/8" 2>/dev/null)" needs-you

env_new ping-off PING=off PING_KINDS=all
{ issue 8 needs-you; } | issues
dispatch --once
ok "PING=off: no ping" eq "$(grep -cE '^(issue|pr) comment' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/pings/8"; echo $?)" "0 1"

env_new ping-dry PING_KINDS=all
{ issue 8 needs-you; } | issues
dispatch --dry-run
ok "--dry-run: no ping, nothing recorded" eq "$(grep -cE '^(issue|pr) comment' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/pings/8"; echo $?)" "0 1"
ok "… says it would" grep -q "would: ping #8 as review-bot: $NYLINE" "$E/out"

# review of f6f65c3, finding 1: a rejected token with two pings pending is logged once, not every pass
env_new ping-reject-two PING_KINDS=all
{ issue 8 needs-you; issue 9 needs-you; } | issues
echo 'fail:issue comment' >> "$FAKE/routes"
dispatch --once; dispatch --once
ok "two pings pending, the token rejected: logged once over two passes" eq "$(grep -c 'ping as review-bot failed' "$CANCCU_HOME/dispatch.log")" 1
ok "… after the first failed post the pass tries no other" eq "$(grep -c '^issue comment' "$FAKE/gh.log")" 2
ok "… nothing recorded" eq "$(ls "$CANCCU_HOME/pings" 2>/dev/null | wc -l)" 0

# finding 2: a state the user already answered by label is not pinged (this pass acts on it)
env_new ping-accepted
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 $HA green accepted | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual: changes .github/ (.github/workflows/ci.yml)"
dispatch --once
ok "an accept the user already gave (PR labelled accepted): no ping" eq "$(grep -c '^issue comment 5 -R example-org/web --body @octo PR #50 waits' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/pings/5"; echo $?)" "0 1"

env_new ping-plan-ok
{ issue 5 in-progress,needs-you,plan-ok; } | issues
state 5 phase=needs-you "ny_at=$NOW" "reason=plan ready for OK" ny_kind=plan
dispatch --once
ok "a plan the user already labelled plan-ok: no ping" eq "$(grep -c '^issue comment 5 -R example-org/web --body @octo the plan' "$FAKE/gh.log") $(test -e "$CANCCU_HOME/pings/5"; echo $?)" "0 1"

# finding 3: PING=off drops the records, so the state seen again once pings are back on pings again
env_new ping-off-records PING_KINDS=all
{ issue 8 needs-you; } | issues
dispatch --once
ok "pinged and recorded" eq "$(cat "$CANCCU_HOME/pings/8" 2>/dev/null)" needs-you
echo PING=off >> "$CANCCU_HOME/config"
dispatch --once
ok "PING=off: the records go" test ! -e "$CANCCU_HOME/pings"
sed -i '/^PING=off$/d' "$CANCCU_HOME/config"
dispatch --once
ok "… pings back on: the state that came back meanwhile is pinged again" eq "$(grep -c '^issue comment 8 ' "$FAKE/gh.log")" 2

# finding 4: a post that timed out may have landed: recorded, not posted again
env_new ping-timeout PING_KINDS=all
{ issue 8 needs-you; } | issues
echo 'fail124:issue comment' >> "$FAKE/routes"
dispatch --once
ok "a timed-out ping: recorded (it may have landed)" eq "$(cat "$CANCCU_HOME/pings/8" 2>/dev/null)" needs-you
ok "… logged as a time-out" grep -q '#8 ping as review-bot timed out; it may have landed' "$CANCCU_HOME/dispatch.log"
sed -i '/^fail124:issue comment$/d' "$FAKE/routes"
dispatch --once
ok "… not posted again on the next pass" eq "$(grep -c '^issue comment 8 ' "$FAKE/gh.log")" 1

# finding 5: a managed unit in phase needs-you whose label did not land is pinged too (once)
env_new ping-ny-unlabelled PING_KINDS=all
{ issue 5 in-progress; issue 6 in-progress,needs-you; } | issues
state 5 phase=needs-you "ny_at=$NOW" "reason=x" ny_kind=question
state 6 phase=needs-you "ny_at=$NOW" "reason=y"
dispatch --once
ok "phase needs-you without the label → its ping" has gh.log 'issue comment 5 -R example-org/web --body @octo the worker'"'"'s question here'
ok "… labelled and in phase needs-you: one ping, not two" eq "$(grep -c '^issue comment 6 ' "$FAKE/gh.log")" 1
ok "… recorded" eq "$(cat "$CANCCU_HOME/pings/5" 2>/dev/null)" question

# finding 6: a list of states that stopped half-way drops no record
env_new ping-half-list PING_KINDS=all
mkdir -p "$CANCCU_HOME/pings"; echo needs-you > "$CANCCU_HOME/pings/8"; echo accept > "$CANCCU_HOME/pings/9"
lib eval 'ping_states() { echo "8 needs-you -"; return 1; }; ping_tick' >/dev/null
ok "a list without its END line: no record dropped" eq "$(ls "$CANCCU_HOME/pings" | tr '\n' ' ')" "8 9 "
ok "… logged" grep -q 'ping: the list of what needs you stopped half-way' "$CANCCU_HOME/dispatch.log"
lib eval 'ping_states() { echo "8 needs-you -"; echo END; }; ping_tick'
ok "… a full list drops the cleared one" eq "$(ls "$CANCCU_HOME/pings" | tr '\n' ' ')" "8 "

# ---------------------------------------------------------------- ping only the product owner's kinds

# the suite's rules (tests/fixtures/rules/web): an accept and a plan ping; a question, a needs-you and a
# PR's needs-you are the lead's: no ping, but they stay in needs-you, the status and the monitor
env_new ping-kinds
ok "PING_KINDS: every kind by default" eq "$( . "$root/lib/canccu-config.default"; echo "$PING_KINDS")" all
ok "… the default rules template leaves it commented out" grep -qx '# PING_KINDS=all' "$root/profiles/default/rules"
ok "… the test project's rules: accept, checkpoint and plan" grep -qx "PING_KINDS='accept checkpoint plan'" "$root/tests/fixtures/rules/web"

{ issue 5 in-progress,awaiting-accept; issue 6 in-progress,needs-you; issue 7 in-progress,needs-you; issue 8 needs-you
  issue 9 in-progress; } | issues
{ pr 50 5 $HA green; pr 90 9 $HB green needs-you; } | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual: changes .github/"
state 6 phase=needs-you "ny_at=$NOW" "reason=plan ready for OK" ny_kind=plan
state 7 phase=needs-you "ny_at=$NOW" "reason=the worker's question needs the product owner" ny_kind=question
state 9 phase=check pr=90 "check_at=$NOW"
route 'pr view 90 *' FAIL
dispatch --once
ok "PING_KINDS (canccu): the accept and the plan are pinged" \
  eq "$(pings '^issue comment 5 -R example-org/web --body @octo PR #50 waits') $(pings '^issue comment 6 -R example-org/web --body @octo the plan here')" "1 1"
ok "… a question, a needs-you and a PR's needs-you are not" eq "$(pings '^(issue|pr) comment (7|8|9|90) ')" 0
ok "… and nothing is recorded for them" eq "$(ls "$CANCCU_HOME/pings" | tr '\n' ' ')" "5 6 "
ok "… they stay in the snapshot's needs-you (the monitor reads it)" \
  eq "$(jq -c '[.needs_you[] | select(.issue == 7 or .issue == 8) | .kind]' "$CANCCU_HOME/status.json")" '["question","needs-you"]'
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "… and in canccu-status" eq "$(grep -cE '^  #(7 · the worker|8 · Issue 8 \(labelled needs-you\))' "$E/status")" 2
echo PING_KINDS=all >> "$CANCCU_HOME/config"
dispatch --once
ok "PING_KINDS=all: the same states ping on the next pass, once each" eq "$(pings '^issue comment (7|8|9) ')" 3
ok "… the accept and the plan not again" eq "$(pings '^issue comment (5|6) ')" 2
sed -i '/^PING_KINDS=all$/d' "$CANCCU_HOME/config"
dispatch --once
ok "back to the test project's kinds: the records of the others go (they ping again once their kind is back)" \
  eq "$(ls "$CANCCU_HOME/pings" | tr '\n' ' ')" "5 6 "

# a kind left out does not hide another one of the same issue: the first listed kind still pings
env_new ping-kinds-second PING_KINDS=accept
{ issue 5 in-progress,awaiting-accept,needs-you; } | issues
pr 50 5 $HA green | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual"
dispatch --once
ok "PING_KINDS=accept: an issue labelled needs-you that waits for its accept → the accept ping" \
  eq "$(pings '^issue comment 5 -R example-org/web --body @octo PR #50 waits') $(pings '^issue comment 5 ') $(cat "$CANCCU_HOME/pings/5")" "1 1 accept"

env_new ping-kinds-typo "PING_KINDS='accept questoin'"
{ issue 5 in-progress,awaiting-accept; issue 6 in-progress,needs-you; } | issues
pr 50 5 $HA green | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual"
state 6 phase=needs-you "ny_at=$NOW" "reason=q" ny_kind=question
dispatch --once; dispatch --once
ok "PING_KINDS with an unknown word: logged once, naming it" eq "$(grep -c "PING_KINDS: unknown kind 'questoin'" "$CANCCU_HOME/dispatch.log")" 1
ok "… the known words still ping, the unknown one pings nothing" eq "$(pings '^issue comment 5 ') $(pings '^issue comment 6 ')" "1 0"

# review of #76: a glob in PING_KINDS is a word, never the file names it matches
env_new ping-kinds-glob "PING_KINDS='accept *'"
touch "$E/code/web/SOME-FILE"
( cd "$E/code/web" && PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1 )
ok "PING_KINDS with a glob: logged as the word, not the files it matches" \
  eq "$(grep -c "PING_KINDS: unknown kind '\*'" "$CANCCU_HOME/dispatch.log") $(grep -c SOME-FILE "$CANCCU_HOME/dispatch.log")" "1 0"

env_new ping-kinds-none "PING_KINDS=''"
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 $HA green | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual"
dispatch --once
ok "PING_KINDS empty: no ping, nothing recorded" eq "$(pings '^(issue|pr) comment') $(ls "$CANCCU_HOME/pings" 2>/dev/null | wc -l)" "0 0"

echo "canccu-pings tests: $npass passed, $nfail failed"
(( nfail == 0 ))
