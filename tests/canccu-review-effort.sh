#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-review-effort.sh — the full review's effort by a package's risk class and by
# EFFORT_DOCS_PATHS, and the reviewer's model by kind (REVIEW_MODEL, FIXCHECK_MODEL,
# REVIEW_MODEL_LIGHT). Kept apart from tests/canccu-review.sh so each file stays well under CI's
# per-file time limit (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- effort by risk class

# with a class: low and normal → medium, high → high; agent configuration and gated paths stay high
env_new effort-pure
ef() { lib review_effort_pure "$1" "${2:-}" "${3:-}"; }
ok "risk low, plain feature code → medium" eq "$(ef $'src/a.ts\t500' 'Tier: feature' low)" medium
ok "risk normal, a risky path → medium" eq "$(ef $'src/auth/session.ts\t40' 'Tier: feature' normal)" medium
ok "risk high, docs only → high" eq "$(ef $'docs/x.md\t3' 'Tier: fix' high)" high
ok "risk low, agent configuration → high" eq "$(ef $'CLAUDE.md\t3' 'Tier: fix' low)" high
ok "risk normal, a gated path → high" eq "$(ef $'setup/host.sh\t3' 'Tier: fix' normal)" high
ok "risk low, no files (gh error) → high" eq "$(ef '' 'Tier: fix' low)" high
ok "an unknown class counts as none (by the paths) → high" eq "$(ef $'src/a.ts\t500' 'Tier: feature' bogus)" high

# EFFORT_DOCS_PATHS (the web project's rules: contracts/) count as docs, though RISKY_PATHS names them
ok "no class, contracts only → medium" eq "$(ef $'contracts/screen.yaml\t400' 'Tier: feature')" medium
ok "no class, contracts and docs → medium" eq "$(ef $'contracts/screen.yaml\t400\ndocs/x.md\t9' 'Tier: feature')" medium
ok "no class, contracts and a small fix → medium" eq "$(ef $'src/a.ts\t3\ncontracts/screen.yaml\t2' 'Tier: fix')" medium
ok "no class, a small fix and a long contract: the contract's lines don't count → medium" \
  eq "$(ef $'src/a.ts\t3\ncontracts/screen.yaml\t400' 'Tier: fix')" medium
ok "a \$-anchored EFFORT_DOCS_PATHS: the docs lines don't count toward the fix-tier 100 → medium" \
  eq "$(lib eval "EFFORT_DOCS_PATHS='\\.ya?ml\$'; review_effort_pure \$'contracts/a.yaml\t400\nsrc/a.ts\t3' 'Tier: fix'")" medium
ok "no class, contracts and feature code → high" eq "$(ef $'src/a.ts\t3\ncontracts/screen.yaml\t2' 'Tier: feature')" high
ok "no class, contracts and another risky path → high" eq "$(ef $'src/auth/a.ts\t3\ncontracts/screen.yaml\t2' 'Tier: fix')" high
# docs/ and *.md count as docs before RISKY_PATHS: a risky word in a docs file name is no risk
ok "docs only, 'session' in an svg name → medium" eq "$(ef $'docs/briefs/step-7/05-sessions.svg\t300' 'Tier: feature')" medium
ok "docs only, 'rights' in a docs name → medium" eq "$(ef $'docs/briefs/13-settings-and-rights.svg\t9\ndocs/x.md\t2' 'Tier: feature')" medium
ok "a risky word in a Markdown name → medium" eq "$(ef $'notes/auth-session.md\t30' 'Tier: feature')" medium
ok "docs with a risky name plus a risky code path → high" eq "$(ef $'docs/05-sessions.svg\t3\nsrc/auth/a.ts\t2' 'Tier: fix')" high
# many risky paths: under pipefail a pipe into grep -q loses the match at random (SIGPIPE)
ok "300 risky paths of 0 lines, Tier: fix, 20 times under pipefail → always high" \
  eq "$(lib eval "set -o pipefail; s=\$(for i in \$(seq 300); do printf 'src/auth/module-%s.ts\t0\n' \$i; done); for n in \$(seq 20); do review_effort_pure \"\$s\" 'Tier: fix'; done | sort | uniq -c | tr -s ' '")" " 20 high"
ok "no EFFORT_DOCS_PATHS: contracts are a risky path again → high" \
  eq "$(lib eval "EFFORT_DOCS_PATHS=; review_effort_pure \$'contracts/screen.yaml\t2' 'Tier: fix'")" high
