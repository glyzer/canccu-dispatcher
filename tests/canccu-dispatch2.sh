#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-dispatch2.sh — offline tests for canccu-dispatch, continued: log times, the state
# format, the holds of a pass, run exits and crashes (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- log times and the state format

env_new log-utc
dispatch --once
ok "log: a line starts with its UTC time and a Z" \
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ' "$CANCCU_HOME/dispatch.log"
ok "… the test clock's time, whatever the host's zone" grep -q '^2030-11-05T12:00:00Z ' <<<"$(TZ=JST-9 lib log x)"

# units in flight across the upgrade: a running worker, a needs-you and a merge; the pass after
# the migration does to them what it does with the format file already there
fmt_env() {
  env_new "$1"
  { issue 5 in-progress; issue 6 needs-you; issue 7 in-progress; } | issues
  pr 70 7 $HA green | prs
  json pr70.json '{"state": "OPEN", "title": "feat: seven", "headRefOid": "'$HA'", "autoMergeRequest": {"enabledAt": "2030-11-05T11:00:00Z"}}'
  route 'pr view 70 *' pr70.json
  state 5 phase=work "started=$NOW" color=0; live_lock 5
  state 6 phase=needs-you "reason=the worker stopped: crashed (exit 1)" color=1
  state 7 phase=merging pr=70 how=auto merge_sha=$HA "merge_at=$((NOW - 60))" color=2
}
fmt_env fmt-before; echo 1 > "$CANCCU_HOME/state.format"
dispatch --once; base_out=$(grep -v 'state format' "$E/out" | cut -c22-); base_gh=$(cat "$FAKE/gh.log")
base_st=$(for n in 5 6 7; do cat "$CANCCU_HOME/state/$n"; done)
fmt_env fmt-upgrade
dispatch --once
ok "state format: a project without state.format is migrated to 1" eq "$(cat "$CANCCU_HOME/state.format")" 1
ok "… the migration is logged" grep -qE '^[0-9TZ:-]{20} state format 0 → 1: ' "$CANCCU_HOME/dispatch.log"
ok "… the pass then handles the work, needs-you and merging units as before (state)" \
  eq "$(for n in 5 6 7; do cat "$CANCCU_HOME/state/$n"; done)" "$base_st"
ok "… (GitHub calls)" eq "$(cat "$FAKE/gh.log")" "$base_gh"
ok "… (pane lines)" eq "$(grep -v 'state format' "$E/out" | cut -c22-)" "$base_out"
dispatch --once
ok "… the next start migrates nothing" eq "$(grep -c 'state format' "$CANCCU_HOME/dispatch.log")" 1
echo 9 > "$CANCCU_HOME/state.format"; : > "$FAKE/gh.log"
dispatch --once; rc=$?
ok "state format 9: the start stops" eq "$rc" 1
ok "… with the message" grep -qF 'state format 9 is newer than this release knows (1); install a newer release' "$E/out"
ok "… before any pass (no GitHub call)" eq "$(wc -l < "$FAKE/gh.log")" 0
ok "… and the file is left as it was" eq "$(cat "$CANCCU_HOME/state.format")" 9
ok "--dry-run with state format 9 stops too" \
  grep -qF 'is newer than this release knows' <<<"$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --dry-run 2>&1)"
rm -f "$CANCCU_HOME/state.format"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --dry-run > "$E/dry" 2>&1
ok "--dry-run on an old project says it would migrate, and writes nothing" \
  eq "$(grep -c 'would: migrate the state format 0 → 1' "$E/dry") $([ -e "$CANCCU_HOME/state.format" ] && echo written || echo none)" "1 none"

# ---------------------------------------------------------------- holds: low disk, GitHub rate limit

# fake df: the free MB in $FAKE/df_mb (plenty without it), for any path
cat > "$fb/df" <<'EOF2'
#!/usr/bin/env bash
printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\nfake 99999 1 %s 1%% /\n' "$(cat "$FAKE/df_mb" 2>/dev/null || echo 99999)"
EOF2
chmod +x "$fb/df"
status() { PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1; }

env_new disk-low
{ issue 3 ready; } | issues
echo 100 > "$FAKE/df_mb"
dispatch --once; dispatch --once
ok "disk: below DISK_MIN_MB a ready issue does not start" not started 3
ok "… the hold is logged once over two passes" \
  eq "$(grep -c "disk: 100 MB free for $WORKERS_DIR, below DISK_MIN_MB (200); nothing new starts" "$CANCCU_HOME/dispatch.log")" 1
ok "canccu-status shows the low disk" grep -qF ' · disk low: 100 MB (DISK_MIN_MB 200)' <<<"$(status)"
echo 500 > "$FAKE/df_mb"
dispatch --once
ok "… with 500 MB free the next pass starts it" started 3
ok "… and logs the clear line" grep -q 'disk: 500 MB free again; starts resume$' "$CANCCU_HOME/dispatch.log"
ok "canccu-status: no disk part once it cleared" not grep -qF 'disk low' <<<"$(status)"
rm -f "$FAKE/df_mb"

