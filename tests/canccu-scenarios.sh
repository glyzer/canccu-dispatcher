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

# the fake's .last layout is the real report()'s: the same printf format
fmt() { grep -oF "printf '%s#%s · \"%s\" · %s · %s · %s turns · \$%s · %dm%02ds\n\n%s\n'" "$1" | head -1; }
ok "the fake engine's .last format is canccu-worker's report() format" \
  eq "$(fmt "$root/tests/scenarios/fake-engine")" "$(fmt "$root/libexec/canccu-worker")"
ok "… and neither is empty" test -n "$(fmt "$root/libexec/canccu-worker")"

# ---------------------------------------------------------------- fake engine: a worker opens its PR

fe_env worker-pr; key=7
fe --quiet --name '#7' web "7 take the issue" turns=1 cost=1 min=1
ok "worker: the start returns 0" eq "$rc" 0
ok "worker: its .last reads as done to the dispatcher" eq "$(lastx 7)" "done|done"
ok "worker: the lock is gone once the run ended" not test -e "$WORKERS_DIR/web-7.lock"
ok "worker: a fresh session the first time" grep -qF ' · fresh · done · ' "$WORKERS_DIR/web-7.last"
ok "worker: its branch is pushed to origin" eval 'git -C "$E/origin.git" rev-parse -q --verify 7-scenario >/dev/null'
ok "worker: the body has the Testing: and Revert: lines the dispatcher asks for" eval 'grep -q "^pr create --head 7-scenario .*Testing: .*Revert: plain revert" "$FAKE/gh.log"'
ok "worker: the PR is opened with Closes #7" eval 'grep -E "^pr create --head 7-scenario .*Closes #7" "$FAKE/gh.log" >/dev/null'
ok "worker: engine.log names the run" eq "$(cat "$SCENARIO_DIR/engine.log")" "worker 1 7 pr"
fe --quiet --name '#7' web "7 resume" turns=1 cost=1 min=1
ok "worker: a later run resumes, round 2" eval 'grep -qF " · resume · done · " "$WORKERS_DIR/web-7.last" && grep -qx "worker 2 7 pr" "$SCENARIO_DIR/engine.log"'

fe_env worker-pkg; key=pkg-3-scenario
fe --quiet --key pkg-3-scenario --name 'pkg' web "work package \"scenario\": do all the issues of the package on one branch, pkg-3-scenario, created from origin/main" turns=1 cost=1 min=1
ok "worker: a package's branch is the one its prompt names" eval 'git -C "$E/origin.git" rev-parse -q --verify pkg-3-scenario >/dev/null'

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

fe_env worker-pr-denied; key=11
printf '%s\n' 'worker 1 pr-denied' > "$SCENARIO_DIR/script"
fe --quiet --name '#11' web "11 take" turns=1 cost=1 min=1
ok "pr-denied: done, the branch pushed, no PR opened" eval '[ "$(lastx 11)" = "done|done" ] && git -C "$E/origin.git" rev-parse -q --verify 11-scenario >/dev/null && ! grep -q "^pr create" "$FAKE/gh.log"'
ok "pr-denied: the denials name gh pr create with the body file, which holds Closes #11" \
  eval 'lib run_msg 11 | grep -qx "Bash gh pr create --head 11-scenario --title \"scenario: 11\" --body-file pr-body.md" && grep -qx "Closes #11" "$WORKERS_DIR/worktrees/web/issue-11/pr-body.md"'

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
ok "review: the dispatcher reads a pass from its file (the finding block and its count line)" \
  eq "$(lib file_verdict "$CANCCU_HOME/reviews/50/$sha.md" "$sha")" pass
printf '%s\n' 'fixcheck 1 changes' > "$SCENARIO_DIR/script"
fe --quiet --key review-50 --dir "$E/rv" --name 'fixcheck#50' --untrusted web "fix-check PR 50" turns=1 cost=1 min=1
ok "fix-check: its own role and round, the scripted verdict" eval \
  '[ "$(tail -1 "$SCENARIO_DIR/engine.log")" = "fixcheck 1 review-50 changes" ] && tail -1 "$CANCCU_HOME/reviews/50/$sha.md" | grep -qx "Review verdict: changes $sha"'
ok "… which the dispatcher reads as changes" eq "$(lib file_verdict "$CANCCU_HOME/reviews/50/$sha.md" "$sha")" changes

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

# ---------------------------------------------------------------- run: the dry run against the fake gh

