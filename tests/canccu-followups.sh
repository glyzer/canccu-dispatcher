#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-followups.sh — offline tests for the review follow-ups of #222: the merge, the
# accept, the pings, the feed, the config, the plan and the commands (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# macc <name> [config...]: PR 50 of issue 5 waits for the accept of HA, accepted by octo since
macc() {
  env_new "$@"
  { issue 5 in-progress,awaiting-accept; } | issues
  pr 50 5 $HA green accepted | prs
  state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 3600))"
  jq -n '[{event: "labeled", label: {name: "accepted"}, actor: {login: "octo"}, created_at: "2030-11-05T11:30:00Z"}]' > "$FAKE/events50.json"
  route 'api --paginate repos/example-org/web/issues/50/events' events50.json
}
# flaky <times> <error> [exit status]: the first <times> `gh pr merge` calls fail with that error (0: every one)
flaky() {
  mkdir -p "$E/sbin"
  cat > "$E/sbin/gh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr merge" ]; then
  k=\$(( \$(cat "$E/merges" 2>/dev/null || echo 0) + 1 )); echo "\$k" > "$E/merges"
  if [ "$1" = 0 ] || [ "\$k" -le "$1" ]; then echo "$2" >&2; exit ${3:-1}; fi
fi
exec "$fb/gh" "\$@"
SH
  chmod +x "$E/sbin/gh"
}
fpass() { PATH="$E/sbin:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1; }
dlog() { grep -cF -- "$1" "$CANCCU_HOME/dispatch.log"; }
# issue_accept <name> <accept_sha> <head> [who labelled] [when]: PR 50 waits for the accept of
# issue 5, whose `accepted` label (none on the PR) has that label event
issue_accept() {
  env_new "$1"
  { issue 5 in-progress,awaiting-accept,accepted; } | issues
  pr 50 5 "$3" | prs
  state 5 phase=accept pr=50 "accept_sha=$2" rounds=0 "accept_at=$((NOW - 3600))"
  jq -n --arg u "${4:-octo}" --arg t "${5:-2030-11-05T11:30:00Z}" \
    '[{event: "labeled", label: {name: "accepted"}, actor: {login: $u}, created_at: $t}]' > "$FAKE/events5.json"
  route 'api --paginate repos/example-org/web/issues/5/events' events5.json
}
# munpark <name> <head> [labels]: a needs-you at the merge of the accepted HA; the PR's head given
munpark() {
  env_new "$1"
  { issue 5 "in-progress${3:+,$3}"; } | issues
  p=$(pr 50 5 "$2" green); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "${@:4}")"; route 'pr view 50 *' pr50.json
  json c5.json '{"comments": []}'; route 'issue view 5 *' c5.json
  state 5 phase=needs-you pr=50 accept_sha=$HA "accept_at=$((NOW - 3600))" "ny_at=$((NOW - 600))" ny_stage=merge merge_tries=3 \
    "reason=gh pr merge failed (after 3 tries)"
  touch "$CANCCU_HOME/paused"
}


macc merge-timeout
flaky 1 '' 124
fpass
ok "a merge call killed by its timeout (124, no output) → retried, no needs-you" \
  eq "$(st 5 phase) $(st 5 merge_tries) $(grep -c needs-you "$FAKE/gh.log")" "accept 1 0"
macc merge-already-enabled
flaky 1 'GraphQL: Pull request auto merge is already enabled (enablePullRequestAutoMerge)'
fpass
ok "--auto refused as already enabled → merging, no needs-you" eq "$(st 5 phase) $(st 5 merge_sha) $(grep -c needs-you "$FAKE/gh.log")" "merging $HA 0"
ok "… logged" grep -qF '#5 PR #50: auto-merge is armed already (accepted)' "$CANCCU_HOME/dispatch.log"
macc merge-armed-after-502
flaky 1 'HTTP 502: Bad Gateway'
json pr50armed.json "$(jq -n --arg h "$HA" '{headRefOid: $h, autoMergeRequest: {enabledAt: "2030-11-05T11:59:00Z"}}')"
route 'pr view 50 *' pr50armed.json
fpass
ok "a 502 on --auto that GitHub armed anyway (fresh read) → merging, no try spent" \
  eq "$(st 5 phase) [$(st 5 merge_tries)] $(grep -c needs-you "$FAKE/gh.log")" "merging [] 0"

issue_accept accept-kept-on-fail $HA $HA
flaky 0 'GraphQL: Pull request is not mergeable (enablePullRequestAutoMerge)'
fpass
ok "an accept on the issue whose merge fails → needs-you, the issue keeps \`accepted\`" \
  eq "$(st 5 phase) $(grep -c 'issue edit 5 .*--remove-label accepted' "$FAKE/gh.log")" "needs-you 0"
