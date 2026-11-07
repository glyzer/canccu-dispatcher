#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-config.sh — no personal defaults: what the tools do while USER_LOGIN,
# REVIEWER_LOGIN or MODEL are unset (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- the defaults

defaults=$( (CANCCU_ROOT=/nonexistent; . "$root/lib/canccu-config.default"; echo "[$USER_LOGIN] [$REVIEWER_LOGIN] [$MODEL]") 2>&1)
tname=defaults
ok "USER_LOGIN, REVIEWER_LOGIN and MODEL default to empty" eq "$defaults" "[] [] []"

# ---------------------------------------------------------------- USER_LOGIN unset

env_new no-user USER_LOGIN=
{ issue 3 ready; issue 5 in-progress; } | issues
printf '%s\n' "$(pr 50 5 "$HA")" | prs
state 5 phase=check "check_at=$NOW" pr=50
dispatch --once
ok "no USER_LOGIN: the dispatcher says which key is missing" grep -q 'USER_LOGIN is not set' "$E/out"
dispatch --once
ok "… once over two passes" eq "$(grep -c 'USER_LOGIN is not set' "$CANCCU_HOME/dispatch.log")" 1
ok "… starts nothing" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… writes nothing to GitHub" not grep -qE '^(issue (edit|comment|close)|pr (edit|merge|comment)|label create)' "$FAKE/gh.log"
ok "… the snapshot says so" grep -q 'USER_LOGIN is not set' <<<"$(jq -r .pass.error "$CANCCU_HOME/status.json")"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --dry-run > "$E/out" 2>&1; rc=$?
ok "no USER_LOGIN: --dry-run refuses, naming the key" eq "$rc $(grep -c 'USER_LOGIN is not set' "$E/out")" "1 1"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)
ok "no USER_LOGIN: canccu-status names the missing key" grep -q '^USER_LOGIN is not set' <<<"$out"
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 2>&1); rc=$?
ok "no USER_LOGIN: canccu-ship refuses, naming the key" eq "$rc $(grep -c 'USER_LOGIN is not set' <<<"$out")" "1 1"
ok "… and merges nothing" not grep -q '^pr merge' "$FAKE/gh.log"
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 50 2>&1); rc=$?
ok "no USER_LOGIN: canccu-review refuses, naming the key" eq "$rc $(grep -c 'USER_LOGIN is not set' <<<"$out")" "1 1"
ok "… and starts no reviewer" eq "$(wc -l < "$FAKE/worker.log")" 0

# ---------------------------------------------------------------- REVIEWER_LOGIN unset

env_new no-reviewer REVIEWER_LOGIN= PING_KINDS=all
{ issue 3 ready; issue 5 in-progress; issue 8 needs-you; } | issues
p=$(pr 50 5 "$HA"); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=check "check_at=$NOW" pr=50
state 8 phase=needs-you
dispatch --once
ok "no REVIEWER_LOGIN: a worker still starts (it needs no reviewer)" started 3
ok "… no reviewer starts" not grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… the dispatcher says which key is missing" grep -q 'REVIEWER_LOGIN is not set' "$CANCCU_HOME/dispatch.log"
ok "… nothing is posted as the reviewer (no review, no ping)" not grep -qP '^(issue|pr) comment\treviewer' "$FAKE/gh.env"
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 50 2>&1); rc=$?
ok "no REVIEWER_LOGIN: canccu-review refuses, naming the key" eq "$rc $(grep -c 'REVIEWER_LOGIN is not set' <<<"$out")" "1 1"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)
ok "no REVIEWER_LOGIN: canccu-status names the missing key" grep -q 'REVIEWER_LOGIN is not set' <<<"$out"
ok "… and no reviewer login" grep -q '^model: the account default · reviews: REVIEWER_LOGIN is not set$' <<<"$out"

# ---------------------------------------------------------------- paths under $HOME, posted as ~/…

# every text the tool posts to GitHub shows a path under $HOME as ~/…: a needs-you that quotes a
# worker's report, a review that could not be posted (the token path), a ping, the digest
env_new home-paths "REVIEWER_TOKEN_FILE=/home/someone/.canccu/reviewer-token" PING_KINDS=all "DIGEST_HOUR_UTC=0"
{ issue 5 in-progress; issue 6 in-progress; } | issues
p=$(pr 50 6 "$HA"); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
state 5 phase=work "started=$NOW"
last 5 "crashed (exit 1)" "cannot read /home/someone/code/web/notes.txt; see /home/someone"
state 6 phase=review pr=50 review_sha=$HA "started=$NOW" rounds=0
last review-50 done "wrote the review"
RF=$CANCCU_HOME/reviews/50/$HA.md; mkdir -p "${RF%/*}"
printf '1. /home/someone/code/web/src/a.ts:3 off by one\n\nReview verdict: changes %s\n' "$HA" > "$RF"; touch -d "@$((NOW + 60))" "$RF"
HOME=/home/someone dispatch --once
ok "HOME=/home/someone: the needs-you comment quotes the report with ~/" has gh.log "cannot read ~/code/web/notes.txt; see ~"
ok "… the review-post failure names the token file as ~/" has gh.log "no reviewer token file (~/.canccu/reviewer-token)"
ok "… no posted text contains /home/" hasnt gh.log "/home/"
ok "… nor a posted body" eq "$(cat "$FAKE"/posted-* 2>/dev/null | grep -c /home/)" 0
# a posted review body: the token works, the reviewer cited an absolute path anyway
env_new home-review
{ issue 6 in-progress; } | issues
p=$(pr 50 6 "$HA"); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
state 6 phase=review pr=50 review_sha=$HA "started=$NOW" rounds=0
last review-50 done "wrote the review"
RF=$CANCCU_HOME/reviews/50/$HA.md; mkdir -p "${RF%/*}"
printf '1. /home/someone/code/web/src/a.ts:3 off by one\n\nReview verdict: changes %s\n' "$HA" > "$RF"; touch -d "@$((NOW + 60))" "$RF"
HOME=/home/someone dispatch --once
# shellcheck disable=SC2088  # a literal ~ is what the posted text holds
ok "HOME=/home/someone: a posted review shows ~/" grep -qF '~/code/web/src/a.ts:3' "$FAKE/posted-50"
ok "… and no /home/" not grep -q /home/ "$FAKE/posted-50" "$FAKE/gh.log"
ok "the reviewer prompt asks for paths relative to the repo root" grep -qF 'cite every file as a path relative to the repo root' <<<"$(lib review_prompt 50 5 x f high)"
ok "… the fix-check prompt too" grep -qF 'cite every file as a path relative to the repo root' <<<"$(lib fixcheck_prompt 50 5 a b f low "")"

# ---------------------------------------------------------------- messages point at this tool

tname=pointers
ok "no message points at another repo's installer, project or docs" \
  eq "$(grep -rnE '(echo|die|log|warn_once|exit|Text\().*(install\.sh|docs/canccu|profiles/ in the)' "$root/bin" "$root/libexec" "$root/lib" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')" ""

echo "canccu-config tests: $npass passed, $nfail failed"
(( nfail == 0 ))