# run_env <name>: a sandbox origin (a local bare repo with the tag scenario-base and a PR branch
# 5-scenario), the fake gh's answers for the preflight and the reset, and a stub dispatcher that
# adds $FAKE/engine.lines to the scenario's engine.log and, from its second pass, the end state
# of $FAKE/prs-next.json
run_env() {
  env_new "$1"; unset CANCCU_HOME WORKERS_DIR CANCCU_PROJECT
  git init -q --bare -b main "$E/sandbox.git"; git clone -q "$E/sandbox.git" "$E/seed" 2>/dev/null
  git -C "$E/seed" -c user.name=octo -c user.email=octo@users.noreply.github.com commit -q --allow-empty -m base
  git -C "$E/seed" tag scenario-base && git -C "$E/seed" push -q origin main scenario-base HEAD:refs/heads/5-scenario
  echo '{"permissions": {"push": true}}' > "$FAKE/repo.json"
  echo 5 > "$FAKE/new-issue"; echo '[{"title": "9 Scenario package", "number": 9}]' > "$FAKE/ms9.json"; : > "$FAKE/empty.txt"
  echo '{"data": {"repository": {"pullRequest": {"id": "PR_node", "isInMergeQueue": true}}}}' > "$FAKE/prnode"; : > "$FAKE/engine.lines"
  route 'pr list -R example-org/web -s open*' empty.txt; route 'issue list -R example-org/web -s open*' empty.txt
  route 'api repos/example-org/web/milestones*' ms9.json
  route 'api repos/example-org/web/git/ref/tags/scenario-base' repo.json; route 'api graphql*' prnode
  echo '[{"type": "merge_queue"}]' > "$FAKE/mq.json"; route 'api repos/example-org/web/rules/branches/main*' mq.json
  route 'pr list -R example-org/web -s all*' prs-all.json
  cat > "$E/stub" <<'STUB'
#!/usr/bin/env bash
[ -e "$FAKE/pr-branch" ] && git -C "$SCENARIO_DIR/../code/sandbox" push -q origin HEAD:refs/heads/5-scenario 2>/dev/null   # the worker's PR branch, made in the run
cat "$FAKE/engine.lines" >> "$SCENARIO_DIR/engine.log"; echo "2030-11-05T12:00:00Z PR #50 posted as review-bot" >> "$CANCCU_HOME/dispatch.log"
n=$(cat "$FAKE/passes" 2>/dev/null); echo $(( ${n:-0} + 1 )) > "$FAKE/passes"
[ -n "$n" ] && [ -e "$FAKE/prs-next.json" ] && mv "$FAKE/prs-next.json" "$FAKE/prs-all.json"
exit 0
STUB
  chmod +x "$E/stub"
}
# world_is <issues json> <prs json>: what the fake GitHub shows at the end
world_is() { printf '%s\n' "$1" > "$FAKE/issues.json"; printf '%s\n' "$2" > "$FAKE/prs-all.json"; }
srun() {
  PATH="$gb:$PATH" SCENARIO_CLONE_URL=$E/sandbox.git SCENARIO_DISPATCH=$E/stub SCENARIO_PASS_SEC=0 \
    SCENARIO_TIMEOUT_SEC=${tmo:-0} SCENARIO_RUN_SEC=0 "$RUN" "$@" > "$E/out" 2>&1; rc=$?
}
I_CLOSED='[{"number": 5, "state": "CLOSED", "labels": [], "comments": []}]'
I_NEEDS='[{"number": 5, "state": "OPEN", "labels": [{"name": "needs-you"}], "comments": [{"body": "the worker'"'"'s run was denied commands: Bash git push -u origin 5-scenario"}]}]'
pr_() {   # pr_ <number> <state> <branch> <body> [mergedAt] [commit headline]
  jq -cn --argjson n "$1" --arg s "$2" --arg b "$3" --arg d "$4" --arg m "${5:-}" --arg c "${6:-scenario}" \
    '{number: $n, state: $s, headRefName: $b, body: $d, isDraft: false, mergedAt: (if $m == "" then null else $m end), commits: [{messageHeadline: $c}]}'
}
MERGED="[$(pr_ 50 MERGED 5-scenario 'Closes #5' 2030-11-05T12:00:00Z)]"
OPEN="[$(pr_ 50 OPEN 5-scenario 'Closes #5')]"