ok "EFFORT_DOCS_PATHS never lightens a gated path" \
  eq "$(lib eval "EFFORT_DOCS_PATHS='^setup/'; review_effort_pure \$'setup/x.md\t2' 'Tier: fix'")" high
ok "an invalid EFFORT_DOCS_PATHS fails closed → high" \
  eq "$(lib eval "EFFORT_DOCS_PATHS='('; review_effort_pure \$'docs/x.md\t2' 'Tier: fix' 2>/dev/null")" high
ok "… and a docs-only diff is still medium with a valid one" \
  eq "$(lib eval "EFFORT_DOCS_PATHS='^contracts/'; review_effort_pure \$'contracts/a.yaml\t2' 'Tier: fix'")" medium
lib eval "EFFORT_DOCS_PATHS='('; review_effort_pure \$'docs/x.md\t2' 'Tier: fix'" >/dev/null 2>&1
ok "… with a warning in the log" grep -q 'EFFORT_DOCS_PATHS' "$CANCCU_HOME/dispatch.log"
ok "the default rules template leaves EFFORT_DOCS_PATHS commented out" grep -qx "# EFFORT_DOCS_PATHS=''" "$root/profiles/default/rules"
ok "… and it defaults to empty" eq "$( . "$root/lib/canccu-config.default"; echo "[$EFFORT_DOCS_PATHS]")" "[]"

# review_effort <pr> <unit>: a package's class is the highest of the plan, the PR's Risk: line and
# the reviewer; the health pass is high when it touches HIGH_RISK_PATHS
# pkgenv <name> <unit> <files json> <pr body> <state...>: the unit (package a or the health pass) with PR #50
pkgenv() {
  env_new "$1"; U=$2; local f=$3 b=$4; shift 4
  { issue 101 in-progress; } | issues
  p=$(PR_BRANCH=101-issue-101 pr 50 101 "$HA" green "" false "$b"); printf '%s\n' "$p" | prs
  json files50.json "$f"; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  state "$U" step=12 wave=1 members=101 branch=101-issue-101 phase=check pr=50 "$@"
}
reff() { lib eval "fetch; review_effort 50 $U"; }
pkgenv eff-pkg-normal 101 '[{"filename": "src/auth/session.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=normal
ok "package rated normal, a risky path → medium" eq "$(reff)" medium
pkgenv eff-pkg-high 101 '[{"filename": "docs/x.md", "changes": 3}]' 'Tier: fix' pkg=a risk=high
ok "package rated high, docs only → high" eq "$(reff)" high
pkgenv eff-pkg-prrisk 101 '[{"filename": "src/a.ts", "changes": 3}]' $'Tier: fix\nRisk: high — touches the session' pkg=a risk=low
ok "the PR's Risk: high raises a low package → high" eq "$(reff)" high
pkgenv eff-pkg-reviewer 101 '[{"filename": "src/a.ts", "changes": 3}]' 'Tier: fix' pkg=a risk=low review_risk=high
ok "an earlier review's Risk: high counts → high" eq "$(reff)" high
pkgenv eff-pkg-comment 101 '[{"filename": "src/a.ts", "changes": 3}]' 'Tier: fix' pkg=a risk=low
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z $'ok\nRisk: high — sessions\nReview verdict: pass '"$HA")")"; route 'pr view 50 *' pr50.json
ok "the reviewer's Risk: high in the PR comments counts (as classify reads it) → high" eq "$(reff)" high
pkgenv eff-pkg-gated 101 '[{"filename": ".github/workflows/ci.yml", "changes": 3}]' 'Tier: fix' pkg=a risk=low
ok "package rated low, a gated path → high" eq "$(reff)" high
pkgenv eff-health pkg-12-health '[{"filename": "contracts/screen.yaml", "changes": 3}]' 'Tier: fix' pkg=health health=1 members= risk=normal
ok "the health pass touching HIGH_RISK_PATHS → high" eq "$(reff)" high
pkgenv eff-health-plain pkg-12-health '[{"filename": "src/a.ts", "changes": 300}]' 'Tier: feature' pkg=health health=1 members= risk=normal
ok "the health pass, plain code → medium" eq "$(reff)" medium
pkgenv eff-single 101 '[{"filename": "src/auth/session.ts", "changes": 3}]' 'Tier: fix'
ok "a single issue (no class): by the paths → high" eq "$(reff)" high

