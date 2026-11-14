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

env_new no-profile
ok "no HOST_PROFILE: the defaults" eq "$(load '$HOST_PROFILE|$BUDGET_WORK|$TOTAL_CAP')" "|250 80 150|3"

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
keys=$(grep -oE '^[A-Z_]+=' "$root/hosts/max.conf" | tr -d = | sort -u)
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

# ---------------------------------------------------------------- hosts/pro.conf

tname=pro
ok "hosts/pro.conf ships" test -f "$root/hosts/pro.conf"
ok "… and sets no HOST_PROFILE" not grep -qE '^[[:space:]]*HOST_PROFILE=' "$root/hosts/pro.conf"
# the issue fixed that a host's model stays its own choice
ok "… and no model" not grep -qE '^[[:space:]]*[A-Z_]*MODEL[A-Z_]*=' "$root/hosts/pro.conf"
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
# the harness's project config sets CAP, which wins over any profile
sed -i '/^CAP=/d' "$CANCCU_HOME/config"
ok "HOST_PROFILE=pro: one run at a time, max's budgets, a medium review effort" \
  eq "$(CANCCU_HOST_PROFILE=pro load '$HOST_PROFILE|$CAP|$TOTAL_CAP|$BUDGET_REVIEW|$REVIEW_EFFORT_MAX')" "pro|1|1|60 15 40|medium"
printf 'HOST_PROFILE=pro\nTOTAL_CAP=2\nREVIEW_EFFORT_MAX=high\n' > "$CANCCU_ROOT/config"
ok "… a value in ~/.canccu/config overrides it" eq "$(load '$TOTAL_CAP|$REVIEW_EFFORT_MAX|$BUDGET_REVIEW')" "2|high|60 15 40"

echo "canccu-hosts tests: $npass passed, $nfail failed"
(( nfail == 0 ))