run_env usage
srun; ok "run: no --repo is a usage error" eq "$rc" 2
srun --repo "$(git -C "$root" remote get-url origin | sed -E 's#^(https://[^/]+/|[^@]+@[^:]+:)##; s#\.git$##')"
ok "run: --repo naming this repo itself is refused" eq "$rc $(grep -c 'is this repo itself' "$E/out")" "2 1"
srun --repo example-org/web nonesuch; ok "run: an unknown scenario is a usage error" eq "$rc" 2
sed -i '/tags\/scenario-base/d' "$FAKE/routes"; route 'api repos/example-org/web/git/ref/tags/scenario-base' FAIL
srun --repo example-org/web single
ok "run: a sandbox without the tag scenario-base is refused" eq "$rc $(grep -c 'no tag scenario-base' "$E/out")" "2 1"

run_env single; world_is "$I_CLOSED" "$MERGED"; srun --repo example-org/web single
ok "single: its end state passes" eq "$rc $(cat "$E/out")" "0 single: pass"
ok "single: the reset closed the open PRs and issues, then moved main to the tag" eval \
  'grep -q "^pr list -R example-org/web -s open" "$FAKE/gh.log" && grep -q "^issue list -R example-org/web -s open -l scenario" "$FAKE/gh.log"'
ok "single: the reset deleted the stale branches (a package branch of an earlier run rejects the push)" \
  not git -C "$E/sandbox.git" rev-parse -q --verify refs/heads/5-scenario
ok "single: the issue it made is labelled scenario and ready" grep -qE '^issue create -R example-org/web --title scenario single: .* --label scenario --label ready' "$FAKE/gh.log"
ok "single: the reset closes the claims of earlier scenarios (each one is a host of its own)" \
  grep -q '^issue list -R example-org/web -s open -l dispatcher-claim' "$FAKE/gh.log"
ok "single: the preflight makes the label scenario (the sandbox may lack it)" grep -qx 'label create scenario -R example-org/web --force' "$FAKE/gh.log"
run_env single-keep; world_is "$I_CLOSED" "$MERGED"; srun --repo example-org/web --keep single
kept=$(sed -n 's/^kept //p' "$E/out")
ok "single: the temp project uses the suite's own gh login" grep -qx 'ALLOW_DEFAULT_GH_LOGIN=1' "$kept/single/root/projects/sandbox/config"
rm -rf "$kept"
ok "single: the PR list stays under GitHub's 500,000-node limit (40 PRs with their commits)" \
  grep -q '^pr list -R example-org/web -s all -L 40 --json .*commits' "$FAKE/gh.log"
run_env single-setup; echo 'fail:issue create' >> "$FAKE/routes"; srun --repo example-org/web single
ok "single: a failed setup names the failing command" eq "$rc $(grep -c '^single: FAIL setup: gh issue create -R example-org/web --title scenario single: one issue to merge .* failed (exit 1)' "$E/out")" "1 1"
run_env single-open;world_is '[{"number": 5, "state": "OPEN", "labels": [], "comments": []}]' "$MERGED"
srun --repo example-org/web single
ok "single: an issue left open fails, saying why" eq "$rc $(grep -c "single: FAIL timed out after 0 s: #5 is still open" "$E/out")" "1 1"
run_env single-ny; world_is "$I_NEEDS" "$OPEN"; srun --repo example-org/web single
ok "single: an unexpected needs-you ends it at once" eq "$rc $(grep -c 'single: FAIL needs-you' "$E/out")" "1 1"

run_env package; world_is "$I_CLOSED" "[$(pr_ 50 MERGED pkg-9-scenario $'Closes #5\nCloses #5\nCloses #5' 2030-11-05T12:00:00Z)]"
echo 'plan 1 plan-9 package' > "$FAKE/engine.lines"; srun --repo example-org/web package
ok "package: its end state passes" eq "$rc $(cat "$E/out")" "0 package: pass"

run_env contract; world_is "$I_CLOSED" "[$(pr_ 51 MERGED 5-scenario-contract 'Refs #5' 2030-11-05T12:00:00Z),$(pr_ 52 MERGED 5-scenario 'Closes #5' 2030-11-05T13:00:00Z)]"
srun --repo example-org/web contract-first
ok "contract-first: its end state passes" eq "$rc $(cat "$E/out")" "0 contract-first: pass"
world_is "$I_CLOSED" "[$(pr_ 51 MERGED 5-scenario-contract 'Refs #5' 2030-11-05T14:00:00Z),$(pr_ 52 MERGED 5-scenario 'Closes #5' 2030-11-05T13:00:00Z)]"
srun --repo example-org/web contract-first
ok "contract-first: the unit's PR merged first fails" eq "$rc $(grep -c 'merged before the contract PR' "$E/out")" "1 1"

