#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-asks.sh — the ask form's safety and the ping's retries (#295; the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

review() {
  local d="$CANCCU_HOME/reviews/$1"; mkdir -p "$d"
  { (( $# > 2 )) && { echo "Change:"; printf '%s\n' "${@:3}"; }; echo "Blocking:"; echo "none"; echo "Review verdict: pass $2"; } > "$d/$2.md"
}
SA=${HA:0:7} SB=${HB:0:7}
form() { lib eval "PRS=\$(cat '$FAKE/prs.json'); ISSUES='[]'; $1"; }

env_new ask-strip
pr 50 5 $HA green | prs
review 50 $HA '- See [x](//evil.example/a) now.' '- Visit www.evil.example/b and ![i](https://x.example/p.png) here.' "- Path $HOME/secret is here."
OUT=$(form "ask_form 12 checkpoint 50 3")
ok "ask form: a protocol-relative link is stripped from the change lines" not grep -q 'evil.example/a' <<<"$OUT"
ok "… and a www autolink and an image" not grep -qE 'evil.example/b|x.example|!\[' <<<"$OUT"
ok "… the words around them stay" eq "$(sed -n 4p <<<"$OUT")" "  - See [x]() now."
env_new ask-why-strip
pr 50 5 $HA green | prs
state 5 phase=accept pr=50 accept_sha=$HA pass_sha=$HA "reason=manual: users see it: @scope/pkg www.evil.example"
OUT=$(form "ask_form 5 accept 50")
ok "Why you: the stored accept reason is stripped of mentions and links" eq "$(grep '^Why you:' <<<"$OUT")" "Why you: users see it: /pkg"

env_new ask-head-file
pr 50 5 $HB green | prs
review 50 $HB '- B one.' '- B two.' '- B three.'
review 50 $HA '- A one.' '- A two.' '- A three.'
touch -d '2030-01-01' "$CANCCU_HOME/reviews/50/$HB.md"
OUT=$(form "ask_form 5 checkpoint 50 3")
ok "ask form: the change lines come from the review file of the head shown, not the newest file" eq "$(sed -n 4p <<<"$OUT")" "  - B one."

env_new ask-pass-old
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 $HB green | prs
state 5 phase=accept pr=50 accept_sha=$HB pass_sha=$HA
OUT=$(form "ask_form 5 accept 50")
ok "a pass on an older head is not shown next to the new head, and is not recommended" \
  eq "$(grep -E '^(Review|Recommended):' <<<"$OUT")" "Review: none · CI: green
Recommended: do not accept, no review passed"

env_new ask-block
{ issue 5 in-progress,awaiting-accept; } | issues
PR_LINES=0 pr 50 5 $HA green "" false "stale snapshot body" | prs
state 5 phase=accept pr=50 accept_sha=$HA
printf 'fresh body edited in this pass\n' > "$FAKE/prbody-50"; touch -d '+1 hour' "$FAKE/prbody-50"
ok "ask_block builds on the fresh body, not the snapshot's" \
  eq "$(lib eval "PRS=\$(cat '$FAKE/prs.json'); ISSUES='[]'; ask_block 5 50 'Accept: x'" >/dev/null; tail -1 "$FAKE/prbody-50")" "fresh body edited in this pass"
rm -f "$FAKE/prbody-50"
state 5 ask_sha=
echo 'fail:pr body' >> "$FAKE/routes"
lib eval "PRS=\$(cat '$FAKE/prs.json'); ISSUES='[]'; ask_block 5 50 'Accept: x'" >/dev/null
ok "ask_block writes nothing when the body cannot be read" eq "$(grep -c '^pr edit' "$FAKE/gh.log")" 1
ok "… the ask_sha is not kept" eq "$(lib eval "st_get 5 ask_sha")" ""

env_new ask-ping-timeouts PING_KINDS=all
touch "$FAKE/comment-urls"
{ issue 5 in-progress,needs-you; } | issues
state 5 phase=needs-you "ny_at=$NOW" "reason=x"
dispatch --once
state 5 phase=needs-you "ny_at=$NOW" "reason=plan ready for OK" ny_kind=plan
echo 'fail124:api patch' >> "$FAKE/routes"
dispatch --once
ok "a timed-out edit keeps the old kind recorded, so it is tried again" eq "$(cat "$CANCCU_HOME/pings/5")" "needs-you 5"
sed -i '/fail124:api patch/d' "$FAKE/routes"
dispatch --once
ok "… and the next pass edits the comment" eq "$(cat "$CANCCU_HOME/pings/5")" "plan 5"

env_new ask-post-timeout PING_KINDS=all
{ issue 5 in-progress,needs-you; } | issues
state 5 phase=needs-you "ny_at=$NOW" "reason=x"
jq -n --arg m "$(lib eval 'echo "$CANCCU_MARK"')" '[{id: 777, user: {login: "review-bot"}, created_at: "2030-11-05T12:00:00Z", body: ("@octo\nx\n\n" + $m)}]' > "$FAKE/c5.json"
route 'api repos/example-org/web/issues/5/comments*' c5.json
echo 'fail124:issue comment' >> "$FAKE/routes"
dispatch --once
ok "a post that timed out is recorded with the id found on the issue" eq "$(cat "$CANCCU_HOME/pings/5" 2>/dev/null)" "needs-you 777"

env_new ask-close-kept PING_KINDS=all
{ issue 5 in-progress,needs-you; issue 6 in-progress,needs-you; } | issues
state 5 phase=needs-you "ny_at=$NOW" "reason=x"
mkdir -p "$CANCCU_HOME/pings"; echo "needs-you 55" > "$CANCCU_HOME/pings/9"
echo 'fail:issue comment' >> "$FAKE/routes"
state 6 phase=needs-you "ny_at=$NOW" "reason=x"
dispatch --once
ok "a settled item's record stays when a failed post stopped the pass (its close was skipped)" test -e "$CANCCU_HOME/pings/9"
ok "ping: no form is rendered after a failed post stopped the pass" eq "$(grep -c '^issue comment' "$FAKE/gh.log")" 1

env_new ask-no-auto-merge
{ issue 5 in-progress,awaiting-accept; } | issues
pr 50 5 $HA green | prs
state 5 phase=accept pr=50 accept_sha=$HA pass_sha=$HA
echo '{"allow_auto_merge": false}' > "$FAKE/repo.json"
OUT=$(form "ask_form 5 accept 50")
ok "the accept line of the form leaves canccu-ship out in a repo without auto-merge" \
  eq "$(sed -n 1p <<<"$OUT")" 'For the product owner: PR #50 waits for your accept: label it `accepted`.'
echo '{"allow_auto_merge": true}' > "$FAKE/repo.json"
OUT=$(form "ask_form 5 accept 50")
ok "… and offers it where auto-merge is allowed" eq "$(sed -n 1p <<<"$OUT")" 'For the product owner: PR #50 waits for your accept: label it `accepted`, or `canccu-ship 5`.'

echo "canccu-asks tests: $npass passed, $nfail failed"
(( nfail == 0 ))
