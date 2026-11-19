#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-accept-carry.sh — offline tests for an accept that survives the dispatcher's merges
# of main (#244): a canccu-ship accept over a clean merge, a merge with resolved conflicts once its
# fix-check passes, and canccu-ship on a head with no pass (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# rcrepo: a real repo in CLONE with a conflict, its shas exported. MB_B is the accepted head (it
# edits a.txt line 2); main (origin/main) edits the same line and adds m.txt. MB_RC merges main with
# the conflict resolved in a.txt; MB_RX resolves it and edits o.txt, a file outside the PR's diff;
# MB_RP adds a plain commit of the PR's own on top of MB_RC.
rcrepo() {
  local d=$E/code/web
  _rcg() { GIT_AUTHOR_DATE=2030-11-05T10:00:00Z GIT_COMMITTER_DATE=2030-11-05T10:00:00Z \
             "$FAKE_REAL_GIT" -C "$d" -c user.name=octo -c user.email=octo@example.com -c init.defaultBranch=main "$@"; }
  _rcq() { _rcg "$@" >/dev/null 2>&1; }
  rm -rf "$d"; mkdir -p "$d"; _rcq init
  printf 'a1\na2\na3\n' > "$d/a.txt"; echo o1 > "$d/o.txt"; _rcq add .; _rcq commit -m root
  _rcq checkout -b pr; printf 'a1\na2-pr\na3\n' > "$d/a.txt"; _rcq commit -am "the PR"; MB_B=$(_rcg rev-parse HEAD)
  _rcq checkout main; printf 'a1\na2-main\na3\n' > "$d/a.txt"; echo m1 > "$d/m.txt"; _rcq add .; _rcq commit -m M1
  _rcq update-ref refs/remotes/origin/main main
  _rcq checkout pr; _rcq merge main; printf 'a1\na2-both\na3\n' > "$d/a.txt"; _rcq add a.txt; _rcq commit --no-edit; MB_RC=$(_rcg rev-parse HEAD)
  echo a4 >> "$d/a.txt"; _rcq commit -am "more of the PR"; MB_RP=$(_rcg rev-parse HEAD)
  _rcq checkout -b rx "$MB_B"; _rcq merge main; printf 'a1\na2-both\na3\n' > "$d/a.txt"; echo o2 > "$d/o.txt"
  _rcq add a.txt o.txt; _rcq commit --no-edit; MB_RX=$(_rcg rev-parse HEAD)
  _rcq checkout main
  export MB_B MB_RC MB_RP MB_RX
  touch "$FAKE/realgit"
}

# movenv <name> <channel label|ship> <new head> [config line...]: PR 50 of the manual issue 5, accepted
# on MB_B through that channel and armed there (merging, how accepted), has moved to the new head
movenv() {
  local ch=$2 h=$3; env_new "$1" "${@:4}"; rcrepo
  { issue 5 in-progress,manual-accept; } | issues
  pr 50 5 "$h" green "$([ "$ch" = label ] && echo accepted)" | prs
  json events50.json '[{"event": "labeled", "label": {"name": "accepted"}, "actor": {"login": "octo"}, "created_at": "2030-11-05T11:30:00Z"}]'
  route 'api --paginate repos/example-org/web/issues/50/events' events50.json
  [ "$ch" = ship ] && printf '%s\t5\t50\t%s\tpo\n' "$((NOW - 3600))" "$MB_B" > "$CANCCU_HOME/accepts.log"
  state 5 phase=merging pr=50 "merge_sha=$MB_B" how=accepted "merge_at=$((NOW - 600))" "accept_sha=$MB_B" \
    "accept_at=$((NOW - 7200))" "pass_sha=$MB_B" "full_sha=$MB_B" stage=review
}

# fxpass <name> <verdict word> [config line...]: in the same repo state, the post-pass fix-check of
# MB_B..<head> on PR 50 posted its verdict; FX_HEAD (default MB_RC) is the head. The caller adds
# carry_sha/carry_by.
fxpass() {
  env_new "$1" "${@:3}"; rcrepo
  local h=${FX_HEAD:-$MB_RC} p
  { issue 5 in-progress,manual-accept; } | issues
  p=$(pr 50 5 "$h"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T11:20:00Z "$(vcomment 2030-11-05T11:30:00Z "$VB0"$'\n'"Review verdict: $2 $h")")"
  route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "a.txt"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue5.json '{"labels": [{"name": "in-progress"}, {"name": "manual-accept"}], "comments": []}'; route 'issue view 5 *' issue5.json
  state 5 phase=review pr=50 "review_sha=$h" stage=fixcheck review_mode=postpass "full_sha=$MB_B" "pass_sha=$MB_B" \
    verdict_at=2030-11-05T11:00:00Z "started=$NOW"
}
asked() { grep -c -- '--body-file' "$FAKE/gh.log"; }

