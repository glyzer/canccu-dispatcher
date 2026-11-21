#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-hosts.sh — host profiles: HOST_PROFILE (CANCCU_HOST_PROFILE, else ~/.canccu/config),
# the load order defaults → hosts/<profile>.conf → ~/.canccu/config → rules → the project's
# config, hosts/max.conf, hosts/pro.conf (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# a tree of its own, with an invented profile "lab" that sets one key of each kind, and
# HOST_PROFILE, which a profile must never change
S=$T/src; src_copy "$S"
printf '# shellcheck shell=bash\nBUDGET_WORK="1 2 3"\nCAP=7\nTOTAL_CAP=9\nPING=off\nHOST_PROFILE=max\n' > "$S/hosts/lab.conf"
# load <expr>: the expression after the lib has loaded the config, or the lib's error
load() { ( . "$S/lib/canccu-common.sh"; eval "echo \"$1\"" ) 2>&1; }

# every run model key, in one expression for load
models='$MODEL|$FIX_MODEL|$PLAN_MODEL|$REVIEW_MODEL|$REVIEW_MODEL_LIGHT|$FIXCHECK_MODEL|$HEALTH_MODEL'

env_new no-profile
ok "no HOST_PROFILE: the defaults" eq "$(load '$HOST_PROFILE|$BUDGET_WORK|$TOTAL_CAP')" "|250 80 150|3"
ok "… and every model key empty (the account default)" eq "$(load "$models")" "||||||"

env_new from-config
echo 'HOST_PROFILE=lab' > "$CANCCU_ROOT/config"
ok "HOST_PROFILE from ~/.canccu/config: the profile's values" eq "$(load '$BUDGET_WORK|$PING|$TOTAL_CAP')" "1 2 3|off|9"
ok "… and a profile never sets HOST_PROFILE" eq "$(load '$HOST_PROFILE')" lab
ok "… the project's config wins over the profile (CAP)" eq "$(load '$CAP')" 3
printf 'HOST_PROFILE=lab\nBUDGET_WORK="4 5 6"\nTOTAL_CAP=2\n' > "$CANCCU_ROOT/config"
ok "a value in ~/.canccu/config overrides the profile's" eq "$(load '$BUDGET_WORK|$TOTAL_CAP')" "4 5 6|2"
echo 'TOTAL_CAP=20' >> "$CANCCU_HOME/config"
ok "… TOTAL_CAP still comes only up to ~/.canccu/config" eq "$(load '$TOTAL_CAP')" 2
printf 'PING=on\n' >> "$CANCCU_HOME/rules"
ok "the project's rules win over the profile" eq "$(load '$PING')" on

env_new uses-defaults
# a config that builds on a default (or names an unset variable) before HOST_PROFILE: the
# profile is still read
printf 'TOTAL_CAP=$((CAP * 2))\nHOST_PROFILE=lab\n' > "$CANCCU_ROOT/config"
ok "a config that uses a default before HOST_PROFILE: the profile applies" eq "$(load '$HOST_PROFILE|$BUDGET_WORK|$TOTAL_CAP')" "lab|1 2 3|14"
printf 'BUDGET_ANSWER="$NOT_SET_ANYWHERE 1"\nHOST_PROFILE="lab"   # the lab host\n' > "$CANCCU_ROOT/config"
ok "… the profile's name read past an unset name, without quotes or comment" \
  eq "$( . "$S/lib/canccu-projects.sh"; canccu_config_host_profile "$CANCCU_ROOT/config")" lab

env_new from-env
echo 'HOST_PROFILE=nosuch' > "$CANCCU_ROOT/config"
ok "CANCCU_HOST_PROFILE wins over ~/.canccu/config" eq "$(CANCCU_HOST_PROFILE=lab load '$HOST_PROFILE|$BUDGET_WORK')" "lab|1 2 3"

env_new unknown
echo 'HOST_PROFILE=nosuch' > "$CANCCU_ROOT/config"
out=$(load ok); rc=$( (. "$S/lib/canccu-common.sh") >/dev/null 2>&1; echo $?)
ok "an unknown profile is refused" eq "$rc" 1
ok "… with the list of profiles" grep -q "no host profile 'nosuch'.*lab, max, pro" <<<"$out"
ok "… so canccu-status refuses too" grep -q "no host profile 'nosuch'" <<<"$(CANCCU_HOST_PROFILE=nosuch "$S/bin/canccu-status" 2>&1)"
ok "a name that is a path is no profile" grep -q "no host profile '../lib/canccu-config'" <<<"$(CANCCU_HOST_PROFILE=../lib/canccu-config load ok)"