run_env conflict; world_is "$I_CLOSED" "[$(pr_ 50 MERGED 5-scenario 'Closes #5' 2030-11-05T12:00:00Z "Merge remote-tracking branch 'origin/main' into 5-scenario")]"
srun --repo example-org/web conflict-waiting
ok "conflict-waiting: its end state passes" eq "$rc $(cat "$E/out")" "0 conflict-waiting: pass"
run_env conflict-tick
world_is '[{"number": 5, "state": "OPEN", "labels": [{"name": "awaiting-accept"}], "comments": []}]' "[$(pr_ 50 OPEN 5-scenario-long-name 'Closes #5')]"
printf '%s\n' "[$(pr_ 50 MERGED 5-scenario-long-name 'Closes #5' 2030-11-05T12:00:00Z 'Merge main')]" > "$FAKE/prs-next.json"
tmo=3 srun --repo example-org/web conflict-waiting
ok "conflict-waiting: main's commit touches the file of the PR's own branch" \
  eq "$(git -C "$E/sandbox.git" show main:scenario/5-scenario-long-name.txt 2>/dev/null)" "main's side"

run_env queue; world_is "$I_CLOSED" "$OPEN"; printf '%s\n' "$MERGED" > "$FAKE/prs-next.json"
tmo=3 srun --repo example-org/web queue-removal
ok "queue-removal: dropped once from the queue, then merged: passes" eq "$rc $(cat "$E/out")" "0 queue-removal: pass"
ok "queue-removal: the suite dequeued the PR through GraphQL" grep -q '^api graphql -f query=mutation { dequeuePullRequest(input: {id: "PR_node"})' "$FAKE/gh.log"

run_env queue-none; echo '[{"type": "required_status_checks"}]' > "$FAKE/mq.json"; srun --repo example-org/web queue-removal single
ok "queue-removal: no merge queue on main: skipped, not a failure; the next scenario runs" \
  eq "$rc $(head -1 "$E/out")" "1 queue-removal: SKIP no merge queue"
ok "… and no reset for it (the skip comes before its home)" not grep -q '^issue create .*dropped by the merge queue' "$FAKE/gh.log"
world_is "$I_CLOSED" "$MERGED"; srun --repo example-org/web queue-removal single
ok "… with the rest passing, the run exits 0" eq "$rc $(tr '\n' '|' < "$E/out")" "0 queue-removal: SKIP no merge queue|single: pass|"

run_env late; : > "$FAKE/pr-branch"; world_is "$I_CLOSED" "$OPEN"; printf '%s\n' "$MERGED" > "$FAKE/prs-next.json"
echo 'review 1 review-50 pass' > "$FAKE/engine.lines"
tmo=3 srun --repo example-org/web push-after-pass
ok "push-after-pass: no fix-check after the push fails" eq "$rc $(grep -c 'no fix-check after the push' "$E/out")" "1 1"
ok "push-after-pass: the suite pushed a commit to the PR's branch" eq "$(git -C "$E/sandbox.git" log -1 --format=%s 5-scenario)" "scenario: a push after the pass"
run_env late2; : > "$FAKE/pr-branch"; world_is "$I_CLOSED" "$OPEN"; printf '%s\n' "$MERGED" > "$FAKE/prs-next.json"
printf '%s\n' 'review 1 review-50 pass' 'fixcheck 1 review-50 pass' > "$FAKE/engine.lines"
tmo=3 srun --repo example-org/web push-after-pass
ok "push-after-pass: a fix-check, then the merge: passes" eq "$rc $(cat "$E/out")" "0 push-after-pass: pass"

run_env denied; world_is "$I_NEEDS" "[]"; srun --repo example-org/web denied-push
ok "denied-push: needs-you naming the push passes" eq "$rc $(cat "$E/out")" "0 denied-push: pass"

run_env denied-pr; world_is "$I_CLOSED" "[$(pr_ 50 MERGED 5-scenario $'Closes #5\n\nThe dispatcher opened this PR: the worker pushed `5-scenario` but did not open it.' 2030-11-05T12:00:00Z)]"
srun --repo example-org/web denied-pr
ok "denied-pr: the PR the dispatcher opened, merged: passes" eq "$rc $(cat "$E/out")" "0 denied-pr: pass"
run_env denied-pr-worker; world_is "$I_CLOSED" "$MERGED"; srun --repo example-org/web denied-pr
ok "denied-pr: a merged PR that does not say the dispatcher opened it fails" eq "$rc $(grep -c 'does not say the dispatcher opened it' "$E/out")" "1 1"

