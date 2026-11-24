#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-claim.sh — offline tests for the dispatcher claim (lib/canccu-claim.sh, #15): one
# dispatcher per repo across hosts. Claim, renew and its throttle, refuse, expiry, release,
# take-over, a gh error, the queue and canccu-init (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

at() { date -u -d "@$(( NOW + $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }   # at <minutes from NOW>
body() { jq -r --argjson n "${1:-99}" '.[] | select(.number == $n) | .body' "$FAKE/claim.json"; }
edits() { grep -c "^issue edit 99 " "$FAKE/gh.log"; }
dlog() { grep -cF -- "$1" "$CANCCU_HOME/dispatch.log"; }
# a ready issue 5: a pass that acts starts its worker
ready5() { issue 5 ready | issues; }
# loop: the dispatcher's loop, stopped by TERM at its first sleep between passes (a clean stop)
REAL_SLEEP=$(command -v sleep)
loop() {
  mkdir -p "$E/sb"
  printf '#!/bin/sh\n[ "$1" = 60 ] || exec %s "$@"\nkill -TERM "$PPID"; exit 0\n' "$REAL_SLEEP" > "$E/sb/sleep"; chmod +x "$E/sb/sleep"
  # the shell's "Terminated" for the stopped child is noise
  ( PATH="$E/sb:$fb:$PATH" CANCCU_WORKER="$fb/worker" timeout 60 "$root/bin/canccu-dispatch" > "$E/out" 2>&1 ) 2>/dev/null
}

# ---------------------------------------------------------------- claim

env_new claim-create "HOST_LABEL=lab-1"
ready5; echo '[]' > "$FAKE/claim.json"; rm -f "$CANCCU_ROOT/host-id"
dispatch --once
id=$(cat "$CANCCU_ROOT/host-id" 2>/dev/null)
ok "claim: the host id is written once, 16 random hex characters" grep -qxE '[0-9a-f]{16}' <<<"$id"
ok "… no claim issue: it is created, titled and labelled" has gh.log "issue create -R example-org/web --title Dispatcher claim --label dispatcher-claim --body-file"
ok "… and pinned" has gh.log "issue pin 900 -R example-org/web"
ok "… its body holds the host id, the label and the time" \
  eq "$(body 900 | grep -E '^(host|label|at):')" "host: $id
label: lab-1
at: 2030-11-05T12:00:00Z"
ok "… never the hostname, a path or the user name" not grep -qF -e "$(hostname)" -e "$E" -e "${USER:-nobody-here}" <<<"$(body 900)"
ok "… the pass acts" started 5
ok "… the creation is logged" eq "$(dlog 'claim: created #900')" 1
dispatch --once
ok "… a second pass: the same host id, no second issue" eq "$(cat "$CANCCU_ROOT/host-id") $(grep -c '^issue create' "$FAKE/gh.log")" "$id 1"

env_new claim-create-lag
ready5; echo '[]' > "$FAKE/claim.json"; echo 'lag:issue create' >> "$FAKE/routes"
dispatch --once
ok "claim: a new claim the list does not show yet (GitHub lags) is ours: never closed, the pass acts" \
  eq "$(grep -c '^issue close' "$FAKE/gh.log") $(started 5 && echo started) $(grep -E '^(issue|state)=' "$CANCCU_HOME/claim" | tr '\n' ' ')" "0 started issue=900 state=ours "

env_new claim-create-lag-other
ready5; echo '[]' > "$FAKE/claim.json"; echo 'lag:issue create' >> "$FAKE/routes"
claim_json "$HOST_OTHER" "lab-2" "$(at -5)" 99; mv "$FAKE/claim.json" "$FAKE/lag-other.json"; echo '[]' > "$FAKE/claim.json"
dispatch --once
ok "claim: another host's issue listed while ours lags: ours (#900) is closed, the pass refuses" \
  eq "$(grep -c '^issue close 900' "$FAKE/gh.log") $(grep -c . "$FAKE/worker.log")" "1 0"

env_new claim-pin-fails
ready5; echo '[]' > "$FAKE/claim.json"; echo 'fail:issue pin' >> "$FAKE/routes"
dispatch --once; dispatch --once
ok "claim: a pin that fails warns once, and the pass acts" eq "$(dlog 'could not pin the claim issue #900') $(started 5 && echo started)" "1 started"

# ---------------------------------------------------------------- renew and its throttle

env_new claim-fresh
ready5; claim_json "$HOST_ME" "" "$(at -9)"
dispatch --once
ok "renew: our claim 9 minutes old is not written (CLAIM_RENEW_MIN 10), --once never releases" eq "$(edits)" 0
ok "… the pass acts" started 5
env_new claim-renew
ready5; claim_json "$HOST_ME" "" "$(at -10)"
dispatch --once
ok "renew: 10 minutes old: the body is edited, never commented" eq "$(edits) $(grep -c '^issue comment 99' "$FAKE/gh.log")" "1 0"
ok "… with the new time" eq "$(body | grep '^at:')" "at: 2030-11-05T12:00:00Z"
env_new claim-renew-min "CLAIM_RENEW_MIN=3"
claim_json "$HOST_ME" "" "$(at -4)"
dispatch --once
ok "renew: CLAIM_RENEW_MIN=3 writes a claim 4 minutes old" eq "$(edits)" 1
env_new claim-own-expired
ready5; claim_json "$HOST_ME" "" "$(at -45)"
dispatch --once
ok "renew: our own claim past its expiry is renewed, and the pass acts" eq "$(edits) $(started 5 && echo started)" "1 started"

# ---------------------------------------------------------------- refuse

env_new claim-foreign
ready5; claim_json "$HOST_OTHER" "lab-2" "$(at -5)"
dispatch --once; CANCCU_NOW=$((NOW + 60)) dispatch --once
ok "refuse: another host's fresh claim: nothing starts, the claim is not written" eq "$(grep -c . "$FAKE/worker.log") $(edits)" "0 0"
ok "… nothing else is read either" not grep -q '^issue list -R example-org/web -s open -L 300' "$FAKE/gh.log"
ok "… said once in the log" eq "$(dlog "is claimed by host lab-2 ($HOST_OTHER)")" 1
ok "… in the snapshot" grep -qF "lab-2 ($HOST_OTHER)" <<<"$(jq -r '.pass.claim // ""' "$CANCCU_HOME/status.json")"
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "… and in canccu-status" grep -qF "CLAIMED BY ANOTHER HOST: lab-2 ($HOST_OTHER)" "$E/status"
claim_json "$HOST_OTHER" "lab-2" "$(at -1)"
CANCCU_NOW=$((NOW + 120)) dispatch --once
ok "… its renewal is not logged again" eq "$(dlog "is claimed by host lab-2")" 1
env_new claim-foreign-nolabel
claim_json "$HOST_OTHER" "" "$(at -5)"
dispatch --once
ok "refuse: a claim without a label names the host id" eq "$(dlog "is claimed by host $HOST_OTHER")" 1

env_new claim-dry
claim_json "$HOST_OTHER" "lab-2" "$(at -5)"
dispatch --dry-run
ok "dry run: reads the claim only, and says whose it is" eq "$(grep -c '^issue edit' "$FAKE/gh.log") $(grep -c "is claimed by host lab-2" "$E/out")" "0 1"

# ---------------------------------------------------------------- expiry and release

env_new claim-expired
ready5; claim_json "$HOST_OTHER" "lab-2" "$(at -30)"
dispatch --once
ok "expiry: another host's claim 30 minutes old (CLAIM_EXPIRY_MIN) is free: taken" eq "$(body | grep '^host:')" "host: $HOST_ME"
ok "… the take is logged, and the pass acts" eq "$(dlog "claim: took #99 (held by lab-2 ($HOST_OTHER), last written 2030-11-05T11:30:00Z)") $(started 5 && echo started)" "1 started"
env_new claim-expiry-min "CLAIM_EXPIRY_MIN=60"
claim_json "$HOST_OTHER" "lab-2" "$(at -45)"
dispatch --once
ok "expiry: CLAIM_EXPIRY_MIN=60 still refuses a claim 45 minutes old" eq "$(edits)" 0
env_new claim-released
ready5; claim_json "" "" "$(at -2)"
dispatch --once
ok "released: an empty host is free: taken at once" eq "$(body | grep '^host:') $(started 5 && echo started)" "host: $HOST_ME started"
env_new claim-lowest
claim_json "$HOST_OTHER" "lab-2" "$(at -5)" 120
jq --arg b "$(claim_body "$HOST_ME" "" "$(at 0)")" '. + [{number: 99, body: $b}]' "$FAKE/claim.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/claim.json"
ready5; dispatch --once
ok "two claim issues: the lowest-numbered one counts" started 5

env_new claim-release
claim_json "$HOST_ME" "" "$(at 0)"
loop
ok "release: a dispatcher that stops cleanly releases its claim" eq "$(body | grep -E '^(host|label):' | tr '\n' ' ')" "host:  label:  "
ok "… logged" eq "$(dlog 'claim: released #99')" 1
env_new claim-release-foreign
claim_json "$HOST_OTHER" "lab-2" "$(at 0)"
loop
ok "release: a claim that is not ours is never released" eq "$(edits)" 0

# ---------------------------------------------------------------- take-over

env_new claim-takeover
claim_json "$HOST_OTHER" "lab-2" "$(at -5)"
dispatch --take-over; rc=$?
ok "take-over: prints whose the claim is" grep -qF "#99 is held by lab-2 ($HOST_OTHER), last written 2030-11-05T11:55:00Z" "$E/out"
ok "… takes it, and exits 0" eq "$(body | grep '^host:') $rc" "host: $HOST_ME 0"
ok "… nothing else runs (no pass)" not grep -q '^issue list -R example-org/web -s open -L 300' "$FAKE/gh.log"
env_new claim-takeover-ours
dispatch --take-over
ok "take-over: our own claim: said so, written again" eq "$(grep -c 'this host holds #99' "$E/out") $(edits)" "1 1"
env_new claim-takeover-lag
echo '[]' > "$FAKE/claim.json"; echo 'lag:issue create' >> "$FAKE/routes"
dispatch --take-over; rc=$?
ok "take-over: no claim issue, the new one not listed yet (GitHub lags): it holds it, exit 0" \
  eq "$rc $(grep -c 'holds #900 now' "$E/out")" "0 1"
env_new claim-takeover-error
route 'issue list -R example-org/web -s open -l dispatcher-claim*' FAIL
dispatch --take-over; rc=$?
ok "take-over: a gh error takes nothing, exit 1" eq "$rc $(grep -c '^issue edit' "$FAKE/gh.log")" "1 0"

# ---------------------------------------------------------------- a gh error

env_new claim-gh-fresh
ready5; route 'issue list -R example-org/web -s open -l dispatcher-claim*' FAIL
mkdir -p "$CANCCU_HOME"; printf 'issue=99\nstate=ours\nwrote=%s\n' "$((NOW - 20 * 60))" > "$CANCCU_HOME/claim"
dispatch --once
ok "gh error: under our claim written 20 minutes ago the pass acts" started 5
ok "… and says until when" eq "$(dlog 'working on under this host'"'"'s claim until 2030-11-05T12:10:00Z')" 1
env_new claim-gh-expired
ready5; route 'issue list -R example-org/web -s open -l dispatcher-claim*' FAIL
mkdir -p "$CANCCU_HOME"; printf 'issue=99\nstate=ours\nwrote=%s\n' "$((NOW - 30 * 60))" > "$CANCCU_HOME/claim"
dispatch --once
ok "gh error: once our claim would have expired, nothing starts" eq "$(grep -c . "$FAKE/worker.log")" 0
ok "… said in the log" eq "$(dlog 'does nothing until the claim is read again')" 1
env_new claim-gh-never
ready5; route 'issue list -R example-org/web -s open -l dispatcher-claim*' FAIL
dispatch --once
ok "gh error: with no claim of ours ever written, nothing starts and nothing is written" \
  eq "$(grep -c . "$FAKE/worker.log") $(grep -cE '^issue (edit|create)' "$FAKE/gh.log")" "0 0"
env_new claim-gh-foreign
ready5; claim_json "$HOST_OTHER" "lab-2" "$(at -5)"
dispatch --once
route 'issue list -R example-org/web -s open -l dispatcher-claim*' FAIL
CANCCU_NOW=$((NOW + 60 * 60)) dispatch --once
ok "gh error: after a foreign claim was seen, a gh error never acts or takes it" \
  eq "$(grep -c . "$FAKE/worker.log") $(grep -cE '^issue (edit|create)' "$FAKE/gh.log")" "0 0"
env_new claim-write-fails
ready5; claim_json "$HOST_OTHER" "lab-2" "$(at -40)"; echo 'fail:issue edit' >> "$FAKE/routes"
dispatch --once
ok "gh error: a take whose write fails does not act" eq "$(grep -c . "$FAKE/worker.log")" 0

# a repo without the label: the create is tried again after the label is made
env_new claim-nolabel
ready5; echo '[]' > "$FAKE/claim.json"; echo 'fail:issue create' >> "$FAKE/routes"
dispatch --once
ok "claim: a failed create makes the label and tries again" eq "$(grep -c '^issue create ' "$FAKE/gh.log") $(grep -c '^label create dispatcher-claim' "$FAKE/gh.log")" "2 1"
# a create whose answer names no issue and a re-read that lists none: a gh error, not "claimed by host"
env_new claim-nourl
ready5; echo '[]' > "$FAKE/claim.json"; printf 'nourl:issue create\nlag:issue create\n' >> "$FAKE/routes"
dispatch --once
ok "claim: no issue to read back is a gh error" eq "$(dlog 'claimed by host')" 0
ok "… and nothing starts" not started 5

# ---------------------------------------------------------------- the queue and canccu-init

env_new claim-queue
{ issue 99 dispatcher-claim,ready; issue 98 dispatcher-claim; } | issues
dispatch --once
ok "queue: the claim issue is never runnable" not started 99
ok "… nor waiting for the product owner" not grep -q '"issue": 98' <<<"$(jq '.queue' "$CANCCU_HOME/status.json")"
ok "… the label is created where missing" not grep -q '^label create dispatcher-claim' "$FAKE/gh.log"
jq 'map(select(.name != "dispatcher-claim"))' "$FAKE/labels.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/labels.json"
dispatch --once
ok "… (created when missing)" has gh.log "label create dispatcher-claim -R example-org/web"

penv claim-init
json repoview.json '{"defaultBranchRef": {"name": "main"}}'; route 'repo view example-org/web*' repoview.json
claim_json "$HOST_OTHER" "lab-2" "$(at -5)"
PATH="$fb:$PATH" "$root/bin/canccu-init" web example-org/web > "$E/out" 2>&1; rc=$?
ok "canccu-init: a repo another host claims: a warning first" grep -qF "warning: example-org/web is claimed by host lab-2 ($HOST_OTHER)" "$E/out"
ok "… the project is still added" eq "$rc $([ -f "$CANCCU_ROOT/projects/web/config" ] && echo added)" "0 added"
penv claim-init-free
json repoview.json '{"defaultBranchRef": {"name": "main"}}'; route 'repo view example-org/web*' repoview.json
claim_json "$HOST_OTHER" "lab-2" "$(at -40)"
PATH="$fb:$PATH" "$root/bin/canccu-init" web example-org/web > "$E/out" 2>&1
ok "canccu-init: an expired claim: no warning" not grep -q "is claimed by" "$E/out"

echo "canccu-claim tests: $npass passed, $nfail failed"
(( nfail == 0 ))
