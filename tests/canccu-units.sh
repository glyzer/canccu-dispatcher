#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-units.sh — offline tests for units and work packages: unit keys, package runs,
# risk-based classify, the fast lane and the old per-issue state. Harness: tests/lib/harness.sh.
#   bash tests/canccu-units.sh    one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# pkgstate <K> <members> [key=value...]: a package's state file
pkgstate() {
  local k=$1 mem=$2 m=${1#pkg-}; m=${m%%-*}; shift 2
  state "$k" "pkg=${k#pkg-"$m"-}" "step=$m" "members=$mem" "branch=$k" risk=normal "$@"
}
# ppr <n> <closes "a b"> <head> <branch> [ci] [body]: a package PR
ppr() {
  PR_BRANCH=$4 pr "$1" 0 "$3" "${5:-green}" "" false "${6:-}" |
    jq --arg c "$2" '.closingIssuesReferences = ($c | split(" ") | map(select(. != "") | {number: tonumber}))'
}

lf() { lib eval "fetch; $*"; }   # a lib call after the pass's read of issues and PRs

# ---------------------------------------------------------------- unit keys (task 2)

env_new units-keys
{ issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"; issue 5 ready; } | issues
pkgstate pkg-12-auth "101 103"
ok "units: lead and members of an issue are the issue" eq "$(lib lead_of 7) $(lib members_of 7)" "7 7"
ok "units: a package's lead is its first open member" eq "$(lf lead_of pkg-12-auth)" 101
{ issue 103 in-progress "" "3 Events"; } | issues
ok "… the first one still open" eq "$(lf lead_of pkg-12-auth)" 103
ok "units: an issue resolves to its package" eq "$(lib unit_of_issue 103) $(lib unit_of_issue 5)" "pkg-12-auth 5"
ok "units: a package is open while a member is" lf unit_open pkg-12-auth
echo '[]' > "$FAKE/issues.json"
ok "… and closed when none is" not lf unit_open pkg-12-auth
ok "units: the budget scales with the issue count" eq "$(BUDGET_PACKAGE_MAX='600 200 360' lib pkg_budget '250 80 150' 2)" "500 160 300"
ok "… capped per part" eq "$(lib pkg_budget '250 80 150' 3)" "600 200 360"
ok "units: the window of a package" eq "$(lib unit_window pkg-12-auth) $(lib unit_window 5)" "pkg#auth #5"
ok "units: the branch names the package" eq "$(lib unit_of_branch pkg-12-auth)" pkg-12-auth
j=$(ppr 50 "101 103" "$HA" pkg-12-other)
ok "units: a package PR on another branch is foreign" grep -q 'is not pkg-12-auth' <<<"$(lib pr_foreign "$j" pkg-12-auth)"
j=$(ppr 50 "101 103" "$HA" pkg-12-auth)
ok "… on its branch it is ours" eq "$(lib pr_foreign "$j" pkg-12-auth)" ""
ok "units: two package keys are both managed (no numeric de-dup)" eq "$(pkgstate pkg-12-zz 5; lib managed | tr '\n' ' ')" "pkg-12-auth pkg-12-zz "

# the engine keeps a package's session (--keep-session); without it a word key starts fresh
env_new units-engine
mkdir -p "$E/wt"
ek() {   # ek <key> <keep 0|1>: one inner run of the engine
  printf 'repo=web\nkey=%s\nkind=worker\npid=\nwindow=\n' "$1" > "$WORKERS_DIR/web-$1.lock"
  PATH="$fb:$PATH" CODE_ROOT="$E/code" "$root/libexec/canccu-worker" __run web "$1" 5 1 2 "" "a prompt" "$E/wt" "" "$2" > /dev/null 2>&1
}
ek pkg-12-auth 1; ek pkg-12-auth 1
ok "engine: --keep-session resumes the package's session" grep -q -- '--resume ' <<<"$(tail -1 "$FAKE/claude.args")"
ek review-9 0; ek review-9 0
ok "engine: without it a word key starts a fresh session" not grep -q -- '--resume ' <<<"$(tail -1 "$FAKE/claude.args")"

# a package worker starts in the worktree the dispatcher made, with its key and --keep-session
env_new units-start
{ issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
pkgstate pkg-12-auth "101 103"
lib run_worker pkg-12-auth "do it" "10 1 5"
ok "units: run_worker of a package passes its key, worktree and --keep-session" \
  grep -qF -- "--name pkg#auth --key pkg-12-auth --dir $WORKERS_DIR/worktrees/web/pkg-12-auth --keep-session web pkg-12-auth do it" "$FAKE/worker.log"
ok "… phase work" eq "$(st pkg-12-auth phase)" work

# ---------------------------------------------------------------- package PRs: ours, classify, review (task 6)

# pkgpr <name> <closes> [body] [review comment json]: package pkg-12-auth (101 103), PR 50 on its branch
pkgpr() {
  env_new "$1"
  { issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"; } | issues
  pkgstate pkg-12-auth "101 103" risk=normal "risk_reason=a form" phase=review pr=50 "review_sha=$HA"
  p=$(ppr 50 "$2" "$HA" pkg-12-auth green "${3:-}"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z ${4:+"$4"})"; route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json i101.json '{"labels": [{"name": "in-progress"}]}'; route 'issue view 101 *' i101.json
  json i103.json '{"labels": [{"name": "in-progress"}]}'; route 'issue view 103 *' i103.json
}
pkgpr pkg-classify "101 103"
ok "packages: our PR closes exactly the members → classified as usual (auto)" eq "$(lf classify 50 pkg-12-auth)" auto
ok "… also found from its branch alone (canccu-classify)" eq "$(lf classify 50)" auto
ok "… it is ours" eq "$(lf not_ours 50)" ""
pkgpr pkg-classify-more "101 103 7"
ok "packages: one more issue → manual" eq "$(lf classify 50 pkg-12-auth)" "manual: PR #50 closes 7 101 103, not the package's 101 103"
pkgpr pkg-closed-member "101 103"
{ issue 103 in-progress "" "3 Events"; } | issues
ok "packages: a member closed by hand: the Closes set still matches" eq "$(lf classify 50 pkg-12-auth)" auto
ok "… and the package still runs (open)" lf unit_open pkg-12-auth
json i103.json '{"labels": [{"name": "manual-accept"}]}'
ok "packages: manual-accept on any member → manual" eq "$(lf classify 50 pkg-12-auth)" "manual: the issue has manual-accept"

pkgpr pkg-review "101 103"
out=$(lf review_prompt 50 pkg-12-auth "$HA" /tmp/f high)
ok "packages: the review prompt names the package and every linked issue" grep -qF "PR #50 (package auth: closes #101, #103)" <<<"$out"
ok "… reads each issue" grep -qF "gh issue view 101 -R example-org/web; gh issue view 103 -R example-org/web" <<<"$out"
ok "… checks every linked issue's criteria" grep -qF "Check every acceptance criterion of every linked issue" <<<"$out"
ok "… asks for the Risk line, never lower" grep -qF "write 'Risk: <low|normal|high> — <why>': confirm the class or raise it, never lower it" <<<"$out"
ok "… the verdict stays the last line" grep -qF "then a final line that is exactly 'Review verdict: pass $HA'" <<<"$out"
out=$(lf review_prompt 50 5 "$HA" /tmp/f high)
ok "packages: an issue's review prompt is unchanged" grep -qF "PR #50 (closes #5), head $HA, checked out in this worktree. You did not write it. Read the issue (gh issue view 5 -R example-org/web), AGENTS.md" <<<"$out"

# ---------------------------------------------------------------- risk-based classify (task 7)

c() { lib classify_pure "$@"; }
ok "risk: max" eq "$(lib risk_max low '' normal low) $(lib risk_max) $(lib risk_max high low)" "normal  high"
ok "risk: max skips an empty class without an error" eq "$( ( PATH="$fb:$PATH"; . "$root/lib/canccu-common.sh"; risk_max '' low '' ) 2>&1)" low
ok "risk: high → manual" eq "$(c src/a.ts "" "" "" example-org/web 0 "high (plan)")" "manual: risk high (plan)"
ok "risk: normal and low → auto" eq "$(c src/a.ts "" "" "" example-org/web 0 normal) $(c src/a.ts "" "" "" example-org/web 0 low)" "auto auto"
ok "risk: the freeze still makes a low-risk PR manual" grep -q '^manual: on or after AUTO_MERGE_UNTIL' <<<"$(CANCCU_NOW=$(date -d 2031-03-02 +%s) c src/a.ts "" "" "" example-org/web 0 low)"
ok "risk: a PR body's Risk: line" eq "$(lib pr_risk_of $'x\n**Risk:** HIGH — sessions\n')" high
pkgpr risk-pr "101 103" $'Package: auth\nRisk: high — touches sessions'
ok "risk: the PR's Risk: high wins over the plan's normal" eq "$(lf classify 50 pkg-12-auth)" "manual: risk high (PR)"
pkgpr risk-rev "101 103" "Risk: low — x" "$(vcomment 2030-11-05T11:00:00Z $'ok\nRisk: high — sessions\nReview verdict: pass '"$HA")"
ok "risk: the reviewer raises it to high → manual" eq "$(lf classify 50 pkg-12-auth)" "manual: risk high (reviewer)"
pkgpr risk-low "101 103" "" "$(vcomment 2030-11-05T11:00:00Z $'ok\nRisk: low — x\nReview verdict: pass '"$HA")"
sed -i 's/^risk=normal/risk=high/' "$CANCCU_HOME/state/pkg-12-auth"
ok "risk: a reviewer's lower class never lowers the plan's" eq "$(lf classify 50 pkg-12-auth)" "manual: risk high (plan)"
pkgpr risk-kept "101 103"; echo review_risk=high >> "$CANCCU_HOME/state/pkg-12-auth"
ok "risk: the full review's class still counts after the fix-check" eq "$(lf classify 50 pkg-12-auth)" "manual: risk high (reviewer)"
pkgpr risk-health "" ""
pkgstate pkg-12-health "" pkg=health health=1 phase=review pr=50 risk=normal
p=$(ppr 50 "" "$HA" pkg-12-health); printf '%s\n' "$p" | prs; json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"
ok "risk: the health pass is normal → auto" eq "$(lf classify 50 pkg-12-health)" auto
json files50.json '[{"filename": "db/migrations/0003.sql"}]'
ok "… high when it touches HIGH_RISK_PATHS" eq "$(lf classify 50 pkg-12-health)" "manual: risk high (paths)"

# ---------------------------------------------------------------- finishing a package (task 6)

pkgpr pkg-finish "101 103"
echo '[]' > "$FAKE/issues.json"; sed -i 's/^phase=.*/phase=merging/' "$CANCCU_HOME/state/pkg-12-auth"
json i101.json '{"state": "CLOSED", "labels": [{"name": "in-progress"}]}'
json i103.json '{"state": "CLOSED", "labels": [{"name": "in-progress"}, {"name": "needs-you"}]}'
jq '.state = "MERGED" | .body = "Follow-up: a later thing"' "$FAKE/pr50.json" > "$FAKE/m50" && mv "$FAKE/m50" "$FAKE/pr50.json"
mkdir -p "$CANCCU_HOME/steps" "$WORKERS_DIR/worktrees/web/pkg-12-auth/.git"; printf 'title=3 Events\n' > "$CANCCU_HOME/steps/12"
dispatch --once
ok "packages: all members closed and the PR merged → finished: the state goes" test ! -e "$CANCCU_HOME/state/pkg-12-auth"
ok "… in-progress off every member, needs-you too" \
  eq "$(grep -cE '^issue edit (101 -R example-org/web --remove-label in-progress|103 -R example-org/web --remove-label (in-progress|needs-you))' "$FAKE/gh.log")" 3
ok "… its worktree removed" grep -qF "worktree remove --force $WORKERS_DIR/worktrees/web/pkg-12-auth" "$FAKE/git.log"
ok "… one line in the step's packages" eq "$(cut -f1,2,4,6,7 "$CANCCU_HOME/steps/12.packages" | tr '\t' '|')" "pkg-12-auth|auth|101 103|50|merged"
ok "… its notes kept" grep -q 'a later thing' "$CANCCU_HOME/steps/12.notes"
ok "… merged.log names the package" grep -qP '\tpkg-12-auth\t50\t' "$CANCCU_HOME/merged.log"

# ---------------------------------------------------------------- a contract-first PR (#63)

# the repo's rule "a contract change is its own PR and merges first": the package's worker opens it
# on <branch>-contract with only Refs lines, beside the package's draft
cpr() {   # cpr <name>: package pkg-12-auth, its draft PR 50 and its contract PR 51
  env_new "$1"
  { issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"; } | issues
  pkgstate pkg-12-auth "101 103" "risk_reason=a form" phase=check pr=50 "check_at=$NOW"
  p=$(ppr 50 "101 103" "$HA" pkg-12-auth green "" | jq '.isDraft = true')
  c=$(ppr 51 "" "$HB" pkg-12-auth-contract green $'Refs #101\nPackage: auth\nRisk: normal — the contract')
  printf '%s\n' "$p" "$c" | prs
  json pr51.json "$(detail "$c" 2030-11-05T10:00:00Z)"; route 'pr view 51 *' pr51.json
  json files51.json '[{"filename": "contracts/a.yaml"}]'; route 'api --paginate repos/example-org/web/pulls/51/files*' files51.json
  json i101.json '{"labels": [{"name": "in-progress"}]}'; route 'issue view 101 *' i101.json
  json i103.json '{"labels": [{"name": "in-progress"}]}'; route 'issue view 103 *' i103.json
}
cpr contract-ours
ok "contract: a PR on the package's <branch>-contract is ours" eq "$(lib pr_foreign "$c" pkg-12-auth)" ""
ok "… its branch names the package" eq "$(lib unit_of_branch pkg-12-auth-contract)" pkg-12-auth
ok "… not another package's" eq "$(lib unit_of_branch pkg-12-auth-contract-x)" ""
ok "… it is the unit's PR while it is open (it merges first)" eq "$(lf pr_for pkg-12-auth)" 51
ok "… not listed as not ours" eq "$(lf not_ours 51)" ""
ok "… classified as usual though it closes no issue" eq "$(lf classify 51 pkg-12-auth)" auto
ok "… also from its branch alone" eq "$(lf classify 51)" auto
c=$(jq '.closingIssuesReferences = [{number: 101}]' <<<"$c"); json pr51.json "$(detail "$c" 2030-11-05T10:00:00Z)"
ok "… one that closes a member is no contract PR → manual" grep -q '^manual: PR #51 closes 101' <<<"$(lf classify 51 pkg-12-auth)"
cpr contract-review
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 51 > "$E/out" 2>&1
ok "contract: canccu-review accepts it" grep -q -- '--key review-51 ' "$FAKE/worker.log"
out=$(lf review_prompt 51 pkg-12-auth "$HB" /tmp/f high)
ok "contract: the review prompt checks only the contract's part of the criteria" grep -qF "This is the unit's contract-first PR: it closes no issue" <<<"$out"
ok "… the draft's prompt is unchanged" grep -qF "Check every acceptance criterion of every linked issue" <<<"$(lf review_prompt 50 pkg-12-auth "$HA" /tmp/f high)"
cpr contract-pass
dispatch --once
ok "contract: a pass reviews it, not the draft" eq "$(grep -c -- '--key review-51 ' "$FAKE/worker.log") $(st pkg-12-auth pr)" "1 51"
ok "… no needs-you for the draft" hasnt gh.log "needs-you"

cpr contract-merged
p=$(ppr 50 "101 103" "$HA" pkg-12-auth green "" | jq '.isDraft = true'); printf '%s\n' "$p" | prs
pkgstate pkg-12-auth "101 103" phase=merging pr=51 "merge_sha=$HB" how=auto "merge_at=$((NOW - 600))" stage=fixcheck "reviewed_sha=$HC"
json pr51.json '{"state": "MERGED", "body": "Refs #101", "closingIssuesReferences": [], "headRefName": "pkg-12-auth-contract"}'
echo sid > "$WORKERS_DIR/web-pkg-12-auth.id"
dispatch --once
ok "contract: once it merged → back to check on the draft, no needs-you" eq "$(st pkg-12-auth phase) $(st pkg-12-auth pr)" "check 50"
ok "… its review round is over" eq "$(st pkg-12-auth stage)|$(st pkg-12-auth reviewed_sha)|$(st pkg-12-auth merge_sha)" "||"
ok "… logged" grep -q 'pkg-12-auth PR #51: the contract PR merged; the package goes on in PR #50' "$CANCCU_HOME/dispatch.log"
dispatch --once
ok "… the next pass resumes the package's worker on its draft" grep -q -- '--key pkg-12-auth .*contract PR #51 merged' "$FAKE/worker.log"
ok "… once" eq "$(dispatch --once; grep -c -- '--key pkg-12-auth ' "$FAKE/worker.log")" 1

# ---------------------------------------------------------------- the fast lane and the old state (task 10)

env_new fast
{ issue 5 ready; issue 6 ready,fast "" "3 Events"; issue 7 ready "" "3 Events"; } | issues
dispatch --once
ok "fast lane: a ready issue with no milestone runs alone at once" started 5
ok "fast lane: a ready issue labelled fast in a step runs alone" started 6
ok "fast lane: a ready step issue without fast is not started alone" not started 7

env_new old-state
{ issue 7 in-progress "" "3 Events"; issue 8 ready "" "3 Events"; issue 90 epic "" "3 Events"; } | issues
jq -nc '{number: 12, title: "3 Events", open_issues: 2, closed_issues: 0}' | jq -s . > "$FAKE/ms.json"
json c90.json '{"comments": []}'; route 'issue view 90 *' c90.json
p=$(pr 70 7 "$HA"); printf '%s\n' "$p" | prs; json pr70.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 70 *' pr70.json
state 7 phase=check pr=70 stage=fixing "reviewed_sha=$HB" "check_at=$NOW"
dispatch --once
ok "old state: an in-progress per-issue unit (fixing) goes on under the per-issue flow (its fix-check)" grep -qF 'fix-check' "$E/out"
ok "… its issue is never in the planner's input" eq "$(pissues)" "#8"
env_new old-adopt
{ issue 7 in-progress "" "3 Events"; } | issues; pr 70 7 "$HA" | prs
dispatch --once
ok "old state: adopt still adopts an <n>-… PR of an in-progress issue in no package" eq "$(st 7 phase) $(st 7 pr)" "check 70"

env_new member-moved
{ issue 101 in-progress,fast; issue 103 in-progress "" "4 Later"; } | issues
pkgstate pkg-12-auth "101 103" phase=work; live_lock pkg-12-auth
{ issue 101 ready,fast; issue 103 ready "" "4 Later"; } | issues
dispatch --once
ok "members: relabelled fast or moved to another milestone mid-wave → never started alone" eq "$(grep -cE -- '--name #(101|103) ' "$FAKE/worker.log")" 0

env_new member-commands
{ issue 101 in-progress "" "3 Events"; issue 103 in-progress "" "3 Events"; } | issues
pkgstate pkg-12-auth "101 103" phase=needs-you pr=50
PR_BRANCH=pkg-12-auth pr 50 101 "$HA" | prs
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-run" 103 go on > "$E/out" 2>&1
ok "canccu-run <member> resumes the package, never a run of the issue alone" \
  eq "$(grep -c -- '--key pkg-12-auth' "$FAKE/worker.log") $(grep -c -- '--name #103' "$FAKE/worker.log")" "1 0"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-stop" 103 > "$E/out" 2>&1
ok "canccu-stop <member> stops the package" grep -q -- '--kill web pkg-12-auth' "$FAKE/worker.log"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 101 > "$E/out" 2>&1
ok "canccu-ship <member> ships the package's PR" grep -q "^pr merge 50 -R example-org/web --auto --match-head-commit $HA" "$FAKE/gh.log"

echo "canccu-units tests: $npass passed, $nfail failed"
(( nfail == 0 ))