run_env crash; world_is "$I_NEEDS" "[]"; printf '%s\n' 'worker 1 5 crash' 'worker 2 5 crash' > "$FAKE/engine.lines"
srun --repo example-org/web crash
ok "crash: two runs, then needs-you: passes" eq "$rc $(head -1 "$E/out")" "0 crash: pass"
run_env crash1; world_is "$I_NEEDS" "[]"; echo 'worker 1 5 crash' > "$FAKE/engine.lines"
srun --repo example-org/web crash
ok "crash: needs-you without the retry fails" eq "$rc $(grep -c 'not one retry' "$E/out")" "1 1"

# ---------------------------------------------------------------- setup: the sandbox's standing setup

SETUP=$root/tests/scenarios/setup
run_env setup
echo '{"permissions": {"push": true, "admin": true}}' > "$FAKE/repo.json"; route 'api repos/example-org/web' repo.json
echo '[{"name": "ready"}]' > "$FAKE/labels.json"; route 'label list*' labels.json
echo '[]' > "$FAKE/rulesets.json"; route 'api repos/example-org/web/rulesets --jq*' rulesets.json
route 'api -X*' empty.txt; route 'variable set*' empty.txt
sup() { PATH="$gb:$PATH" SCENARIO_CLONE_URL=$E/sandbox.git "$SETUP" "$@" > "$E/out" 2>&1; rc=$?; }
base0=$(git -C "$E/sandbox.git" rev-parse scenario-base)
sup --repo example-org/web
ok "setup: exits 0" eq "$rc" 0
ok "… scenario-base moved to a commit on the old one with the snippets, the review gate and CI" eval \
  '[ "$(git -C "$E/sandbox.git" rev-parse scenario-base~1)" = "$base0" ] &&
   [ "$(git -C "$E/sandbox.git" ls-tree -r --name-only scenario-base | sort | tr "\n" " ")" = ".github/scripts/review-gate .github/workflows/ci.yml .github/workflows/review-gate.yml AGENTS.md CLAUDE.md " ] &&
   [ "$(git -C "$E/sandbox.git" show scenario-base:AGENTS.md)" = "$(cat "$root/templates/repo/AGENTS.snippet.md")" ]'
ok "… the missing labels created, scenario among them; one there is left" eval \
  'grep -qx "label create scenario -R example-org/web" "$FAKE/gh.log" && grep -qx "label create dispatcher-claim -R example-org/web" "$FAKE/gh.log" && ! grep -q "^label create ready " "$FAKE/gh.log"'
ok "… auto-merge allowed, REVIEWER_LOGIN set, the ruleset created" eval \
  'grep -qx "api -X PATCH repos/example-org/web -F allow_auto_merge=true" "$FAKE/gh.log" && grep -q "^variable set REVIEWER_LOGIN -R example-org/web --body " "$FAKE/gh.log" && grep -qx "api -X POST repos/example-org/web/rulesets --input -" "$FAKE/gh.log"'
base1=$(git -C "$E/sandbox.git" rev-parse scenario-base)
echo '[{"name": "scenario main", "id": 7}]' > "$FAKE/rulesets.json"
sup --repo example-org/web
ok "setup: run again, the tag stays where it is and the ruleset is set again, not made twice" eval \
  '[ "$rc $(git -C "$E/sandbox.git" rev-parse scenario-base)" = "0 $base1" ] && grep -qx "api -X PUT repos/example-org/web/rulesets/7 --input -" "$FAKE/gh.log" && grep -q "scenario-base: up to date" "$E/out"'
echo '{"permissions": {"push": true, "admin": false}}' > "$FAKE/repo.json"; sup --repo example-org/web
ok "setup: a login that is no admin of the sandbox is refused, exit 1" eq "$rc $(grep -c 'no admin' "$E/out")" "1 1"

ok "tests/run lints the scenario files" eq "$("$root/tests/run" --list 2>/dev/null | grep '^lint:' | grep -c 'tests/scenarios/fake-engine')" 1
ok "tests/run never runs the live suite" eq "$("$root/tests/run" --list 2>/dev/null | grep -v '^lint:' | grep -c 'tests/scenarios/')" 0

echo "canccu-scenarios tests: $npass passed, $nfail failed"
(( nfail == 0 ))