# ---------------------------------------------------------------- hosts/max.conf

tname=max
ok "hosts/max.conf ships" test -f "$root/hosts/max.conf"
ok "… and sets no HOST_PROFILE" not grep -qE '^[[:space:]]*HOST_PROFILE=' "$root/hosts/max.conf"
# the plan-limit keys only: the run models, the review effort and the caps (two at once under v2,
# #14) are the profile's own choice
keys=$(grep -oE '^[A-Z_]+=' "$root/hosts/max.conf" | tr -d = | grep -vE 'MODEL|^REVIEW_EFFORT_MAX$|^DEEP_REVIEW_EFFORT$|CAP$' | sort -u)
ok "… it pins some keys" test -n "$keys"
diff=""
for k in $keys; do
  a=$( (CANCCU_ROOT=/nonexistent; . "$root/lib/canccu-config.default"; echo "${!k}") )
  b=$( (CANCCU_ROOT=/nonexistent; . "$root/hosts/max.conf"; echo "${!k}") )
  [ "$a" = "$b" ] || diff+=" $k"
done
ok "… each to today's default" eq "${diff# }" ""
env_new max-load
ok "HOST_PROFILE=max loads" eq "$(CANCCU_HOST_PROFILE=max load '$HOST_PROFILE|$BUDGET_WORK')" "max|250 80 150"
ok "HOST_PROFILE=max: Opus runs and every review and fix-check (v2), effort up to high" \
  eq "$(CANCCU_HOST_PROFILE=max load "$models|\$REVIEW_EFFORT_MAX|\$DEEP_REVIEW_EFFORT")" \
  "claude-opus-5-5||claude-opus-5-5|claude-opus-5-5||||high|high"
ok "… two runs at once" eq "$( (CANCCU_ROOT=/nonexistent; . "$root/hosts/max.conf"; echo "$CAP|$TOTAL_CAP") )" "2|2"
printf 'HOST_PROFILE=max\nMODEL=x\n' > "$CANCCU_ROOT/config"
ok "… MODEL in ~/.canccu/config overrides it" eq "$(load '$MODEL|$REVIEW_MODEL')" "x|claude-opus-5-5"

# ---------------------------------------------------------------- hosts/pro.conf

tname=pro
ok "hosts/pro.conf ships" test -f "$root/hosts/pro.conf"
ok "… and sets no HOST_PROFILE" not grep -qE '^[[:space:]]*HOST_PROFILE=' "$root/hosts/pro.conf"
# the product owner decided that a Pro host's limit is parallelism, not run length
pk=$(grep -oE '^(BUDGET_[A-Z_]+|STEP_BUDGET)=' "$root/hosts/max.conf" | tr -d = | sort -u)
ok "… it sets the budget keys max sets" eq "$(grep -oE '^(BUDGET_[A-Z_]+|STEP_BUDGET)=' "$root/hosts/pro.conf" | tr -d = | sort -u)" "$pk"
diff=""
for k in $pk; do
  a=$( (CANCCU_ROOT=/nonexistent; . "$root/hosts/max.conf"; echo "${!k}") )
  b=$( (CANCCU_ROOT=/nonexistent; . "$root/hosts/pro.conf"; echo "${!k}") )
  [ "$a" = "$b" ] || diff+=" $k"
done
ok "… each to max's value" eq "${diff# }" ""
ok "… and one run at a time" eq "$( (CANCCU_ROOT=/nonexistent; . "$root/hosts/pro.conf"; echo "$CAP|$TOTAL_CAP") )" "1|1"
env_new pro-load
# the harness's project config sets CAP and pins the old defaults (DEEP_REVIEW_EFFORT), which win over
# any profile
sed -i '/^CAP=/d' "$CANCCU_HOME/config"; new_defaults
ok "HOST_PROFILE=pro: one run at a time, max's budgets, a medium review and deep review effort" \
  eq "$(CANCCU_HOST_PROFILE=pro load '$HOST_PROFILE|$CAP|$TOTAL_CAP|$BUDGET_REVIEW|$REVIEW_EFFORT_MAX|$DEEP_REVIEW_EFFORT')" "pro|1|1|60 15 40|medium|medium"