# ---------------------------------------------------------------- the default (A1)

ok "KEEP_ACCEPT_ON_MAIN_MERGE defaults to 1" grep -qE '^KEEP_ACCEPT_ON_MAIN_MERGE=1( |$)' "$root/lib/canccu-config.default"

# ---------------------------------------------------------------- canccu-ship's accept over a clean merge (A2)

env_new ship-clean; mmrepo
{ issue 5 in-progress,manual-accept; } | issues
pr 50 5 "$MB_MM1" | prs
printf '%s\t5\t50\t%s\tpo\n' "$((NOW - 3600))" "$MB_B" > "$CANCCU_HOME/accepts.log"
state 5 phase=merging pr=50 "merge_sha=$MB_B" how=accepted "merge_at=$((NOW - 600))" "accept_sha=$MB_B" "accept_at=$((NOW - 7200))"
dispatch --once
ok "accepted with canccu-ship, then a clean merge of main → auto-merge on the new head" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $MB_MM1"
ok "… no new accept request" eq "$(asked) $(st 5 phase)" "0 merging"
ok "… logged as the carry-over" grep -qF "#5 PR #50: \`accepted\` carried over from ${MB_B:0:7} to ${MB_MM1:0:7}: a merge of main only (KEEP_ACCEPT_ON_MAIN_MERGE=1)" "$CANCCU_HOME/dispatch.log"
env_new ship-clean-off ACCEPT_CHANNELS=label; mmrepo
{ issue 5 in-progress,manual-accept; } | issues
pr 50 5 "$MB_MM1" | prs
printf '%s\t5\t50\t%s\tpo\n' "$((NOW - 3600))" "$MB_B" > "$CANCCU_HOME/accepts.log"
state 5 phase=merging pr=50 "merge_sha=$MB_B" how=accepted "merge_at=$((NOW - 600))" "accept_sha=$MB_B" "accept_at=$((NOW - 7200))"
dispatch --once
ok "… ACCEPT_CHANNELS=label: the ship record does not count, review again" eq "$(grep -c -- '--auto' "$FAKE/gh.log") $(st 5 phase)" "0 check"

# ---------------------------------------------------------------- a merge with resolved conflicts (A3)

# the fixed dates make the shas the same in every env: read them once for movenv's argument
env_new rc-shas; rcrepo
for ch in label ship; do
  movenv "rc-$ch" "$ch" "$MB_RC"
  dispatch --once
  ok "$ch: a merge of main resolved inside the PR's files → the accept is held for the fix-check" eq "$(st 5 carry_sha) $(st 5 carry_by)" "$MB_B $ch"
  ok "… not merged yet: checked again" eq "$(grep -c -- '--auto' "$FAKE/gh.log") $(st 5 phase)" "0 check"
done
movenv rc-plain label "$MB_RP"
dispatch --once
ok "a resolved merge plus a commit of the PR's own → no accept held" eq "$(st 5 carry_sha)$(st 5 phase)" check
movenv rc-outside label "$MB_RX"
dispatch --once
ok "a resolution that changes a file outside the PR's diff → no accept held" eq "$(st 5 carry_sha)$(st 5 phase)" check
ok "… said" grep -qF "#5 PR #50: ${MB_RX:0:7} resolves a conflict outside the PR's own files (o.txt); a new accept is asked" "$CANCCU_HOME/dispatch.log"
movenv rc-off label "$MB_RC" KEEP_ACCEPT_ON_MAIN_MERGE=0
dispatch --once
ok "KEEP_ACCEPT_ON_MAIN_MERGE=0: no accept held, today's requeue" eq "$(st 5 carry_sha)$(st 5 phase)" check

