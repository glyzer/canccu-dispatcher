#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-share.sh — the fair share of TOTAL_CAP over the projects: a project alone may fill
# TOTAL_CAP; one with work waiting gets the next freed slot; spare slots go to the project with
# the fewest runs (the harness: tests/lib/harness.sh, its projects fixtures).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# plock <project> <key>: a live run of that project the dispatcher did not start (a run by hand)
plock() {
  printf 'repo=%s\nkey=%s\nkind=worker\npid=%s\nwindow=\nstarted=%s\n' "$1" "$2" "$$" "$NOW" \
    > "$CANCCU_ROOT/projects/$1/workers/$1-$2.lock"
}
nstarted() { grep -c -- "--name #[0-9]* $1 " "$FAKE/worker.log"; }
waits() { sed -n 's/^n=//p' "$CANCCU_ROOT/projects/$1/want" 2>/dev/null; }
status() { PATH="$fb:$PATH" "$root/bin/canccu-status" --project "$1" 2>&1; }
# share <name> <TOTAL_CAP> <project=CAP...>: projects with those CAPs; the first is the default
share() {
  local n=$1 tc=$2 p ps=(); shift 2
  for p; do ps+=("${p%%=*}"); done
  penv "$n" "${ps[@]}"
  echo "${ps[0]}" > "$CANCCU_ROOT/default-project"; echo "TOTAL_CAP=$tc" > "$CANCCU_ROOT/config"
  for p; do pconf "${p%%=*}" "CAP=${p#*=}"; done
}

# two projects, web idle: tools fills every slot of TOTAL_CAP
share alone 3 tools=4 web=3
projissues tools 1 2 3 4
dispatch --project web --once
dispatch --project tools --once
ok "web idle: tools takes every slot of TOTAL_CAP" eq "$(nstarted tools)" 3
ok "… web waits for nothing" eq "$(waits web)" 0
ok "… tools's fourth issue waits for a slot (its CAP is 4)" eq "$(waits tools)" 1

# work arrives for web: it waits; the next slot tools frees goes to web, not to tools's next run
projissues web 11
dispatch --project web --once
ok "work for web, every slot held by tools: web waits" eq "$(nstarted web) $(waits web)" "0 1"
ok "… canccu-status says who holds the slots" grep -q '^waiting for a slot held by tools$' <<<"$(status web)"
ok "… tools, the busy one, waits for no slot held by another" not grep -q 'waiting for a slot' <<<"$(status tools)"
rm "$CANCCU_ROOT/projects/tools/workers/tools-1.lock"   # tools's first run ends
: > "$FAKE/worker.log"
dispatch --project tools --once
ok "a slot freed in tools: tools does not start its next run while web waits" not pstarted tools 4
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-run" --project tools 4 2>&1); rc=$?
ok "… not by hand either: the engine yields the slot to web" \
  eq "$rc $(grep -c 'could not start worker #4: the free slot goes to web, which waits for one' <<<"$out")" "1 1"
dispatch --project web --once
ok "… web takes the freed slot" pstarted web 11
ok "… and waits no more" eq "$(waits web)" 0
ok "… canccu-status of web: no wait" not grep -q 'waiting for a slot' <<<"$(status web)"

# CAP stays the project's bound
share cap 3 tools=2 web=3
projissues tools 1 2 3
dispatch --project tools --once
ok "CAP 2 under TOTAL_CAP 3: tools starts 2" eq "$(nstarted tools)" 2
ok "… and waits for no shared slot (its own CAP holds it)" eq "$(waits tools)" 0

# a start that fails for another reason (the engine refuses) is no wait for a shared slot
share fail 3 tools=3 web=3
projissues tools 1 2; touch "$FAKE/refuse"
dispatch --project tools --once
ok "a start the worker refuses: tools waits for no slot" eq "$(waits tools)" 0

# three projects with work, three slots: one each
share three 3 tools=4 shop=4 web=4
projissues tools 1 2 3; projissues shop 11 12 13; projissues web 21 22 23
plock tools h1; plock tools h2; plock tools h3   # every slot held: each pass records its wait
for p in tools shop web; do dispatch --project "$p" --once; done
ok "every slot held: all three wait (the fast lane reads only its first issue then)" \
  eq "$(waits tools) $(waits shop) $(waits web)" "1 1 1"
ok "… canccu-status of web names the holder" grep -q '^waiting for a slot held by tools$' <<<"$(status web)"
rm "$CANCCU_ROOT"/projects/tools/workers/tools-h*.lock   # the three runs end
for p in tools shop web; do dispatch --project "$p" --once; done
ok "three projects with work, three slots: one each" eq "$(nstarted tools) $(nstarted shop) $(nstarted web)" "1 1 1"

