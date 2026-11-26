# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the automatic fix budgets of a PR. Two
# counters, both kept for one PR (fixes_pr) and reset together when the unit opens another: red-CI
# fixes (`fixes`, against FIX_ATTEMPTS: the key kept its name, older state counts as CI fixes) and
# review fixes (`rfixes`, against REVIEW_FIX_ATTEMPTS), so red CI before the review never uses up
# the review's fix round. Also the extra round of FIX_EXTRA_IF_FEWER.

# fix_max: FIX_ATTEMPTS, or its default 2 when it is no whole number (a typo must not break the
# (( )) tests or lift the cap)
fix_max() { [[ ${FIX_ATTEMPTS:-} =~ ^[0-9]+$ ]] && echo "$FIX_ATTEMPTS" || echo 2; }
# rfix_max: REVIEW_FIX_ATTEMPTS, or its default 1 when it is no whole number
rfix_max() { [[ ${REVIEW_FIX_ATTEMPTS:-} =~ ^[0-9]+$ ]] && echo "$REVIEW_FIX_ATTEMPTS" || echo 1; }

# fixes_used <K> <pr>: the red-CI fix runs on that PR so far; rfixes_used: its review fix runs. A
# count kept for another PR (the unit opened a new one) is not this PR's
fixes_used() { [ "$(st_get "$1" fixes_pr)" = "$2" ] && echo "$(( $(st_get "$1" fixes) + 0 ))" || echo 0; }
rfixes_used() { [ "$(st_get "$1" fixes_pr)" = "$2" ] && echo "$(( $(st_get "$1" rfixes) + 0 ))" || echo 0; }
fix_left() { (( $(fixes_used "$1" "$2") < $(fix_max) )); }
rfix_left() { (( $(rfixes_used "$1" "$2") < $(rfix_max) )); }
# fix_count <K> <pr>, rfix_count <K> <pr>: one more of that kind. Both counters are written: a
# first count on a new PR must zero the other kind's count of the old one
fix_count() { st_set "$1" fixes=$(( $(fixes_used "$1" "$2") + 1 )) rfixes="$(rfixes_used "$1" "$2")" fixes_pr="$2"; }
rfix_count() { st_set "$1" rfixes=$(( $(rfixes_used "$1" "$2") + 1 )) fixes="$(fixes_used "$1" "$2")" fixes_pr="$2"; }
# fix_counts <K> <pr>: the status line's "ci 2/2 · review 0/1"
fix_counts() { printf 'ci %s/%s · review %s/%s' "$(fixes_used "$1" "$2")" "$(fix_max)" "$(rfixes_used "$1" "$2")" "$(rfix_max)"; }

# blocking_note <K> <verdict body> <verdict at> <head>: the verdict's blocking count (findings_count:
# the blocking findings left, as spend.log has them) becomes blocking_last, the one before it blocking_prev. Once per verdict
# (blocking_at): a verdict acted on again next pass, after a step that failed, never shifts twice.
blocking_note() {
  local b nb
  [ "$(st_get "$1" blocking_at)" = "$3" ] && return 0
  read -r b nb <<<"$(findings_count <(printf '%s\n' "$2") "${4:-}")"
  st_set "$1" blocking_prev="$(st_get "$1" blocking_last)" blocking_last="${b:-0}" blocking_at="$3"
}
# extra_fix_due <K>: FIX_EXTRA_IF_FEWER is 1, the cycle had no extra round yet (extra_fix, cleared by
# new_cycle: a fix that keeps improving still meets a person after one), and the last verdict has
# fewer blocking findings than the one before but at least one (none left is a parse miss, not progress)
extra_fix_due() {
  local p l
  # FIX_ATTEMPTS=0 means no automatic fix run at all, this one included
  [ "${FIX_EXTRA_IF_FEWER:-1}" = 1 ] && [ -z "$(st_get "$1" extra_fix)" ] && (( $(fix_max) > 0 )) || return 1
  p=$(st_get "$1" blocking_prev) l=$(st_get "$1" blocking_last)
  [[ $p =~ ^[0-9]+$ && $l =~ ^[0-9]+$ ]] && (( l >= 1 && l < p ))
}
# findings_inline <blocking findings> <their file>: as a fix prompt has them; long ones are cut and
# read in the file (the prompt has a limit)
findings_inline() {
  if (( ${#1} > 3000 )); then printf '%s' "${1:0:3000} The findings are cut here; read all of them in $2."
  else printf '%s' "$1 (also in $2)"; fi
}
# extra_fix_round <K> <pr> <head> <verdict body> <review|fix-check>: a `changes` that would stop for
# the user gets one more automatic fix round when extra_fix_due, like a needs-work's (extra_round)
# without the user's comments; then a fix-check of head..new head against its blocking findings.
# It ignores both caps (it is the one round past them the setting allows) and counts as a review
# fix. 0: started; 1: not due, ask as today; 2: due but not started (back-off, no slot, the run
# failed): again next pass.
extra_fix_round() {
  local k=$1 pr=$2 head=$3 b ff
  extra_fix_due "$k" || return 1
  may_start "$k" || return 2
  b=$(blocking_numbered "$4") ff=$(findings_file "$pr" "$head")
  save_findings "$k" "$pr" "$ff" "$b"
  resume "$k" "The $5 of PR #$pr still finds blocking items, fewer than the verdict before it: this is one more automatic fix round, the last one. Fix every blocking finding below, rerun the checks, push once and stop: the dispatcher watches CI. Leave its non-blocking findings alone: they went to a follow-up issue. A narrow fix-check of this fix diff follows, then the merge or the product owner. The blocking findings: $(findings_inline "$b" "$ff")" fix || return 2
  fix_count "$k" "$pr"
  st_set "$k" extra_fix=1 stage=fixing reviewed_sha="$head"
  log "#$k PR #$pr: blocking findings fell from $(st_get "$k" blocking_prev) to $(st_get "$k" blocking_last); one more automatic fix round"
}
