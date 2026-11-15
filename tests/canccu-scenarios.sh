#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-scenarios.sh — the scenario suite's own parts, never against GitHub: the fake engine
# (its lock and .last as the dispatcher reads them, each scripted action on a real local git
# remote), and tests/scenarios/run's dry run against the harness's fake gh (the harness:
# tests/lib/harness.sh). The live suite itself runs by hand before a tag (docs/reference/scenarios.md).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
FE=$root/tests/scenarios/fake-engine RUN=$root/tests/scenarios/run
tname=scenarios
# only the fake gh goes on PATH: the fake engine's git must be the real one
gb=$T/ghbin; mkdir -p "$gb"; ln -s "$fb/gh" "$gb/gh"

# fe_env <name>: a project home whose clone has a real bare origin with one commit on main
fe_env() {
  env_new "$1"
  export SCENARIO_DIR=$E/scenario CODE_ROOT=$E/code SCENARIO_RUN_SEC=0
  mkdir -p "$SCENARIO_DIR"; rm -rf "$E/code/web"
  git init -q --bare -b main "$E/origin.git"
  git clone -q "$E/origin.git" "$E/code/web" 2>/dev/null
  git -C "$E/code/web" -c user.name=octo -c user.email=octo@users.noreply.github.com commit -q --allow-empty -m base
  git -C "$E/code/web" push -q origin main
  echo https://github.com/example-org/web/pull/50 > "$FAKE/prurl"; route 'pr create*' prurl; route 'pr list --head*' empty.txt
  : > "$FAKE/empty.txt"
}
# fe <args...>: the fake engine, then wait (bounded) until its run is over: its lock gone
fe() {
  PATH="$gb:$PATH" "$FE" "$@" > "$E/fe.out" 2>&1; rc=$?
  local k=$key; for _ in $(seq 100); do [ -e "$WORKERS_DIR/web-$k.lock" ] || break; sleep 0.1; done
}
lastx() { lib run_exit "$WORKERS_DIR/web-$1.last"; }

# ---------------------------------------------------------------- fake engine: a worker opens its PR

fe_env worker-pr; key=7
fe --quiet --name '#7' web "7 take the issue" turns=1 cost=1 min=1
ok "worker: the start returns 0" eq "$rc" 0
ok "worker: its .last reads as done to the dispatcher" eq "$(lastx 7)" "done|done"
ok "worker: the lock is gone once the run ended" not test -e "$WORKERS_DIR/web-7.lock"
ok "worker: a fresh session the first time" grep -qF ' · fresh · done · ' "$WORKERS_DIR/web-7.last"
ok "worker: its branch is pushed to origin" eval 'git -C "$E/origin.git" rev-parse -q --verify 7-scenario >/dev/null'
ok "worker: the PR is opened with Closes #7" eval 'grep -E "^pr create --head 7-scenario .*Closes #7" "$FAKE/gh.log" >/dev/null'
ok "worker: engine.log names the run" eq "$(cat "$SCENARIO_DIR/engine.log")" "worker 1 7 pr"
fe --quiet --name '#7' web "7 resume" turns=1 cost=1 min=1
ok "worker: a later run resumes, round 2" eval 'grep -qF " · resume · done · " "$WORKERS_DIR/web-7.last" && grep -qx "worker 2 7 pr" "$SCENARIO_DIR/engine.log"'

# ---------------------------------------------------------------- fake engine: the scripted failures

fe_env worker-crash; key=8
printf '%s\n' 'worker 1 crash' > "$SCENARIO_DIR/script"
fe --quiet --name '#8' web "8 take" turns=1 cost=1 min=1
ok "crash: the dispatcher reads crashed" eq "$(lastx 8)" "crashed|crashed (exit 1)"

fe_env worker-denied; key=9
printf '%s\n' 'worker 1 push-denied' > "$SCENARIO_DIR/script"
fe --quiet --name '#9' web "9 take" turns=1 cost=1 min=1
ok "push-denied: done, nothing pushed" eval '[ "$(lastx 9)" = "done|done" ] && ! git -C "$E/origin.git" rev-parse -q --verify 9-scenario >/dev/null'
ok "push-denied: the denials block denied_ok reads names the push" \
  eq "$(lib run_msg 9 | sed -n '/^Permission denials (information):$/,$p' | tail -n +2)" "Bash git push -u origin 9-scenario"

fe_env worker-contract; key=10
printf '%s\n' 'worker 1 contract' > "$SCENARIO_DIR/script"
fe --quiet --name '#10' web "10 take" turns=1 cost=1 min=1
ok "contract: the contract PR with Refs, then the unit's as a draft" eq \
  "$(grep -oE '^pr create --head [^ ]+|Refs #10|Closes #10|--draft$' "$FAKE/gh.log" | tr '\n' '|')" \
  "pr create --head 10-scenario-contract|Refs #10|pr create --head 10-scenario|Closes #10|--draft|"

# ---------------------------------------------------------------- fake engine: reviewer, fix-check, planner

fe_env review; key=review-50
git -C "$E/code/web" worktree add -q --detach "$E/rv" HEAD
sha=$(git -C "$E/rv" rev-parse HEAD)
fe --quiet --key review-50 --dir "$E/rv" --name 'review#50' --untrusted web "review PR 50" turns=1 cost=1 min=1
ok "review: the verdict for the head is the file's last line" \
  eq "$(tail -1 "$CANCCU_HOME/reviews/50/$sha.md" 2>/dev/null)" "Review verdict: pass $sha"
printf '%s\n' 'fixcheck 1 changes' > "$SCENARIO_DIR/script"
fe --quiet --key review-50 --dir "$E/rv" --name 'fixcheck#50' --untrusted web "fix-check PR 50" turns=1 cost=1 min=1
ok "fix-check: its own role and round, the scripted verdict" eval \
  '[ "$(tail -1 "$SCENARIO_DIR/engine.log")" = "fixcheck 1 review-50 changes" ] && tail -1 "$CANCCU_HOME/reviews/50/$sha.md" | grep -qx "Review verdict: changes $sha"'

fe_env plan; key=plan-12
fe --quiet --key plan-12 --name 'plan#12' --untrusted web "Plan wave 2 of step 12. The issues to plan are exactly: 101, 103, 104." turns=1 cost=1 min=1
ok "plan: one package of the named issues, a plan lib/canccu-plan.jq accepts" eq \
  "$(lib run_msg plan-12 | jq -c '[.step, .wave, .packages[0].issues]')" "[12,2,[101,103,104]]"

# ---------------------------------------------------------------- fake engine: --kill and --unlock

fe_env kill; key=11
SCENARIO_RUN_SEC=30 PATH="$gb:$PATH" "$FE" --quiet --name '#11' web "11 take" turns=1 cost=1 min=1 >/dev/null 2>&1
ok "kill: the run's lock is alive while it runs" eval 'lib lock_alive "$WORKERS_DIR/web-11.lock"'
"$FE" --kill web 11
ok "kill: the run is gone, its lock too" not test -e "$WORKERS_DIR/web-11.lock"
printf 'pid=999999999\n' > "$WORKERS_DIR/web-12.lock"; "$FE" --unlock web 12
ok "unlock: a stale lock goes" not test -e "$WORKERS_DIR/web-12.lock"

# @RUN-TESTS@

echo "canccu-scenarios tests: $npass passed, $nfail failed"
(( nfail == 0 ))