for ch in label ship; do
  fxpass "fx-pass-$ch" pass
  printf 'carry_sha=%s\ncarry_by=%s\n' "$MB_B" "$ch" >> "$CANCCU_HOME/state/5"
  [ "$ch" = ship ] && printf '%s\t5\t50\t%s\tpo\n' "$((NOW - 3600))" "$MB_B" > "$CANCCU_HOME/accepts.log"
  dispatch --once
  ok "$ch: the resolved merge's fix-check passes → auto-merge on it" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $MB_RC"
  ok "… no accept request" eq "$(asked) $(st 5 phase) $(st 5 how)" "0 merging accepted"
  ok "… logged with the reason" grep -qF "#5 PR #50: \`accepted\` carried over from ${MB_B:0:7} to ${MB_RC:0:7}: a merge of main only (KEEP_ACCEPT_ON_MAIN_MERGE=1) (conflicts resolved, fix-check pass)" "$CANCCU_HOME/dispatch.log"
  ok "… the held accept is spent" eq "$(st 5 carry_sha)" ""
done
fxpass fx-changes changes
printf 'carry_sha=%s\ncarry_by=label\n' "$MB_B" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "the same with a failing fix-check → no carry-over, no merge" eq "$(grep -c '^pr merge' "$FAKE/gh.log") $(st 5 carry_sha)" "0 "
FX_HEAD=$MB_RP fxpass fx-plain pass
printf 'carry_sha=%s\ncarry_by=label\n' "$MB_B" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "a pass on a head with a commit of the PR's own since → a new accept is asked" eq "$(grep -c '^pr merge' "$FAKE/gh.log") $(st 5 phase) $(asked)" "0 accept 1"
fxpass fx-pass-off pass KEEP_ACCEPT_ON_MAIN_MERGE=0
printf 'carry_sha=%s\ncarry_by=label\n' "$MB_B" >> "$CANCCU_HOME/state/5"
dispatch --once
ok "KEEP_ACCEPT_ON_MAIN_MERGE=0: the pass asks for an accept" eq "$(grep -c '^pr merge' "$FAKE/gh.log") $(st 5 phase)" "0 accept"

# the carried accept holds for a later clean merge too, though the label went with the requeue
env_new carried-again; mmrepo
{ issue 5 in-progress,manual-accept; } | issues
pr 50 5 "$MB_MM2" | prs
state 5 phase=merging pr=50 "merge_sha=$MB_MM1" how=accepted "merge_at=$((NOW - 600))" "accept_at=$((NOW - 7200))" "carried=$MB_MM1" carried_by=label
dispatch --once
ok "an accept carried to a head carries over the next clean merge" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $MB_MM2"

# ---------------------------------------------------------------- canccu-ship on a head with no pass (A5)

ship() { PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" "$@" > "$E/out" 2>&1; }
env_new ship-unreviewed; rcrepo
{ issue 5 in-progress,manual-accept; } | issues
pr 50 5 "$MB_RC" | prs
state 5 phase=check pr=50 "pass_sha=$MB_B" "full_sha=$MB_B" "merge_sha=$MB_B" stage=review "check_at=$NOW"
ship 5; rc=$?
ok "canccu-ship on a head with no review pass → arms nothing" eq "$rc $(grep -c '^pr merge' "$FAKE/gh.log")" "0 0"
ok "… records the accept of that head" eq "$(cut -f2- "$CANCCU_HOME/accepts.log")" "5	50	$MB_RC	po"
ok "… says it goes to the fix-check first" grep -qF "#5 PR #50: ${MB_RC:0:7} has no review pass yet; sent to the fix-check first, and the accept carries over once it passes" "$E/out"
ok "… holds the accept for that head" eq "$(st 5 carry_sha) $(st 5 carry_by) $(st 5 phase)" "$MB_RC ship check"
fxpass ship-unreviewed-pass pass
printf 'carry_sha=%s\ncarry_by=ship\n' "$MB_RC" >> "$CANCCU_HOME/state/5"
printf '%s\t5\t50\t%s\tpo\n' "$((NOW - 60))" "$MB_RC" > "$CANCCU_HOME/accepts.log"
dispatch --once
ok "… its fix-check passes → auto-merge on that head, no request" eq "$(grep -c -- "--match-head-commit $MB_RC" "$FAKE/gh.log") $(asked)" "1 0"
ok "… logged" grep -qF "#5 PR #50: canccu-ship's accept of ${MB_RC:0:7} holds: its fix-check passed" "$CANCCU_HOME/dispatch.log"
env_new ship-passed; rcrepo
{ issue 5 in-progress,manual-accept; } | issues
pr 50 5 "$MB_B" | prs
state 5 phase=accept pr=50 "accept_sha=$MB_B" "pass_sha=$MB_B" "accept_at=$((NOW - 3600))"
ship 5
ok "canccu-ship on the passed head arms it, as today" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $MB_B"

echo "canccu-accept-carry tests: $npass passed, $nfail failed"
(( nfail == 0 ))