# REVIEW_LIGHT (#216 D3): a package of class low or normal gets a light review
lrc() { lib eval "fetch; REVIEW_LIGHT=${1:-1}; review_light_class 50 $U && echo light || echo full"; }
pkgenv light-normal 101 '[{"filename": "src/a.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=normal
ok "REVIEW_LIGHT=1, a normal package → light, its class printed" eq "$(lrc)" "normal
light"
ok "… REVIEW_LIGHT=0 → full" eq "$(lrc 0)" full
pkgenv light-asked 101 '[{"filename": "src/a.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=normal review_asked=1
ok "… a full review asked for → full" eq "$(lrc)" full
pkgenv light-high 101 '[{"filename": "src/a.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=high
ok "… a high package → full" eq "$(lrc)" full
pkgenv light-gated 101 '[{"filename": ".github/workflows/ci.yml", "changes": 3}]' 'Tier: fix' pkg=a risk=low
ok "… a gated path → full" eq "$(lrc)" full
pkgenv light-agent 101 '[{"filename": "src/a.ts", "changes": 3}, {"filename": "src/CLAUDE.md", "changes": 3}]' 'Tier: fix' pkg=a risk=low
ok "… agent configuration → full" eq "$(lrc)" full
pkgenv light-health pkg-12-health '[{"filename": "src/a.ts", "changes": 300}]' 'Tier: feature' pkg=health health=1 members= risk=normal
ok "… the health pass → full" eq "$(lrc)" full
pkgenv light-single 101 '[{"filename": "src/a.ts", "changes": 3}]' 'Tier: fix'
ok "… a single issue (the fast lane) → full" eq "$(lrc)" full
pkgenv light-dispatch 101 '[{"filename": "src/auth/session.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=normal "check_at=$NOW"
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
echo "REVIEW_LIGHT=1" >> "$CANCCU_HOME/rules"; echo "HIGH_RISK_TEXT='auth & sessions'" >> "$CANCCU_HOME/rules"
dispatch --once
ok "a light review runs at low effort" eq "$(cat "$CANCCU_HOME/reviews/50.effort") $(cat "$CANCCU_HOME/reviews/50.light")" "low $HA"
ok "… logged" grep -qF 'PR #50: light review (REVIEW_LIGHT=1, normal risk, low effort)' "$CANCCU_HOME/dispatch.log"
ok "… on the light prompt" grep -q 'review#50 .*This is a light review: do not run the code-review skill' "$FAKE/worker.log"
# bash 5.2's patsub_replacement would turn an unquoted replacement's & into the pattern
ok "… HIGH_RISK_TEXT with an & goes into the checklist as written" grep -qF 'or risky code (auth & sessions) makes your Risk: line high' "$FAKE/worker.log"
# the PR's files are read once for both light checks (REVIEW_MODEL_LIGHT's and REVIEW_LIGHT's);
# a light review needs no review_effort, so not once more for its sizes
pkgenv light-files-once 101 '[{"filename": "src/auth/session.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=normal "check_at=$NOW"
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
echo "REVIEW_LIGHT=1" >> "$CANCCU_HOME/rules"; echo "REVIEW_MODEL_LIGHT=claude-light-x" >> "$CANCCU_HOME/config"
dispatch --once
ok "… the PR's files read once for both light checks" \
  eq "$(grep -c 'This is a light review' "$FAKE/worker.log") $(grep -c '^api --paginate repos/example-org/web/pulls/50/files' "$FAKE/gh.log")" "1 1"

# through a pass: a package rated normal gets a medium review although it touches a risky path
pkgenv eff-pkg-dispatch 101 '[{"filename": "src/auth/session.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=normal "check_at=$NOW"
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
dispatch --once
ok "a normal-risk package's review runs at medium effort" grep -q 'review#50 .*Run the code-review skill at medium effort' "$FAKE/worker.log"
ok "… recorded" eq "$(cat "$CANCCU_HOME/reviews/50.effort")" medium

# REVIEW_EFFORT_MAX caps every review and fix-check effort, gated paths and no files included
env_new effort-cap
cap() { lib eval "REVIEW_EFFORT_MAX=$1; $2"; }
ok "cap medium: a code diff that is high → medium capped" \
  eq "$(cap medium "review_effort_pure \$'src/a.ts\t500' 'Tier: feature'")" "medium capped"