printf 'HOST_PROFILE=pro\nTOTAL_CAP=2\nREVIEW_EFFORT_MAX=high\n' > "$CANCCU_ROOT/config"
ok "… a value in ~/.canccu/config overrides it" eq "$(load '$TOTAL_CAP|$REVIEW_EFFORT_MAX|$BUDGET_REVIEW')" "2|high|60 15 40"
printf 'HOST_PROFILE=pro\n' > "$CANCCU_ROOT/config"
ok "HOST_PROFILE=pro: Sonnet runs, fixes and health; Opus plans, every review and fix-check (v2)" \
  eq "$(load "$models")" \
  "claude-sonnet-5-5|claude-sonnet-5-5|claude-opus-5-5|claude-opus-5-5||claude-opus-5-5|claude-sonnet-5-5"
printf 'HOST_PROFILE=pro\nMODEL=x\n' > "$CANCCU_ROOT/config"
ok "… MODEL in ~/.canccu/config overrides it" eq "$(load '$MODEL|$REVIEW_MODEL')" "x|claude-opus-5-5"

# ---------------------------------------------------------------- the test tier (#250)

tname=test-tier
for h in max pro; do
  ok "hosts/$h.conf sets TEST_TIER=targeted" eq "$( (CANCCU_ROOT=/nonexistent; . "$root/hosts/$h.conf"; echo "${TEST_TIER-unset}") )" targeted
done
env_new tier-load
printf 'HOST_PROFILE=pro\nTEST_TIER=full\n' > "$CANCCU_ROOT/config"
ok "… ~/.canccu/config overrides it" eq "$(load '$TEST_TIER')" full

# ---------------------------------------------------------------- the same project on both (#14)

tname=both
# keys_of <profile>: every key the lib loads, with its value, minus the profile's own
keys_of() {
  ( CANCCU_HOST_PROFILE=$1; . "$root/lib/canccu-common.sh"
    for k in $(grep -oE '^[A-Z_]+=' "$root/lib/canccu-config.default" | tr -d = | sort -u); do
      grep -qE "^$k=" "$root/hosts/max.conf" "$root/hosts/pro.conf" || printf '%s=%s\n' "$k" "${!k}"
    done ) 2>/dev/null
}
env_new both
sed -i '/^CAP=/d' "$CANCCU_HOME/config"
ok "the same project on a pro and a max host gets the same features" eq "$(keys_of pro | md5sum)" "$(keys_of max | md5sum)"
ok "… a profile sets only caps, budgets, thresholds, models, effort and the test tier (#250)" \
  eq "$(cat "$root/hosts/max.conf" "$root/hosts/pro.conf" | grep -oE '^[A-Z_]+=' | tr -d = | grep -vE '^(CAP|TOTAL_CAP|BUDGET_[A-Z_]+|STEP_BUDGET|USAGE_[A-Z_]+|[A-Z_]*MODEL[A-Z_]*|REVIEW_EFFORT_MAX|DEEP_REVIEW_EFFORT|TEST_TIER)$')" ""
# the throttle at each profile's thresholds (usage_state)
ustate() { ( CANCCU_HOST_PROFILE=$1; . "$root/lib/canccu-common.sh"
  for v in "${@:2}"; do USAGE_NOW="$v - - $NOW"; printf '%s ' "$(usage_state)"; done ) 2>/dev/null; }
ok "pro's throttle: slow at 80, stop at 95, drain at weekly 90" eq "$(ustate pro '79 0' '80 0' '95 0' '10 90')" "normal slow stop drain "
ok "max's throttle: slow at 60, stop at 90, drain at weekly 90" eq "$(ustate max '59 0' '60 0' '90 0' '10 90')" "normal slow stop drain "
# the review effort per profile: a gated path asks for high, the profile caps it
eff() { ( CANCCU_HOST_PROFILE=$1; . "$root/lib/canccu-common.sh"; review_effort_pure "$(printf '%s\t1' "$2")" "" "${3:-}" ) 2>/dev/null; }
ok "pro: a gated path and a high-risk PR are reviewed at medium" eq "$(eff pro .github/workflows/ci.yml)|$(eff pro src/a.sh high)" "medium capped|medium capped"
ok "max: the same at high" eq "$(eff max .github/workflows/ci.yml)|$(eff max src/a.sh high)" "high|high"
echo "canccu-hosts tests: $npass passed, $nfail failed"
(( nfail == 0 ))