issue_accept accept-later-holder $HA $HA
pr 50 5 $HA green accepted | prs
jq -n '[{event: "labeled", label: {name: "accepted"}, actor: {login: "review-bot"}, created_at: "2030-11-05T11:30:00Z"}]' > "$FAKE/events50.json"
route 'api --paginate repos/example-org/web/issues/50/events' events50.json
dispatch --once
ok "an \`accepted\` on the PR that does not count does not hide the user's on the issue → merged" \
  has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"

macc requeue-clears
state 5 phase=accept pr=50 accept_sha=$HB "accept_at=$((NOW - 3600))" merge_tries=2
fpass
ok "a requeue (new push) clears merge_tries and the old accept_sha" eq "$(st 5 phase) [$(st 5 merge_tries)] [$(st 5 accept_sha)]" "check [] []"
ok "new_cycle clears accept_sha" eq "$(lib eval "new_cycle 5; st_get 5 accept_sha")" ""

# a merge needs-you lifted: back to the accept's reason and owner, no new ask line in the feed
munpark merge-unpark-owner $HA
printf '%s\n' LEADER=on LEADER_ACCEPTS=technical >> "$CANCCU_ROOT/projects/web/config"
sed -i 's/^reason=.*/reason=gh pr merge failed (after 3 tries)/' "$CANCCU_HOME/state/5"
echo 'accept_reason=users see it: web/index.html' >> "$CANCCU_HOME/state/5"
echo owner=po >> "$CANCCU_HOME/state/5"
dispatch --once
ok "a merge needs-you lifted → accept with the accept's reason and owner" \
  eq "$(st 5 phase)|$(st 5 reason)|$(st 5 owner)" "accept|users see it: web/index.html|po"
ok "… no new accept ask in the feed" not grep -qP '\task\taccept\t5\t' "$CANCCU_HOME/events"

macc conflict-mm-transient
pr 50 5 $HA green accepted | jq '.mergeStateStatus = "DIRTY"' | prs
lib eval ". '$root/lib/canccu-merge.sh'; "'main_merge() { MERGED=error MERGE_WHY="git push: HTTP 502"; }; fetch; conflict_merge 5 50 '"$HA"
ok "a scripted merge of main that fails (conflict) → no needs-you on the first error" \
  eq "$(st 5 phase) $(st 5 mm_err) [$(st 5 conflict_merge)]" "accept 1 []"
lib eval ". '$root/lib/canccu-merge.sh'; "'main_merge() { MERGED=error MERGE_WHY="git push: HTTP 502"; }; fetch; conflict_merge 5 50 '"$HA"'; conflict_merge 5 50 '"$HA"
ok "… needs-you once 3 errors came in a row" eq "$(st 5 phase) [$(st 5 mm_err)]" "needs-you []"

# ---------------------------------------------------------------- gating

# a fix-check's pass leaves the fix round: a later push takes the post-pass path again
review_env fixcheck-pass-stage 'Review verdict: pass' fixcheck
echo review_mode=fixcheck >> "$CANCCU_HOME/state/5"
dispatch --once
ok "a fix-check pass → stage review" eq "$(st 5 stage) $(st 5 pass_sha)" "review $HA"

