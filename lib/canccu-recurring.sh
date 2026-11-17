# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): recurring findings (contracts §8, Q1).
# A finding that comes back on FINDINGS_RECUR merged PRs within FINDINGS_RECUR_DAYS days is fixed
# where it comes from (a rule, a prompt line, a lint, a test), not once more in each PR: the
# dispatcher files one issue per key for a person to decide on. The key is class + file only, never
# the finding's text: reviewers word the same finding differently each time.

# findings_keys <pr>: "<class> <file>" (tab-separated) once per key of the PR's acted-on verdicts
# (the posted ones: reviews.log), every heading's items; an item without a class or a file has no key
findings_keys() {
  local sha
  for sha in $(awk -F '\t' -v p="$1" '$2 == p { print $3 }' "$CANCCU_HOME/reviews.log" 2>/dev/null | sort -u); do
    [ -s "$(review_file "$1" "$sha")" ] && review_parse "$(review_file "$1" "$sha")"
  done | awk -F '\t' '$1 != "count" && $2 != "-" && $3 != "-" && !s[$2 "\t" $3]++ { print $2 "\t" $3 }'
}

# _recur_n: FINDINGS_RECUR as a number (a value that is none counts as its default)
_recur_n() { local r=${FINDINGS_RECUR:-3}; [[ $r =~ ^[0-9]+$ ]] || r=3; echo "$r"; }
_recur_days() { local d=${FINDINGS_RECUR_DAYS:-30}; [[ $d =~ ^[0-9]+$ ]] || d=30; echo "$d"; }

# findings_record <pr>: on merge, the PR's keys go to findings.log (`<time> <pr> <class> <file>`),
# then recur_check. Once per PR: a merge seen again (a retried pass) neither counts nor comments twice.
findings_record() {
  local pr=$1 keys t
  (( $(_recur_n) > 0 )) && ! (( CANCCU_DRY )) || return 0
  awk -F '\t' -v p="$pr" '$2 == p { f = 1 } END { exit !f }' "$CANCCU_HOME/findings.log" 2>/dev/null && return 0
  keys=$(findings_keys "$pr"); [ -n "$keys" ] || return 0
  t=$(now)
  awk -v t="$t" -v p="$pr" '{ print t "\t" p "\t" $0 }' <<<"$keys" >> "$CANCCU_HOME/findings.log" ||
    { log "PR #$pr: cannot append to findings.log"; return 0; }
  recur_check "$pr" "$keys"
}

# _recur_prs <class> <file>: the distinct PRs with the key in findings.log within the window, oldest first
_recur_prs() {
  awk -F '\t' -v c="$1" -v f="$2" -v from="$(( $(now) - $(_recur_days) * 86400 ))" \
    '$3 == c && $4 == f && $1 >= from && !s[$2]++ { print $2 }' "$CANCCU_HOME/findings.log" 2>/dev/null
}

# _recur_lines <pr> <class> <file>: the PR's findings of the key, one "- PR #<pr>: <item's first line>" each
_recur_lines() {
  local sha
  for sha in $(awk -F '\t' -v p="$1" '$2 == p { print $3 }' "$CANCCU_HOME/reviews.log" 2>/dev/null | sort -u); do
    [ -s "$(review_file "$1" "$sha")" ] && _review_awk items < "$(review_file "$1" "$sha")"
  done | awk -F '\t' -v c="$2" -v f="$3" '$1 == c && $2 == f && !s[$3]++ { print $3 }' |
    while IFS= read -r l; do echo "- PR #$1: $(oneline 200 "$(sed -E 's/^([0-9]+[.)]|[-*+])[[:space:]]+//' <<<"$l")")"; done
}

# recurring_issue <class> <file>: the issue recorded for the key (recurring: `<class> <file> <issue>`)
recurring_issue() {
  awk -F '\t' -v c="$1" -v f="$2" '$1 == c && $2 == f { n = $3 } END { print n }' "$CANCCU_HOME/recurring" 2>/dev/null
}