# spare slots go to the project with the fewest runs first
share fewest 4 tools=4 shop=4 web=4
projissues tools 1 2 3; projissues shop 11 12; projissues web 21 22
plock tools h1; plock tools h2; plock shop h1; plock web h1
for p in tools shop web; do dispatch --project "$p" --once; done
rm "$CANCCU_ROOT/projects/shop/workers/shop-h1.lock" "$CANCCU_ROOT/projects/tools/workers/tools-h1.lock"   # two free
dispatch --project tools --once
ok "two free slots; tools, shop, web run 1, 0, 1: tools leaves one for shop and takes the other" eq "$(nstarted tools)" 1
dispatch --project web --once
ok "… web (1 run) yields the last slot to shop (0 runs)" eq "$(nstarted web)" 0
dispatch --project shop --once
ok "… shop takes it" eq "$(nstarted shop)" 1

# two dispatchers deciding at once never exceed TOTAL_CAP
share race 2 tools=3 web=3
projissues tools 1 2 3; projissues web 11 12 13
( PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --project tools --once > "$E/out-tools" 2>&1 ) &
( PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --project web --once > "$E/out-web" 2>&1 ) &
wait
ok "two dispatchers at once: TOTAL_CAP 2 holds" eq "$(cat "$CANCCU_ROOT"/projects/*/workers/*.lock | grep -c '^kind=worker')" 2

# a tie goes to the waiter: it gets the next freed slot also when the busy project's ending run
# leaves the two level (the busy one started last: it yields)
share tie 1 tools=3 web=3
projissues tools 1 2
dispatch --project tools --once
projissues web 11
dispatch --project web --once
rm "$CANCCU_ROOT/projects/tools/workers/tools-1.lock"; : > "$FAKE/worker.log"   # 0 runs each
dispatch --project tools --once
ok "TOTAL_CAP 1, tools's run ends while web waits: tools does not take the slot back" eq "$(nstarted tools)" 0
dispatch --project web --once
ok "… web gets it" pstarted web 11

share tie3 2 tools=3 shop=3 web=3
projissues tools 1 2; plock web h1
dispatch --project tools --once
projissues shop 11
dispatch --project shop --once
rm "$CANCCU_ROOT/projects/tools/workers/tools-1.lock"; : > "$FAKE/worker.log"   # runs 0, 0 (waiting), 1
dispatch --project tools --once
ok "TOTAL_CAP 2, runs tools 1, shop 0 (waiting), web 1; tools's run ends: tools yields" eq "$(nstarted tools)" 0
dispatch --project shop --once
ok "… shop gets the slot" pstarted shop 11

# the engine refuses a slot owed to a waiter with its own exit code, so the pass counts the wait
share engine 2 tools=3 web=3
plock tools h1
printf 'n=1\ncap=3\nuntil=%s\n' $((NOW + 600)) > "$CANCCU_ROOT/projects/web/want"
plib tools engine "worker #9" 9 --name '#9' tools "9 x" > /dev/null; rc=$?
ok "the engine refuses a slot owed to a waiter with exit 75" eq "$rc" 75
ok "… and starts nothing" not grep -q -- '--name #9 ' "$FAKE/worker.log"

# a unit held back by the project's own reservation is no wait for a shared slot
share own 3 tools=1 web=3
projissues tools 1 5; printf 'phase=question\n' > "$CANCCU_ROOT/projects/tools/state/5"; touch "$FAKE/refuse"
dispatch --project tools --once
ok "CAP 1 reserved for a question: tools's fast lane waits for no shared slot" eq "$(waits tools)" 0

# a pass that ends early (a gh error) clears the wait the pass before left
share early 1 tools=3 web=3
plock tools h1; projissues web 11
dispatch --project web --once
ok "every slot held by tools: web waits" eq "$(waits web)" 1
route "issue list -R $(prepo web) *" FAIL
dispatch --project web --once
ok "a gh error ends web's pass early: its old wait is cleared" eq "$(waits web)" 0

# a wait that is not renewed (its dispatcher stopped) ends: the busy project takes the slot again
share stale 2 tools=3 web=2
projissues tools 1 2; projissues web 11
plock tools h1; plock tools h2
dispatch --project web --once
rm "$CANCCU_ROOT/projects/tools/workers/tools-h1.lock"
dispatch --project tools --once
ok "web waits: tools yields the freed slot" eq "$(nstarted tools)" 0
CANCCU_NOW=$((NOW + 3600)) dispatch --project tools --once
ok "an hour later, web's wait not renewed: tools takes the slot" eq "$(nstarted tools)" 1