ok "cap medium: a gated path → medium capped" \
  eq "$(cap medium "review_effort_pure \$'.github/workflows/ci.yml\t3' 'Tier: fix'")" "medium capped"
ok "cap medium: agent configuration → medium capped" \
  eq "$(cap medium "review_effort_pure \$'CLAUDE.md\t3' 'Tier: fix'")" "medium capped"
ok "cap medium: no files → medium capped" eq "$(cap medium "review_effort_pure '' 'Tier: fix'")" "medium capped"
ok "cap medium: a package rated high → medium capped" \
  eq "$(cap medium "review_effort_pure \$'docs/x.md\t3' 'Tier: fix' high")" "medium capped"
ok "cap medium never raises: a docs-only diff stays medium, not capped" \
  eq "$(cap medium "review_effort_pure \$'docs/x.md\t3' 'Tier: fix'")" medium
ok "cap high: high stays high, not capped" eq "$(cap high "review_effort_pure \$'src/a.ts\t500' 'Tier: feature'")" high
ok "cap low: a docs-only diff → low capped" eq "$(cap low "review_effort_pure \$'docs/x.md\t3' 'Tier: fix'")" "low capped"
ok "cap low: a fix-check diff over FIXCHECK_BIG → low capped" \
  eq "$(cap low "fixcheck_effort_pure \$'400\t1\tsrc/a.ts'")" "low capped"
ok "cap low: a small fix-check diff stays low, not capped" eq "$(cap low "fixcheck_effort_pure \$'1\t1\tsrc/a.ts'")" low
ok "cap medium: a fix-check with no lines stays medium" eq "$(cap medium "fixcheck_effort_pure ''")" medium
ok "an invalid cap is ignored: high stays high" eq "$(cap fast "review_effort_pure \$'src/a.ts\t500' 'Tier: feature'")" high
ok "… and a fix-check's medium stays medium" eq "$(cap fast "fixcheck_effort_pure \$'400\t1\tsrc/a.ts'")" medium
ok "… with one warning in the log" eq "$(grep -c 'REVIEW_EFFORT_MAX is not low, medium, high, xhigh or max (fast): ignored' "$CANCCU_HOME/dispatch.log")" 1
env_new effort-cap-top
ok "cap xhigh: max → xhigh capped" eq "$(cap xhigh "effort_cap max")" "xhigh capped"
ok "cap xhigh: high stays high, not capped" eq "$(cap xhigh "effort_cap high")" high
ok "cap max: xhigh stays xhigh, not capped" eq "$(cap max "effort_cap xhigh")" xhigh
ok "… and neither cap warns" eq "$(cat "$CANCCU_HOME/dispatch.log" 2>/dev/null | grep -c "REVIEW_EFFORT_MAX is not")" 0
ok "REVIEW_EFFORT_MAX defaults to empty" eq "$( . "$root/lib/canccu-config.default"; echo "[$REVIEW_EFFORT_MAX]")" "[]"

# a reviewer started under the cap: the effort file says so, the prompt names the effort only
effenv effort-cap-start '[{"filename": "src/a.ts", "changes": 500}]' 'Tier: feature'
echo "REVIEW_EFFORT_MAX=medium" >> "$CANCCU_HOME/config"
dispatch --once
ok "a capped review's prompt names medium" grep -q 'review#50 .*Run the code-review skill at medium effort on the diff' "$FAKE/worker.log"
ok "… recorded as medium (capped)" eq "$(cat "$CANCCU_HOME/reviews/50.effort" 2>/dev/null)" "medium (capped)"
ok "… and logged with the effort word" grep -qF "#5 PR #50: reviewer started at ${HA:0:7} (medium effort," "$CANCCU_HOME/dispatch.log"

# ---------------------------------------------------------------- model by kind

ok "REVIEW_MODEL and FIXCHECK_MODEL default to empty (MODEL)" \
  eq "$( . "$root/lib/canccu-config.default"; echo "[$REVIEW_MODEL][$FIXCHECK_MODEL]")" "[][]"
ok "review_model: each kind falls back to MODEL" \
  eq "$(lib eval 'MODEL=m0 REVIEW_MODEL= FIXCHECK_MODEL=; echo "$(review_model review) $(review_model fixcheck)"')" "m0 m0"