# _issue_state <n>: OPEN or CLOSED; this pass's open list first (it is capped, so a miss asks gh).
# Fails on a gh error.
_issue_state() {
  [ "$(jqr --argjson n "$1" 'any(.[]; .number == $n)' <<<"$ISSUES" 2>/dev/null)" = true ] && { echo OPEN; return 0; }
  local s; s=$(ghj issue view "$1" -R "$REPO" --json state 2>/dev/null | jqr '.state // empty') && [ -n "$s" ] || return 1
  echo "$s"
}

# recur_check <pr> <keys>: each key raised on FINDINGS_RECUR PRs within the window gets its issue: a
# comment on the recorded one while it is open, else a new one, never `ready` (a person decides
# what is built of it). A gh error is logged and the key waits for the next PR that raises it: the
# merge never waits for this.
recur_check() {
  local pr=$1 c f prs n s what who p body
  while IFS=$'\t' read -r c f; do
    [ -n "$c" ] || continue
    prs=$(_recur_prs "$c" "$f")
    (( $(grep -c . <<<"$prs") >= $(_recur_n) )) || continue
    what="recurring finding $c in $f"
    n=$(recurring_issue "$c" "$f")
    if [ -n "$n" ]; then s=$(_issue_state "$n") || { log "$what: gh error reading #$n; skipped"; continue; }; fi
    if [ -n "$n" ] && [ "$s" = OPEN ]; then
      mut gh issue comment "$n" -R "$REPO" --body "$(home_tilde "PR #$pr raised it again:"$'\n\n'"$(_recur_lines "$pr" "$c" "$f")")"$'\n\n'"$CANCCU_MARK" ||
        { log "$what: commenting PR #$pr on #$n failed (gh)"; continue; }
      log "$what: PR #$pr commented on #$n"
      continue
    fi
    who="the product owner decides (\`LEADER=off\`)"; [ "${LEADER:-off}" = on ] && who="the leader decides"
    body="Findings of class \`$c\` in \`$f\` were raised on $(grep -c . <<<"$prs") merged PRs within $(_recur_days) days (\`FINDINGS_RECUR\`, \`FINDINGS_RECUR_DAYS\`):"$'\n\n'
    for p in $prs; do body+="$(_recur_lines "$p" "$c" "$f")"$'\n'; done
    body+=$'\n'"Proposal: fix it at the source, not once more in each PR: a rule in \`AGENTS.md\` or \`REVIEW.md\`, a line in the worker prompt, a lint or a test."$'\n\n'"Who decides: $who what is built of it. This issue is not \`ready\`."
    mut_out gh issue create -R "$REPO" --title "Recurring finding: $c in $f" --body "$(home_tilde "$body")"$'\n\n'"$CANCCU_MARK" ||
      { log "$what: creating the issue failed (gh)"; continue; }
    n=$(grep -oE '/issues/[0-9]+' <<<"$MUT_OUT" | grep -oE '[0-9]+$' | tail -1)
    [ -n "$n" ] || { log "$what: created an issue but read no number from gh"; continue; }
    { awk -F '\t' -v c="$c" -v f="$f" '!($1 == c && $2 == f)' "$CANCCU_HOME/recurring" 2>/dev/null; printf '%s\t%s\t%s\n' "$c" "$f" "$n"; } \
      > "$CANCCU_HOME/recurring.tmp" && mv "$CANCCU_HOME/recurring.tmp" "$CANCCU_HOME/recurring"
    log "$what: #$n"
  done <<<"$2"
  return 0
}

# recurring_open_line: the open recurring-finding issues (this pass's open list), for canccu-status;
# nothing when there are none
recurring_open_line() {
  local c f n out=""
  while IFS=$'\t' read -r c f n; do
    [ -n "$n" ] && [ "$(jqr --argjson n "$n" 'any(.[]; .number == $n)' <<<"$ISSUES" 2>/dev/null)" = true ] || continue
    out+="${out:+, }#$n $c in $f"
  done < <(cat "$CANCCU_HOME/recurring" 2>/dev/null)
  [ -z "$out" ] || echo "recurring findings (a person decides): $out"
}