# a dry run writes no wait
share dry 1 tools=3 web=3
plock tools h1; projissues web 11
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --project web --dry-run > "$E/out" 2>&1
ok "a dry run writes no want file" test ! -e "$CANCCU_ROOT/projects/web/want"

# a reservation of the project's own that cannot start: the slot it took is no wait for a shared
# one, so the other project takes the spare slot instead of yielding it for ever
share own-refused 3 tools=4 web=3
projissues tools 1 2 3; projissues web 11 5
plock tools h1; plock tools h2
printf 'phase=question\n' > "$CANCCU_ROOT/projects/web/state/5"; touch "$FAKE/refuse-answer-5"
dispatch --project web --once
ok "web's own question took the free slot and cannot start: web waits for no shared slot" eq "$(waits web)" 0
dispatch --project tools --once
ok "… so tools takes the spare slot" eq "$(nstarted tools)" 1

# held5 <project>: its unit 5 is a question of step 12, which is at STEP_BUDGET (5 of 5 spent)
held5() {
  local d=$CANCCU_ROOT/projects/$1
  printf 'phase=question\nstep=12\n' > "$d/state/5"
  mkdir -p "$d/steps"; echo answer-5 > "$d/steps/12.keys"
  printf '%s\t%s\tanswer-5\t5.00\n' "$NOW" "$1" > "$d/workers/spend.log"
  pconf "$1" STEP_BUDGET=5
}
# a run its step's budget holds waits for no slot and reserves none
share held 2 tools=3 web=3
plock tools h1; plock tools h2; projissues web 5; held5 web
dispatch --project web --once
ok "every slot taken, web's question held by its step's budget: web waits for no slot" eq "$(waits web)" 0
share held-own 3 tools=3 web=1
projissues web 11 5; held5 web
dispatch --project web --once
ok "a question its step's budget holds reserves no slot: web's issue starts (CAP 1)" pstarted web 11

# a review that cannot start (no reviewer token) reserves no slot either
share no-reviewer 3 tools=3 web=1
{ issue 5 in-progress; issue 11 ready; } | jq -s . > "$FAKE/issues-web.json"
pr 50 5 "$HA" green | jq -s . > "$FAKE/prs-web.json"
printf 'phase=check\npr=50\n' > "$CANCCU_ROOT/projects/web/state/5"
rm "$E/reviewer-token"
dispatch --project web --once
ok "reviews refused: PR 50's review reserves no slot, web's issue starts (CAP 1)" pstarted web 11

# the engine's own refusal for want of a shared slot counts the unit as waiting, whoever started it
share engine-wait 2 tools=3 web=3
plock tools h1
printf 'n=1\ncap=3\nuntil=%s\n' $((NOW + 600)) > "$CANCCU_ROOT/projects/web/want"
ok "a start the engine refuses for the share is noted as waiting" \
  eq "$(plib tools eval 'engine "reviewer review#50" review-50 --name "review#50" tools "x" > /dev/null; echo "${!WANT_KEYS[@]}"' | tail -1)" review-50

# a pass that dies half-way leaves no wait behind
share dies 1 tools=3 web=3
plock tools h1; projissues web 11
dispatch --project web --once
ok "every slot held by tools: web waits" eq "$(waits web)" 1
CANCCU_TEST_PASS_DIES=1 dispatch --project web --once
ok "a pass that dies: web's old wait is cleared" eq "$(waits web)" 0

# canccu-status names only the projects that owe the waiter a slot: more runs, or as many and
# started last; not one with fewer runs
share names 6 tools=4 shop=4 web=4
plock tools h1; plock tools h2; plock tools h3; plock shop h1; plock web h1; plock web h2
printf 'n=1\ncap=4\nuntil=%s\n' $((NOW + 600)) > "$CANCCU_ROOT/projects/web/want"
ok "web (2 runs) waits: held by tools (3), not by shop (1)" grep -q '^waiting for a slot held by tools$' <<<"$(status web)"

# the usage throttle's slow mode (one run over all projects) still wins over the share
share slow 3 tools=3 web=3
jq -n --argjson at "$((NOW - 60))" --argjson r "$((NOW + 3600))" \
  '{at: $at, info: {status: "allowed", unifiedWindows: {five_hour: {utilization: 0.6, resetsAt: $r}, seven_day: {utilization: 0.1, resetsAt: ($r + 82800)}}}}' \
  > "$CANCCU_ROOT/projects/tools/workers/usage.json"
projissues tools 1 2; projissues web 11
dispatch --project web --once; dispatch --project tools --once; dispatch --project web --once
ok "slow mode: one run over both projects though both have work" eq "$(cat "$CANCCU_ROOT"/projects/*/workers/*.lock | grep -c '^kind=worker')" 1

echo "canccu-share tests: $npass passed, $nfail failed"
(( nfail == 0 ))