ok "review_model: each kind its own" \
  eq "$(lib eval 'MODEL=m0 REVIEW_MODEL=m1 FIXCHECK_MODEL=m2; echo "$(review_model review) $(review_model fixcheck)"')" "m1 m2"

effenv model-review '[{"filename": "src/a.ts", "changes": 12}]' 'Tier: fix'
echo "REVIEW_MODEL=claude-review-x" >> "$CANCCU_HOME/config"
dispatch --once
ok "a full review runs on REVIEW_MODEL" grep -q -- '^--quiet --model claude-review-x .*--name review#50 ' "$FAKE/worker.log"
ok "… recorded" eq "$(cat "$CANCCU_HOME/reviews/50.model" 2>/dev/null)" claude-review-x
ok "… and logged" grep -qF "#5 PR #50: reviewer started at ${HA:0:7} (medium effort, claude-review-x)" "$CANCCU_HOME/dispatch.log"
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "canccu-status shows the running review's effort and model" grep -q '^  review PR #50 (medium · claude-review-x) ' "$E/status"

effenv model-none '[{"filename": "src/a.ts", "changes": 12}]' 'Tier: fix'
dispatch --once
ok "no model set: the review gets no --model" not grep -q -- '--model' "$FAKE/worker.log"
ok "… logged as the account default" grep -qF "#5 PR #50: reviewer started at ${HA:0:7} (medium effort, the account default)" "$CANCCU_HOME/dispatch.log"
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "… canccu-status shows the effort alone" grep -q '^  review PR #50 (medium) ' "$E/status"

# ---------------------------------------------------------------- the light reviewer (#151)

env_new light-pure
lp() { lib eval "$1; review_light_pure \"\$(printf '%s\\n' $2)\" && echo light || echo full"; }
ok "light: docs only" eq "$(lp : 'docs/a.md README.md')" light
ok "light: a test file only (TEST_PATHS)" eq "$(lp : 'tests/a.sh src/a.test.ts')" light
ok "light: a LIGHT_REVIEW_PATHS match" eq "$(lp "LIGHT_REVIEW_PATHS='^schemas/'" 'schemas/a.yaml docs/x.md')" light
ok "light: an EFFORT_DOCS_PATHS match counts as docs" eq "$(lp "EFFORT_DOCS_PATHS='^specs/'" 'specs/a.yaml')" light
ok "not light: one code path" eq "$(lp "LIGHT_REVIEW_PATHS='^schemas/'" 'docs/a.md src/a.ts')" full
ok "not light: a gated path, even when LIGHT_REVIEW_PATHS names it" eq "$(lp "LIGHT_REVIEW_PATHS='^\\.github/'" '.github/workflows/ci.yml')" full
ok "not light: agent configuration, though it is *.md" eq "$(lp : 'docs/a.md CLAUDE.md')" full
ok "not light: no paths" eq "$(lib eval "review_light_pure '' && echo light || echo full")" full
ok "not light: a bad LIGHT_REVIEW_PATHS matches nothing" eq "$(lp "LIGHT_REVIEW_PATHS='('" 'schemas/a.yaml')" full
ok "… and leaves the other kinds light" eq "$(lp "LIGHT_REVIEW_PATHS='('" 'docs/a.md tests/a.sh')" light
ok "REVIEW_MODEL_LIGHT and LIGHT_REVIEW_PATHS default to empty" \
  eq "$( . "$root/lib/canccu-config.default"; echo "[$REVIEW_MODEL_LIGHT][$LIGHT_REVIEW_PATHS]")" "[][]"
ok "review_model: a light review gets REVIEW_MODEL_LIGHT, a fix-check never" \
  eq "$(lib eval 'MODEL=m0 REVIEW_MODEL=m1 FIXCHECK_MODEL=m2 REVIEW_MODEL_LIGHT=m3; echo "$(review_model review 1) $(review_model review 0) $(review_model fixcheck 1)"')" "m3 m1 m2"

