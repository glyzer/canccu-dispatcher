#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-repocheck.sh — repo_check, the read-only check of a target repo's prerequisites, and
# canccu-init --check that prints it (#17). Harness: tests/lib/harness.sh (its fake gh is GitHub).
#   bash tests/canccu-repocheck.sh    one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

D=https://github.com/glyzer/canccu-dispatcher/blob/main/docs
G=$root/templates/repo/.github
# rc_env <name> [config...]: project web whose repo has every piece; a test breaks one with route
# (its routes come before these)
rc_env() {
  env_new "$@"
  json perm.json '{"permission": "write"}'
  json var.json '{"name": "REVIEWER_LOGIN", "value": "review-bot"}'
  json ci.json '{"total_count": 1}'
  json rules.json '[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "CI"}, {"context": "review-gate"}]}}]'
  json prot.json '{"required_status_checks": {"contexts": [], "checks": []}}'
  json gate-script.json "{\"sha\": \"$("$FAKE_REAL_GIT" hash-object "$G/scripts/review-gate")\"}"
  json gate-wf.json "{\"sha\": \"$("$FAKE_REAL_GIT" hash-object "$G/workflows/review-gate.yml")\"}"
  printf '%s\t%s\n' \
    'api repos/example-org/web/collaborators/review-bot/permission *' perm.json \
    'api repos/example-org/web/actions/variables/REVIEWER_LOGIN *' var.json \
    'api repos/example-org/web/contents/.github/scripts/review-gate?ref=main *' gate-script.json \
    'api repos/example-org/web/contents/.github/workflows/review-gate.yml?ref=main *' gate-wf.json \
    'api repos/example-org/web/commits/main/check-runs?check_name=CI *' ci.json \
    'api repos/example-org/web/rules/branches/main *' rules.json \
    'api repos/example-org/web/branches/main/protection *' prot.json >> "$FAKE/routes.default"
}
check() { lib repo_check "$root"; }
# the text of each line of one state
lines() { check | awk -F '\t' -v s="$1" '$1 == s { sub(/^[^\t]*\t/, ""); print }'; }
initcheck() { out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --check web 2>&1); rc=$?; }
# reads: the gh calls since the last : > gh.log, none a write
writes() { grep -E -- ' -X | --method | -f | -F |^label create' "$FAKE/gh.log"; }

# ---------------------------------------------------------------- every piece there

rc_env repocheck-good
ok "every piece there: no line" eq "$(check)" ""
ok "… the protection is not read when the rules have every check" not grep -q 'branches/main/protection' "$FAKE/gh.log"
ok "… every call a read" eq "$(writes)" ""
initcheck
ok "--check: nothing missing exits 0" eq "$rc" 0
ok "… the summary line" grep -qxF "repo example-org/web: 0 missing, 0 unknown" <<<"$out"
ok "… then the Telegram check as before" grep -qxF "NOTIFY=github: nothing to check for Telegram" <<<"$out"
ok "… no write on the way" eq "$(writes)" ""

# ---------------------------------------------------------------- each row missing

rc_env repocheck-noreach; mkdir -p "$CANCCU_HOME/gh"; printf 'github.com:\n    oauth_token: t\n' > "$CANCCU_HOME/gh/hosts.yml"
touch "$CANCCU_HOME/gh/noreach"
ok "repo: a 404 is missing, word for word, and nothing else is checked" eq "$(check)" \
  "missing	the repo example-org/web is not reachable with this project's gh login: $D/reference/projects.md#a-narrow-token-per-project"
ok "… one gh call" eq "$(grep -c . "$FAKE/gh.log")" 1
rm "$CANCCU_HOME/gh/noreach"; touch "$CANCCU_HOME/gh/down"
ok "repo: no answer is unknown, and ends it too" eq "$(check)" \
  "unknown	repo: unknown (dial tcp: lookup api.github.com: no such host)"
initcheck
ok "--check: only unknown exits 0" eq "$rc $(grep -c '^repo example-org/web: 0 missing, 1 unknown$' <<<"$out")" "0 1"

