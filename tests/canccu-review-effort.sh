#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-review-effort.sh — the full review's effort by a package's risk class and by
# EFFORT_DOCS_PATHS, and the reviewer's model by kind (REVIEW_MODEL, FIXCHECK_MODEL). Kept apart
# from tests/canccu-review.sh so each file stays well under CI's per-file time limit (the harness:
# tests/lib/harness.sh).
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
ok "no class, contracts and feature code → high" eq "$(ef $'src/a.ts\t3\ncontracts/screen.yaml\t2' 'Tier: feature')" high
ok "no class, contracts and another risky path → high" eq "$(ef $'src/auth/a.ts\t3\ncontracts/screen.yaml\t2' 'Tier: fix')" high
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

# through a pass: a package rated normal gets a medium review although it touches a risky path
pkgenv eff-pkg-dispatch 101 '[{"filename": "src/auth/session.ts", "changes": 40}]' 'Tier: feature' pkg=a risk=normal "check_at=$NOW"
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
dispatch --once
ok "a normal-risk package's review runs at medium effort" grep -q 'review#50 .*Run the code-review skill at medium effort' "$FAKE/worker.log"
ok "… recorded" eq "$(cat "$CANCCU_HOME/reviews/50.effort")" medium

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

echo "canccu-review-effort tests: $npass passed, $nfail failed"
(( nfail == 0 ))