effenv light-docs '[{"filename": "docs/a.md", "changes": 400}, {"filename": "tests/a.sh", "changes": 300}]' 'Tier: feature'
printf '%s\n' REVIEW_MODEL=claude-review-x REVIEW_MODEL_LIGHT=claude-light-x >> "$CANCCU_HOME/config"
dispatch --once
ok "REVIEW_MODEL_LIGHT: a docs and tests PR runs on it" grep -q -- '^--quiet --model claude-light-x .*--name review#50 ' "$FAKE/worker.log"
ok "… recorded" eq "$(cat "$CANCCU_HOME/reviews/50.model" 2>/dev/null)" claude-light-x
ok "… at medium effort, though a feature over 100 lines" eq "$(cat "$CANCCU_HOME/reviews/50.effort" 2>/dev/null)" medium
ok "… logged once" eq "$(grep -cF "PR #50: light review (claude-light-x): docs, tests or light paths only" "$CANCCU_HOME/dispatch.log")" 1

effenv light-code '[{"filename": "docs/a.md", "changes": 4}, {"filename": "src/a.ts", "changes": 3}]' 'Tier: fix'
printf '%s\n' REVIEW_MODEL=claude-review-x REVIEW_MODEL_LIGHT=claude-light-x >> "$CANCCU_HOME/config"
dispatch --once
ok "REVIEW_MODEL_LIGHT: a code PR records REVIEW_MODEL" eq "$(cat "$CANCCU_HOME/reviews/50.model" 2>/dev/null)" claude-review-x
ok "… with no light line" not grep -q 'light review' "$CANCCU_HOME/dispatch.log"

effenv light-unset '[{"filename": "docs/a.md", "changes": 4}]' 'Tier: fix'
echo REVIEW_MODEL=claude-review-x >> "$CANCCU_HOME/config"
dispatch --once
ok "no REVIEW_MODEL_LIGHT: a docs PR records REVIEW_MODEL, as before" eq "$(cat "$CANCCU_HOME/reviews/50.model" 2>/dev/null)" claude-review-x

effenv light-unset-code '[{"filename": "src/a.ts", "changes": 4}]' 'Tier: fix'
echo REVIEW_MODEL=claude-review-x >> "$CANCCU_HOME/config"
dispatch --once
ok "… and a code PR too" eq "$(cat "$CANCCU_HOME/reviews/50.model" 2>/dev/null)" claude-review-x

# fxstart <name> [config...]: the worker fixed the findings of the review of HA; CI is green on HB
fxstart() {
  fxenv "$@"
  state 5 phase=check pr=50 stage=fixing reviewed_sha="$HA" verdict_at=2030-11-05T11:00:00Z "check_at=$NOW"
  printf '1\t1\tsrc/a.ts\n' > "$FAKE/numstat"
  dispatch --once
}
fxstart model-fixcheck - FIXCHECK_MODEL=claude-sonnet-5-5 REVIEW_MODEL=claude-review-x
ok "a fix-check runs on FIXCHECK_MODEL" grep -q -- '^--quiet --model claude-sonnet-5-5 .*--name fixcheck#50 ' "$FAKE/worker.log"
ok "… recorded" eq "$(cat "$CANCCU_HOME/reviews/50.model" 2>/dev/null)" claude-sonnet-5-5
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "canccu-status shows the running fix-check's effort and model" grep -q '^  fix-check PR #50 (low · claude-sonnet-5-5) ' "$E/status"
fxstart model-fixcheck-default - MODEL=claude-opus-5-5 REVIEW_MODEL=claude-review-x
ok "no FIXCHECK_MODEL: the fix-check runs on MODEL, not REVIEW_MODEL" grep -q -- '^--quiet --model claude-opus-5-5 .*--name fixcheck#50 ' "$FAKE/worker.log"

# canccu-status: a model without an effort file (a reviewer started before the effort was recorded)
env_new status-model-only
state 6 phase=review stage=review review_mode=review pr=60 "started=$NOW"; live_lock review-60
mkdir -p "$CANCCU_HOME/reviews"; echo review > "$CANCCU_HOME/reviews/60.mode"; echo m1 > "$CANCCU_HOME/reviews/60.model"
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "canccu-status: the model alone" grep -q '^  review PR #60 (m1) ' "$E/status"

# the activity column clips by the label's real width: a label with a model overflows the 22 columns
env_new status-wide
state 6 phase=review stage=review review_mode=review pr=60 "started=$NOW"; live_lock review-60
mkdir -p "$CANCCU_HOME/reviews"; echo review > "$CANCCU_HOME/reviews/60.mode"
echo medium > "$CANCCU_HOME/reviews/60.effort"; echo claude-review-model-x > "$CANCCU_HOME/reviews/60.model"
printf '[t1] %s\n' "$(printf 'x%.0s' {1..150})" > "$WORKERS_DIR/web-review-60.log"
COLUMNS=80 PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "canccu-status: a long label does not push the line past the terminal width" \
  eq "$(l=$(grep -m1 '^  review PR #60' "$E/status"); (( ${#l} > 50 && ${#l} <= 80 )) && echo fits)" fits