rc_env repocheck-bot; json perm.json '{"permission": "read"}'
ok "bot: read access is missing, word for word" eq "$(lines missing)" \
  "review-bot has no write access to example-org/web: add it as a collaborator and accept the invitation as the bot: $D/repo-contract.md"
json perm.json '{"permission": "admin"}'
ok "bot: admin passes" eq "$(check)" ""
route 'api repos/example-org/web/collaborators/*' NOTFOUND
ok "bot: a 404 is missing" grep -q '^review-bot has no write access' <<<"$(lines missing)"
: > "$FAKE/routes"; route 'api repos/example-org/web/collaborators/*' FAIL
ok "bot: another failure is unknown, gh's error cut to 80" eq "$(check)" "unknown	bot: unknown (fake gh: failing api repos/example-org/web/collaborators/review-bot/permission -…)"

rc_env repocheck-var; route 'api repos/example-org/web/actions/variables/*' NOTFOUND
ok "variable: a 404 is missing, word for word" eq "$(lines missing)" "the repo variable REVIEWER_LOGIN is not set: $D/repo-contract.md"
: > "$FAKE/routes"; json var.json '{"name": "REVIEWER_LOGIN", "value": "other-bot"}'
ok "variable: another value is missing, word for word" eq "$(lines missing)" "the repo variable REVIEWER_LOGIN is other-bot, not review-bot: $D/repo-contract.md"
route 'api repos/example-org/web/actions/variables/*' FAIL
ok "variable: another failure is unknown (the narrow token reads no variables)" grep -q '^variable: unknown (' <<<"$(lines unknown)"
initcheck
ok "--check: unknown lines never fail it" eq "$rc" 0

rc_env repocheck-nobot REVIEWER_LOGIN=
ok "REVIEWER_LOGIN empty: one missing line instead of bot and variable" eq "$(check)" \
  "missing	REVIEWER_LOGIN is not set ($(lib login_where)): $D/getting-started.md"
ok "… neither is read" not grep -qE 'collaborators|actions/variables' "$FAKE/gh.log"

rc_env repocheck-gate; route 'api repos/example-org/web/contents/.github/scripts/*' NOTFOUND
ok "review gate: a file not on the base branch is missing, word for word" eq "$(lines missing)" \
  ".github/scripts/review-gate is not on main: copy it from templates/repo/.github/: $D/repo-contract.md"
: > "$FAKE/routes"; json gate-wf.json '{"sha": "0000000000000000000000000000000000000000"}'
ok "review gate: a changed file is a note, word for word" eq "$(check)" \
  "note	.github/workflows/review-gate.yml differs from this version's template (changed by you, or older)"
initcheck
ok "--check: a note never fails it" eq "$rc $(grep -c '^repo: .github/workflows/review-gate.yml differs' <<<"$out")" "0 1"
route 'api repos/example-org/web/contents/*' FAIL
ok "review gate: another failure is unknown" eq "$(lines unknown | cut -d'(' -f1 | tr '\n' '|')" \
  "review gate .github/scripts/review-gate: unknown |review gate .github/workflows/review-gate.yml: unknown |"
rc_env repocheck-gate-base BASE_BRANCH=trunk
ok "review gate: read on BASE_BRANCH" grep -q 'contents/.github/scripts/review-gate?ref=trunk' <<<"$(check; cat "$FAKE/gh.log")"

rc_env repocheck-ci; json ci.json '{"total_count": 0}'
ok "CI: no check run is missing, word for word" eq "$(lines missing)" "no check named CI on the latest commit of main: $D/repo-contract.md"
initcheck
ok "--check: one missing exits 1" eq "$rc" 1
ok "… each line as repo: <text>" grep -qxF "repo: no check named CI on the latest commit of main: $D/repo-contract.md" <<<"$out"
ok "… the summary counts it" grep -qxF "repo example-org/web: 1 missing, 0 unknown" <<<"$out"
ok "… the Telegram check still runs" grep -qF "nothing to check for Telegram" <<<"$out"
: > "$FAKE/routes"; route 'api repos/example-org/web/commits/*' FAIL
ok "CI: another failure is unknown" grep -q '^CI: unknown (' <<<"$(lines unknown)"

