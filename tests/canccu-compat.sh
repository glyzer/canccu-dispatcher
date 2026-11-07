#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-compat.sh — an existing install keeps working: a ~/.canccu laid out like one (two
# projects, a unit with a live run lock, a unit waiting for an accept, a step with a plan) gives
# the expected canccu-status and canccu-dispatch --dry-run output, and no file in it changes.
# The expected output is in tests/fixtures/compat/; --write-expected rewrites it from this run.
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

tname=compat
E=$T/compat; H=$E/home; C=$H/.canccu; W=$C/projects/web; FAKE=$E/fake
export FAKE CANCCU_NOW=$NOW
unset CANCCU_ROOT CANCCU_PROJECT CANCCU_HOME WORKERS_DIR
mkdir -p "$FAKE" "$H/code/web" "$H/code/tools" "$W/state" "$W/steps" "$W/workers" "$W/reviews" "$W/digest" \
  "$C/projects/tools/state" "$C/projects/tools/workers"

# ---------------------------------------------------------------- the install

printf '# TOTAL_CAP=3\nTOTAL_CAP=4\n' > "$C/config"
echo web > "$C/default-project"
printf '%s\n' "$FAKE_TOKEN" > "$C/reviewer-token"; chmod 600 "$C/reviewer-token"
# as canccu-init wrote them, then edited by hand
printf 'REPO=example-org/web\nCLONE=$HOME/code/web\nDIGEST_ISSUE=\nUSER_LOGIN=octo\nREVIEWER_LOGIN=review-bot\nCAP=2\n' > "$W/config"
cp "$root/tests/fixtures/rules/web" "$W/rules"
printf 'REPO=example-user/tools\nCLONE=$HOME/code/tools\nDIGEST_ISSUE=\nUSER_LOGIN=octo\nREVIEWER_LOGIN=review-bot\n' > "$C/projects/tools/config"
sed 's/@NAME@/tools/g' "$root/profiles/default/rules" > "$C/projects/tools/rules"
# unit 5: a worker that runs (its lock is live: this test's own pid)
printf 'phase=work\nstarted=%s\ncolor=0\nexclusive=0\n' "$((NOW - 1500))" > "$W/state/5"
printf 'repo=web\nkey=5\nkind=worker\npid=%s\nwindow=\nsession=canccu\nwname=#5\nword=5 You are working on example-org/web issue #5\nstarted=%s\nexclusive=0\nisolated=1\n' \
  "$$" "$((NOW - 1500))" > "$W/workers/web-5.lock"
printf '\n=== 2030-11-05 11:35:00 web#5 "5 You are working" session-id x · budget 250t/$80/150m\n[t1] Reading the issue\n[t7] → Bash tests/run search\n' > "$W/workers/web-5.log"
# unit 7: its PR waits for the user's accept
printf 'phase=accept\npr=70\naccept_sha=%s\naccept_at=%s\nreason=manual: changes setup/ (setup/x.sh)\ncolor=1\nexclusive=0\n' \
  "$HA" "$((NOW - 7200))" > "$W/state/7"
# step 12: its wave-1 plan, one package not started yet
cat > "$W/steps/12.plan-1.json" <<'P'
{"schema":1,"step":12,"wave":1,"packages":[
 {"name":"search-box","issues":[101,102],"risk":"normal","risk_reason":"a new page","areas":["src/search/"],"depends_on":[]}]}
P
printf 'phase=running\nwave=1\nplan=%s\nplan_at=%s\nstarted_at=%s\ntitle=1 Search\nepic=100\n' \
  "$W/steps/12.plan-1.json" "$((NOW - 600))" "$((NOW - 3600))" > "$W/steps/12"
printf 'plan-12\n' > "$W/steps/12.keys"
printf '%s\tweb\tplan-12\t2.00\n%s\tweb\t5\t?\n' "$((NOW - 3000))" "$((NOW - 2000))" > "$W/workers/spend.log"
printf '2030-11-05 11:35:00 #5 started: Add a search box\n' > "$W/dispatch.log"

# ---------------------------------------------------------------- GitHub, as the fake gh answers