# ---------------------------------------------------------------- the light review (#216 D3)

# lightenv <name> <verdict comment>: package 101 (rated normal) has PR 50 at HA; its light review
# of HA is posted with that comment
lightenv() {
  env_new "$1"; echo "REVIEW_LIGHT=1" >> "$CANCCU_HOME/rules"
  { issue 101 in-progress; } | issues
  p=$(PR_BRANCH=101-issue-101 pr 50 101 "$HA" green "" false 'Tier: feature'); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z "$2")")"; route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts", "changes": 40}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue101.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 101 *' issue101.json
  state 101 pkg=a step=12 wave=1 members=101 branch=101-issue-101 risk=normal "risk_reason=plain code" phase=review pr=50 \
    review_sha=$HA stage=review review_mode=review "started=$NOW"
  mkdir -p "$CANCCU_HOME/reviews"; echo "$HA" > "$CANCCU_HOME/reviews/50.light"
}
lightenv light-prompt "Review verdict: pass $HA"
out=$(lib eval "fetch; light_review_prompt 50 101 $HA /tmp/review.md")
hrt='migrations, sign-in or auth, rights, sessions, secrets, tenancy/RLS, deploy/, setup/, contract changes or CI configuration'
ok "the light prompt holds the checklist word for word" grep -qF "This is a light review: do not run the code-review skill. Check exactly this: 1. the change is sensible for its issues; 2. each issue of the package is done (every acceptance criterion of every linked issue); 3. every new behaviour has a test that would fail if it broke, and no test was skipped, emptied or weakened; 4. obvious bugs in the changed lines; 5. code and contracts agree (the names, defaults, texts and formats the issues and the repo's docs fix); 6. no TODO, stub or debug code left, and no work outside the package; 7. tripwires: a secret or a private name is a blocking security finding; a new dependency or risky code ($hrt) makes your Risk: line high." <<<"$out"
ok "… the security-review sentence" grep -qF 'Also run the security-review skill if it touches sign-in, rights, sessions, secrets, tenancy/RLS or deploy/.' <<<"$out"
ok "… REVIEW_EXTRA and Decisions made:" grep -qF "Check the no-personal-data rule (no real names, hostnames, IPs or personal paths), that contract changes are additive and migrations non-destructive and the implementation choices listed under 'Decisions made:' in the PR body." <<<"$out"
ok "… the risk and no-repeat sentences" eq "$(grep -cF "The plan rated the package normal (plain code)" <<<"$out") $(grep -cF 'is not raised again: the dispatcher demotes it' <<<"$out")" "1 1"
ok "… the block and the verdict line" eq "$(grep -cF 'Findings: <b> blocking' <<<"$out") $(grep -cF "Review verdict: pass $HA" <<<"$out")" "1 1"
ok "… and no code-review skill run" not grep -qF 'Run the code-review skill' <<<"$out"

# a light pass rated high: one full review of the same head, then no more
lightenv light-up $'Risk: high — a new dependency\n\nReview verdict: pass '"$HA"
dispatch --once
ok "a light pass with Risk: high → logged" grep -qF "#101 PR #50: the light review rated it high risk; full review of ${HA:0:7}" "$CANCCU_HOME/dispatch.log"
ok "… a full review of the same head starts, not a light one" \
  eq "$(grep -c -- '--key review-50' "$FAKE/worker.log") $(grep -c 'Run the code-review skill' "$FAKE/worker.log") $(grep -c 'This is a light review' "$FAKE/worker.log") $(cat "$CANCCU_HOME/reviews/50.sha")" "1 1 0 $HA"
