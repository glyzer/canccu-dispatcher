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
ok "… needs-you once MERGE_TRIES errors came in a row" eq "$(st 5 phase) [$(st 5 mm_err)]" "needs-you []"

echo "canccu-followups tests: $npass passed, $nfail failed"; (( nfail == 0 ))