# a path with a non-ASCII letter and a space comes back as it is, not C-quoted: the risky-path
# check and the no-repeat match see it
env_new quote-path
d=$E/code/web
_qg() { GIT_AUTHOR_DATE=2030-11-05T10:00:00Z GIT_COMMITTER_DATE=2030-11-05T10:00:00Z \
        "$FAKE_REAL_GIT" -C "$d" -c user.name=octo -c user.email=octo@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
rm -rf "$d"; mkdir -p "$d"; _qg init; echo a > "$d/a.txt"; _qg add .; _qg commit -m root; _qg update-ref refs/remotes/origin/main main
QP_B=$("$FAKE_REAL_GIT" -C "$d" rev-parse HEAD)
_qg checkout -b pr; echo x > "$d/café menu.txt"; _qg add .; _qg commit -m "the PR"; QP_H=$("$FAKE_REAL_GIT" -C "$d" rev-parse HEAD)
touch "$FAKE/realgit"
ok "postpass_full names a risky path with a non-ASCII letter" \
  eq "$(lib eval ". '$root/lib/canccu-merge.sh'; FIXCHECK_RISKY='café'; postpass_full $QP_B $QP_H")" "risky path café menu.txt"
ok "changed_lines keeps the path as it is" eq "$(lib eval "changed_lines $QP_B $QP_H")" "café menu.txt	1	1"

# ---------------------------------------------------------------- accept pings and channels

# pings <glob>: the comments posted as the reviewer bot whose gh.log line matches (one per line)
pings() { grep -cE -- "$1" <(paste <(cut -f2 "$FAKE/gh.env") "$FAKE/gh.log" | grep -P '^reviewer\t' | cut -f2-); }
env_new ping-accepted-issue
{ issue 5 in-progress,awaiting-accept,accepted; } | issues
pr 50 5 $HA green | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual: changes .github/ (.github/workflows/ci.yml)"
dispatch --once
ok "\`accepted\` on the issue only: no accept ping" eq "$(pings '^issue comment 5 -R example-org/web --body @octo For the product owner: PR #50 waits')" 0

env_new ping-ship-only ACCEPT_CHANNELS=ship
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 $HA green accepted | prs
state 5 phase=accept pr=50 accept_sha=$HA "accept_at=$((NOW - 60))" "reason=manual: changes .github/ (.github/workflows/ci.yml)"
dispatch --once
ok "ACCEPT_CHANNELS=ship: an ignored label does not stop the ping, which offers canccu-ship only" \
  has gh.log 'issue comment 5 -R example-org/web --body @octo For the product owner: PR #50 waits for your accept: `canccu-ship 5`.'
lib eval "fetch; to_accept 5 50 'manual: changes .github/' $HA"
ok "… the accept request offers canccu-ship only" eq "$(grep -q 'Accept: `canccu-ship 5`\.' "$FAKE/gh.log" && echo yes) $(grep -c 'Accept: add the label' "$FAKE/gh.log")" "yes 0"

# ---------------------------------------------------------------- a named close refused

# failgh <"cmd sub"> <error>: every such gh call fails with that error (fpass runs the pass)
failgh() {
  mkdir -p "$E/sbin"
  cat > "$E/sbin/gh" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "$1" ] && { echo "$2" >&2; exit 1; }
exec "$fb/gh" "\$@"
SH
  chmod +x "$E/sbin/gh"
}
env_new close-refused
json pr50.json '{"state": "MERGED", "title": "Add a thing", "body": "Closes #5", "closingIssuesReferences": [{"number": 5}], "headRefName": "5-thing"}'
route 'pr view 50 *' pr50.json
state 5 phase=merging pr=50 merge_sha=$HA how=auto "merge_at=$((NOW - 600))" "gone_at=$((NOW - 3 * 60))"
{ issue 5 in-progress; } | issues
failgh "issue close" 'GraphQL: Resource not accessible by integration (closeIssue)'
fpass
ok "a named close refused for good → needs-you at once, not after MERGE_WAIT_MIN" \
  eq "$(grep -c 'issue edit 5 -R example-org/web --add-label needs-you' "$FAKE/gh.log") [$(st 5 phase)]" "1 []"

# ---------------------------------------------------------------- small guards

env_new nw-no-lead
pr 50 5 $HA green needs-work | prs
lib eval 'lead_of() { :; }; fetch; needs_work_from_pr 5 50; echo "rc=$?"' > "$E/out" 2>&1
ok "needs_work_from_pr with no lead issue → no gh call" eq "$(grep -c '^issue edit' "$FAKE/gh.log") $(grep -c 'rc=0' "$E/out")" "0 1"

env_new fix-zero FIX_ATTEMPTS=0
state 5 phase=review pr=50 blocking_prev=4 blocking_last=2
ok "FIX_ATTEMPTS=0: no extra fix round" eq "$(lib eval 'extra_fix_due 5 && echo due || echo none')" none

# canccu-stop --forget: the blocked marker stays while the label could not be removed
env_new stop-label-fails
{ issue 21 needs-you,blocked; } | issues
state 21 phase=needs-you pr=70 branch=21-thing
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/21"
failgh "issue edit" 'HTTP 502: Bad Gateway'
PATH="$E/sbin:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-stop" --forget 21 > "$E/out" 2>&1
ok "canccu-stop: the label edit failed → the blocked marker is kept" test -e "$CANCCU_HOME/blocked/21"

# ---------------------------------------------------------------- --help

env_new help
touch "$CANCCU_HOME/paused"
bad=""
for c in classify dispatch dispatcher init pause resume review run ship status stop up; do
  out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-$c" --help 2>/dev/null); rc=$?
  [ "$rc" = 0 ] && [[ $out == canccu-$c* ]] || bad+=" $c($rc)"
done
ok "every command answers --help with its usage, exit 0" eq "[${bad# }]" "[]"
ok "… canccu-resume --help resumes nothing" test -e "$CANCCU_HOME/paused"

echo "canccu-followups tests: $npass passed, $nfail failed"; (( nfail == 0 ))