# fake gh in front of the harness's: $FAKE/limit-once makes the next issue list answer with a
# rate limit (once)
mv "$fb/gh" "$fb/gh.real"
cat > "$fb/gh" <<'EOF2'
#!/usr/bin/env bash
if [ -e "$FAKE/limit-once" ] && [ "$1 $2" = "issue list" ]; then
  rm -f "$FAKE/limit-once"; echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1
fi
exec "$(dirname "$0")/gh.real" "$@"
EOF2
chmod +x "$fb/gh"

env_new gh-limit
{ issue 3 ready; } | issues
json ratelimit.json "{\"resources\": {\"core\": {\"reset\": $((NOW + 600))}}}"
route 'api rate_limit*' ratelimit.json
touch "$FAKE/limit-once"
dispatch --once
ok "rate limit: a read that hits it writes gh_limit with the reset" eq "$(cat "$CANCCU_HOME/gh_limit" 2>/dev/null)" $((NOW + 600))
ok "… (read from gh api rate_limit)" has gh.log "api rate_limit"
ok "canccu-status shows the rate limit" grep -qF " · GitHub rate limit until $(date -u -d "@$((NOW + 600))" +%FT%TZ)" <<<"$(status)"
: > "$FAKE/gh.log"
dispatch --once; dispatch --once
ok "… the next passes make no gh call" eq "$(wc -l < "$FAKE/gh.log")" 0
ok "… and log the pause once" \
  eq "$(grep -c "GitHub rate limit: passes pause until $(date -u -d "@$((NOW + 600))" +%FT%TZ)$" "$CANCCU_HOME/dispatch.log")" 1
ok "… the pass did not end early" not grep -q "the pass ended early" "$E/out"
CANCCU_NOW=$((NOW + 601)) dispatch --once
ok "… after the reset the over line" grep -q 'GitHub rate limit over; passes resume$' "$CANCCU_HOME/dispatch.log"
ok "… the file goes" not test -e "$CANCCU_HOME/gh_limit"
ok "… and the pass runs" started 3

env_new gh-limit-secondary
lib eval 'CANCCU_MUT_TO_LOG=1; mut_out sh -c "echo \"You have exceeded a secondary rate limit\" >&2; exit 1"' > /dev/null
ok "rate limit: a write that hits the secondary limit pauses 15 minutes" eq "$(cat "$CANCCU_HOME/gh_limit" 2>/dev/null)" $((NOW + 900))
ok "… without asking GitHub for the reset" hasnt gh.log "rate_limit"
rm -f "$CANCCU_HOME/gh_limit"
lib eval 'ghj issue view 5 --json body' > /dev/null
ok "rate limit: a read with another error writes nothing" not test -e "$CANCCU_HOME/gh_limit"
mv -f "$fb/gh.real" "$fb/gh"

# ---------------------------------------------------------------- canccu-stop --forget

stop() { PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-stop" "$@" > "$E/out" 2>&1; }
env_new stop-forget
{ issue 21 needs-you; issue 22 needs-you,blocked; } | issues
state pkg-4-thing pkg=4 step=1 members="21 22" phase=needs-you pr=70 branch=pkg-4-thing
wt="$WORKERS_DIR/worktrees/web/pkg-4-thing"; mkdir -p "$wt"; echo x > "$wt/file"
live_lock pkg-4-thing; : > "$WORKERS_DIR/web-pkg-4-thing.id"; : > "$WORKERS_DIR/web-pkg-4-thing.nudge"
mkdir -p "$CANCCU_HOME/blocked"; : > "$CANCCU_HOME/blocked/22"
stop --forget 21
ok "--forget: the run is stopped" grep -q '^--kill web pkg-4-thing$' "$FAKE/worker.log"
ok "… no state file" not test -e "$CANCCU_HOME/state/pkg-4-thing"
ok "… no worktree" not test -e "$wt"
ok "… (git worktree remove --force)" grep -qF "worktree remove --force $wt" "$FAKE/git.log"
ok "… no run lock, .id or .nudge" eq "$(compgen -G "$WORKERS_DIR/*pkg-4-thing*" | wc -l)" 0
ok "… the labels removed from each member" \
  eq "$(grep -c -e 'issue edit 21 -R example-org/web --remove-label in-progress,needs-you,awaiting-accept$' -e 'issue edit 22 -R example-org/web --remove-label in-progress,needs-you,awaiting-accept,blocked$' "$FAKE/gh.log")" 2
ok "… blocked only where the dispatcher set it (its marker goes too)" not test -e "$CANCCU_HOME/blocked/22"
ok "… the PR and the branch are left alone" hasnt gh.log "pr "
ok "… the log line" grep -qF '#pkg-4-thing forgotten (canccu-stop --forget): runs stopped, state and worktree removed, labels cleared' "$CANCCU_HOME/dispatch.log"
stop --forget 21; rc=$?
ok "… a second call: nothing to forget, exit 0" eq "$(cat "$E/out") $rc" "nothing to forget for #21 0"

echo "canccu-dispatch2 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