# ---------------------------------------------------------------- the required checks

rc_env repocheck-req-prot
json rules.json '[]'
json prot.json '{"required_status_checks": {"contexts": ["CI"], "checks": [{"context": "review-gate"}]}}'
ok "required: found in the protection only" eq "$(check)" ""
json prot.json '{"required_status_checks": {"contexts": ["CI"], "checks": []}}'
json rules.json '[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "review-gate"}]}}]'
ok "required: one in the rules, the other in the protection" eq "$(check)" ""
json rules.json '[]'; route 'api repos/example-org/web/branches/main/protection *' NOTFOUND
ok "required: in neither (no protection) is missing, word for word, per check" eq "$(lines missing)" \
  "the check CI is not required on main: add it to a ruleset: $D/repo-contract.md
the check review-gate is not required on main: add it to a ruleset: $D/repo-contract.md"
ok "… the protection read once" eq "$(: > "$FAKE/gh.log"; check >/dev/null; grep -c 'branches/main/protection' "$FAKE/gh.log")" 1
: > "$FAKE/routes"; route 'api repos/example-org/web/branches/main/protection *' FAIL
ok "required: not in the rules and the protection unreadable is unknown" eq "$(lines unknown | cut -d'(' -f1 | tr '\n' '|')" \
  "required CI: unknown |required review-gate: unknown |"
ok "… never missing" eq "$(lines missing)" ""
rc_env repocheck-req-words "REVIEW_CHECKS='review-gate deep-check'"
ok "required: every word of REVIEW_CHECKS" eq "$(lines missing)" "the check deep-check is not required on main: add it to a ruleset: $D/repo-contract.md"

# ---------------------------------------------------------------- auto-merge and labels

rc_env repocheck-am; json repo.json '{"allow_auto_merge": false}'
ok "auto-merge off is a note, word for word" eq "$(check)" "note	auto-merge is off: the dispatcher merges directly"
json repo.json '{"allow_auto_merge": true}'
ok "auto-merge on: no line" eq "$(check)" ""

rc_env repocheck-labels; echo '[{"name": "ready"}, {"name": "blocked"}]' > "$FAKE/labels.json"
ok "labels: the absent ones are missing, word for word" eq "$(lines missing)" \
  "labels missing: in-progress, epic, needs-you, plan-ok, awaiting-accept, needs-work, accepted, manual-accept, checkpoint, checkpoint-ok, fast, security, follow-up, dispatcher-claim (canccu-dispatch creates them on its next pass)"
ok "… read with label list -R <repo> -L 300 --json name" grep -qx 'label list -R example-org/web -L 300 --json name' "$FAKE/gh.log"
: > "$FAKE/gh.log"; initcheck
ok "--check: never creates a label" eq "$(writes)" ""
route 'label list*' FAIL
ok "labels: a failed list is unknown" grep -q '^labels: unknown (' <<<"$(lines unknown)"

# ---------------------------------------------------------------- the order, and Telegram

rc_env repocheck-order REVIEWER_LOGIN=; json ci.json '{"total_count": 0}'; json repo.json '{"allow_auto_merge": false}'
json rules.json '[]'; echo '[]' > "$FAKE/labels.json"; route 'api repos/example-org/web/contents/*' NOTFOUND
ok "the rows in the issue's order" eq "$(check | cut -f2 | cut -c1-20 | tr '\n' '|')" \
  "REVIEWER_LOGIN is no|.github/scripts/revi|.github/workflows/re|no check named CI on|the check CI is not |the check review-gat|auto-merge is off: t|labels missing: read|"
ok "… every call a read" eq "$(writes)" ""

rc_env repocheck-tg NOTIFY=telegram TELEGRAM_CHAT_ID=-1009876 "TELEGRAM_TOKEN_FILE=$T/repocheck-tg/telegram-token"
initcheck
ok "--check: the Telegram check failing exits 1 with the repo all there" eq "$rc $(grep -c '^repo example-org/web: 0 missing, 0 unknown$' <<<"$out")" "1 1"

echo "canccu-repocheck tests: $npass passed, $nfail failed"
(( nfail == 0 ))