jq -n '[{number: 12, title: "1 Search", open_issues: 4, closed_issues: 0, due_on: null}]' > "$FAKE/ms.json"
echo '[]' > "$FAKE/empty.json"; echo '[]' > "$FAKE/runs.json"
{ issue 5 in-progress; issue 7 in-progress; issue 3 ready; issue 4 ready "Blocked by #3"
  issue 100 epic "" "1 Search"; issue 101 ready "" "1 Search"; issue 102 ready "" "1 Search"; } | jq -s . > "$FAKE/issues-web.json"
{ issue 21 ready; } | jq -s . > "$FAKE/issues-tools.json"
p=$(PR_AUTHOR=octo pr 70 7 "$HA" green); printf '%s\n' "$p" | jq -s . > "$FAKE/prs-web.json"
detail "$p" 2030-11-05T09:00:00Z > "$FAKE/pr70.json"
echo '[{"filename": "setup/x.sh"}]' > "$FAKE/files70.json"
echo '{"labels": [{"name": "in-progress"}], "comments": []}' > "$FAKE/issue7.json"
echo '[]' > "$FAKE/prs-tools.json"
jq -n '["ready","blocked","in-progress","epic","needs-you","plan-ok","awaiting-accept","needs-work","accepted","manual-accept","checkpoint","checkpoint-ok","fast"] | map({name: .})' > "$FAKE/labels.json"
jq -n --arg l "$BOT" '{login: $l}' > "$FAKE/user.json"
printf '%s\t%s\n' 'pr view 70 *' pr70.json 'issue view 7 *' issue7.json 'api --paginate repos/example-org/web/pulls/70/files*' files70.json 'issue list -R example-org/web -s open*' issues-web.json 'issue list -R example-user/tools -s open*' issues-tools.json \
  'issue list*' empty.json 'pr list -R example-org/web -s open*' prs-web.json 'pr list -R example-user/tools -s open*' prs-tools.json \
  'api repos/example-org/web/milestones*' ms.json 'api repos/*/milestones*' empty.json 'api repos/*/dependencies/*' empty.json \
  'label list*' labels.json 'run list*' runs.json 'api user*' user.json > "$FAKE/routes.default"
: > "$FAKE/routes"; : > "$FAKE/gh.log"; : > "$FAKE/worker.log"

# ---------------------------------------------------------------- the run

snapshot() { (cd "$C" && find . -printf '%p %m %s %T@\n' | sort && find . -type f -exec md5sum {} + | sort); }
before=$(snapshot)
# what the tools print, with this run's temp dir and clock taken out
norm() { sed -e "s|$H|<home>|g" -e "s|$T|<tmp>|g"; }
run() { TZ=UTC HOME=$H PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" COLUMNS=100 NO_COLOR=1 "$@" 2>&1 | norm; }
out_status=$(run "$root/bin/canccu-status")
out_tools=$(run "$root/bin/canccu-status" --project tools)
out_dry=$(run "$root/bin/canccu-dispatch" --dry-run)
X=$root/tests/fixtures/compat
if [ "${1:-}" = --write-expected ]; then
  mkdir -p "$X"
  printf '%s\n' "$out_status" > "$X/status-web.txt"; printf '%s\n' "$out_tools" > "$X/status-tools.txt"
  printf '%s\n' "$out_dry" > "$X/dry-run-web.txt"
fi
ok "canccu-status (the default project) as expected" eq "$out_status" "$(cat "$X/status-web.txt")"
ok "canccu-status --project tools as expected" eq "$out_tools" "$(cat "$X/status-tools.txt")"
ok "canccu-dispatch --dry-run as expected" eq "$out_dry" "$(cat "$X/dry-run-web.txt")"
ok "… which shows the running unit, the accept and the step's package" \
  eq "$(grep -c '^  #5 work ' <<<"$out_status") $(grep -c '^  #7 · PR #70 · manual' <<<"$out_status") $(grep -c 'package search-box (101, 102; normal risk): pending' <<<"$out_dry")" "1 1 1"
ok "no file in ~/.canccu changed" eq "$(snapshot)" "$before"
ok "nothing was written to GitHub or started" \
  eq "$(grep -cvE '^(issue (list|view)|pr (list|view)|api |label list|run list|auth token)' "$FAKE/gh.log") $(wc -l < "$FAKE/worker.log")" "0 0"

echo "canccu-compat tests: $npass passed, $nfail failed"
(( nfail == 0 ))
