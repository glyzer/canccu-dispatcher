#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-costs.sh — offline tests for the cost report: canccu-status --costs (by run type,
# per issue, by kind from COST_KINDS) and the digest's cost section. Harness: tests/lib/harness.sh.
#   bash tests/canccu-costs.sh   one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

d() { date -u -d "$1" +%s; }
env_new costs "COST_KINDS='packs=^docs\(briefs\);shots=screenshot|demo-stack'" COST_ROUNDS_ALERT=2
{
  printf '%s\t10\t100\tauto\tdocs(briefs): pack one\n' "$(d 2030-10-20T10:00:00Z)"
  printf '%s\t11\t101\tauto\tfeat: add Screenshot tool\n' "$(d 2030-11-02T10:00:00Z)"
  printf '%s\t12\t102\tauto\tfeat: plain\n' "$(d 2030-11-03T10:00:00Z)"
} > "$CANCCU_HOME/merged.log"
sp() { printf '%s\tweb\t%s\t%s\t%s\t-\t-\tfresh\n' "$(d "$1")" "$2" "$3" "$4"; }
{
  sp 2030-10-19T10:00:00Z 10 1.00 build
  sp 2030-10-19T12:00:00Z review-100 0.50 review
  sp 2030-11-02T08:00:00Z 11 2.00 build
  sp 2030-11-02T09:00:00Z 11 1.00 fix
  sp 2030-11-02T09:30:00Z review-101 0.25 fix-check
  sp 2030-11-03T08:00:00Z 12 3.00 build
  sp 2030-11-04T08:00:00Z 12 '?' fix
  sp 2030-11-05T09:00:00Z 13 4.00 build
  sp 2030-11-05T09:30:00Z 13 0.50 fix
  sp 2030-11-05T10:00:00Z 13 0.50 fix
  sp 2030-11-05T11:00:00Z 13 0.50 fix
  printf '%s\tother\t99\t50.00\tbuild\n' "$(d 2030-11-05T09:00:00Z)"
} > "$WORKERS_DIR/spend.log"

out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" --costs 2>&1)
ok "--costs: the total, the run count and the lost run" grep -qF 'costs (all) · $13.25 · 11 runs (1 lost, so at least)' <<<"$out"
ok "… by run type" grep -qE '^  fix +5 runs +\$2\.50$' <<<"$out"
ok "… another repo's runs are not counted" not grep -qF 50.00 <<<"$out"
ok "… a review counts for the issue whose PR merged, its fix rounds shown" grep -qE '^  #11 +\$3\.25 +1 fix round +feat: add Screenshot tool$' <<<"$out"
ok "… the most expensive issue first" eq "$(grep -A1 '^most expensive' <<<"$out" | tail -1 | awk '{print $1}')" "#13"
ok "… by kind: packs" grep -qE '^  packs +1 issue +\$1\.50$' <<<"$out"
ok "… shots, matched case-insensitively" grep -qE '^  shots +1 issue +\$3\.25$' <<<"$out"
ok "… the rest is other" grep -qE '^  other +2 issues +\$8\.50$' <<<"$out"

out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" --costs --since 2030-11-02 --top 1 2>&1)
ok "--since: only later runs" grep -qF 'costs (since 2030-11-02) · $11.75 · 9 runs' <<<"$out"
ok "--top 1: one issue listed" eq "$(grep -cE '^  #[0-9]+ ' <<<"$out")" 1
PATH="$fb:$PATH" "$root/bin/canccu-status" --costs --since nonsense >/dev/null 2>&1; ok "--since with no date: a usage error" eq "$?" 2

PATH="$fb:$PATH" "$root/bin/canccu-status" --costs --since >/dev/null 2>&1; ok "--since as the last argument: a usage error" eq "$?" 2
PATH="$fb:$PATH" "$root/bin/canccu-status" --costs --since "" >/dev/null 2>&1; ok "--since with an empty value: a usage error" eq "$?" 2

dg=$(lib costs_digest)
ok "digest: today's cost by kind" grep -qF '**Cost today:** $5.50 total (other $5.50)' <<<"$dg"
ok "… an issue over COST_ROUNDS_ALERT rounds" grep -qF -- '- #13: 3 rounds, $5.50' <<<"$dg"
env_new costs-quiet COST_ROUNDS_ALERT=0
printf '%s\tweb\t13\t1\tfix\n' "$(d 2030-11-05T09:00:00Z)" > "$WORKERS_DIR/spend.log"
ok "COST_ROUNDS_ALERT=0: no round line" not grep -qF rounds <<<"$(lib costs_digest)"
: > "$WORKERS_DIR/spend.log"
ok "no run today: no section" eq "$(lib costs_digest)" ""

# no merged.log (or an empty one): runs still count
printf '%s\tweb\t13\t1\tfix\n%s\tweb\t13\t2\tfix\n' "$(d 2030-11-05T09:00:00Z)" "$(d 2030-11-05T10:00:00Z)" > "$WORKERS_DIR/spend.log"
rm -f "$CANCCU_HOME/merged.log"
ok "no merged.log: the report has the runs" grep -qF 'costs (all) · $3.00 · 2 runs' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" --costs 2>&1)"
ok "… and so has the digest" grep -qF 'total' <<<"$(lib costs_digest)"
: > "$CANCCU_HOME/merged.log"
ok "empty merged.log: the report has the runs" grep -qF '2 runs' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" --costs 2>&1)"

# kinds are grep -iE: \b, {n} and \W work
env_new costs-re "COST_KINDS='w=\bui\b;iv=a{3}b;up=\Wfoo'"
printf '%s\t1\t201\tauto\tfeat: ui page\n%s\t2\t202\tauto\taaab thing\n%s\t3\t203\tauto\tx foo\n' "$(d 2030-11-05T09:00:00Z)" "$(d 2030-11-05T09:00:00Z)" "$(d 2030-11-05T09:00:00Z)" > "$CANCCU_HOME/merged.log"
{ sp 2030-11-05T09:00:00Z 1 1.00 build; sp 2030-11-05T09:00:00Z 2 2.00 build; sp 2030-11-05T09:00:00Z 3 3.00 build; } > "$WORKERS_DIR/spend.log"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" --costs 2>&1)
ok "regex kinds: \\b" grep -qE '^  w +1 issue +\$1\.00$' <<<"$out"
ok "regex kinds: {n}" grep -qE '^  iv +1 issue +\$2\.00$' <<<"$out"
ok "regex kinds: \\W" grep -qE '^  up +1 issue +\$3\.00$' <<<"$out"

# a big log: the kind map must not go through the environment (one string over 128 KiB)
env_new costs-big "COST_KINDS='f=^feat'"
for i in $(seq 1 2500); do printf '%s\t%s\t%s\tauto\tfeat: a typical title of about seventy characters, give or take a few\n' "$(d 2030-11-05T09:00:00Z)" "$i" "$((1000 + i))"; done > "$CANCCU_HOME/merged.log"
for i in $(seq 1 2500); do sp 2030-11-05T09:00:00Z "$i" 1.00 build; done > "$WORKERS_DIR/spend.log"
ok "2500 units: the kind report still works" grep -qE '^  f +2500 issues +\$2500\.00$' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" --costs 2>&1)"

echo "canccu-costs tests: $npass passed, $nfail failed"
(( nfail == 0 ))
