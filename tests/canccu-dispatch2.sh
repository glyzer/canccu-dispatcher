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

echo "canccu-dispatch2 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