ok "… no merge on the light pass" hasnt gh.log "pr merge 50"
ok "… the light mark is gone once it runs; the ask holds until its verdict" eq "$([ -e "$CANCCU_HOME/reviews/50.light" ] && echo light)[$(st 101 review_asked)]" "[1]"
rm -f "$WORKERS_DIR/web-review-50.lock"
jq --argjson c "$(vcomment 2030-11-05T11:30:00Z $'Risk: normal — fine\n\nReview verdict: pass '"$HA")" '.comments += [$c]' "$FAKE/pr50.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/pr50.json"
dispatch --once
ok "… its pass is acted on: merge or accept, no third review; the ask is cleared" \
  eq "$(grep -c -- '--key review-50' "$FAKE/worker.log") $(case $(st 101 phase) in accept|merging) echo acted ;; *) st 101 phase ;; esac) [$(st 101 review_asked)]" "1 acted []"
# the upgraded full review ends at the usage limit without a verdict: the ask holds, so the light
# pass in reviews.log is not reused; the full review starts again after the back-off
lightenv light-up-limit $'Risk: high — a new dependency\n\nReview verdict: pass '"$HA"
printf '%s\nReview verdict: pass %s\n' "$VB0" "$HA" > "$E/light.md"; lib reviews_log 101 50 "$HA" "$E/light.md"
dispatch --once
rm -f "$WORKERS_DIR/web-review-50.lock"; last review-50 error "Claude AI usage limit reached|$((NOW + 3600))"
dispatch --once
ok "the asked-for full review hits the usage limit: back to check, the ask kept" eq "$(st 101 phase) $(st 101 review_asked)" "check 1"
echo $((NOW - 1)) > "$CANCCU_ROOT/backoff"; dispatch --once
ok "… after the back-off the full review starts again, the light pass not reused" \
  eq "$(grep -c -- '--key review-50' "$FAKE/worker.log") $(grep -c 'This is a light review' "$FAKE/worker.log") $(grep -c 'verdict reused' "$CANCCU_HOME/dispatch.log") $(grep -c 'pr merge 50' "$FAKE/gh.log")" "2 0 0 0"
# the full review finds no slot: no merge meanwhile; it starts once a slot is free
lightenv light-up-slot $'Risk: high — a new dependency\n\nReview verdict: pass '"$HA"
echo "CAP=1" >> "$CANCCU_HOME/config"; live_lock 77
dispatch --once; dispatch --once
ok "the full review refused for a slot: no merge over two passes" \
  eq "$(grep -c -- '--key review-50' "$FAKE/worker.log") $(grep -c 'pr merge 50' "$FAKE/gh.log") $(st 101 phase) $(st 101 review_asked)" "0 0 check 1"
rm -f "$WORKERS_DIR/web-77.lock"; dispatch --once
ok "… a slot frees: the full review starts" eq "$(grep -c -- '--key review-50' "$FAKE/worker.log") $(grep -c 'This is a light review' "$FAKE/worker.log")" "1 0"
# a light `changes` rated high: no fix run on it; the full review of the same head comes first,
# and its verdict drives the fix round
lightenv light-up-changes "$VB1"$'Risk: high — a new dependency\n\nReview verdict: changes '"$HA"
dispatch --once
ok "a light changes with Risk: high → the full review of that head, no fix run" \
  eq "$(grep -cF 'the light review rated it high risk' "$CANCCU_HOME/dispatch.log") $(grep -c -- '--key review-50' "$FAKE/worker.log") $(grep -c 'Run the code-review skill' "$FAKE/worker.log") $(grep -c 'asked for changes on PR #50' "$FAKE/worker.log") $(st 101 stage) $(st 101 review_asked)" "1 1 1 0 review 1"
rm -f "$WORKERS_DIR/web-review-50.lock"
jq --argjson c "$(vcomment 2030-11-05T11:30:00Z "$VB1"$'Risk: normal — fine\n\nReview verdict: changes '"$HA")" '.comments += [$c]' "$FAKE/pr50.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/pr50.json"
dispatch --once
ok "… the full review's changes starts the fix round" \
  eq "$(grep -c 'asked for changes on PR #50' "$FAKE/worker.log") $(st 101 stage) $(st 101 reviewed_sha) [$(st 101 review_asked)]" "1 fixing $HA []"

printf '%s\nReview verdict: pass %s\n' "$VB0" "$HA" > "$E/light.md"; lib reviews_log 101 50 "$HA" "$E/light.md"
ok "reviews.log keeps kind full for a light review" grep -qP "^\S+\t50\t$HA\tfull\tpass\t" "$CANCCU_HOME/reviews.log"

echo "canccu-review-effort tests: $npass passed, $nfail failed"
(( nfail == 0 ))
