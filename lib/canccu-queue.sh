# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the queue: blockers, the one-at-a-time lock, candidates, runnable.

# ---------------------------------------------------------------- queue

# blockers_open <n>: open issues that block n: the dependencies API plus "Blocked by #x" lines in
# its body. Prints "?" when the API fails (treated as blocked).
blockers_open() {
  local n=$1 api b c=${BLOCKERS_CACHE:-}
  if [ -n "$c" ] && [ -f "$c/$n" ]; then cat "$c/$n"; return 0; fi
  if [ -n "$c" ] && [ -d "$c" ]; then BLOCKERS_CACHE="" blockers_open "$n" > "$c/$n.tmp" && mv -f "$c/$n.tmp" "$c/$n"; cat "$c/$n" 2>/dev/null; return 0; fi
  if api=$(ghj api "repos/$REPO/issues/$n/dependencies/blocked_by" 2>/dev/null); then
    jqr '.[] | select(.state == "open") | .number' <<<"$api"
  else echo "?"; fi
  blockers_in_body "$n"
}
# blocked_by_refs <n>: every issue named on issue n's "Blocked by #k" lines, open or closed (no GitHub read)
blocked_by_refs() {
  jqr --argjson n "$1" '.[] | select(.number == $n) | .body // "" | split("\n")[]
    | select(test("blocked by"; "i")) | [scan("#([0-9]+)")[] | tonumber][]' <<<"$ISSUES"
}
# blockers_in_body <n>: the open issues named on issue n's "Blocked by #k" lines (no GitHub read)
blockers_in_body() {
  local b
  for b in $(blocked_by_refs "$1"); do is_open "$b" && echo "$b"; done
  return 0
}

# is_exclusive <n>: the issue is of the one-at-a-time kind (the rules): it has EXCLUSIVE_LABEL,
# or its body or its plan on origin/main matches EXCLUSIVE_PATTERN
is_exclusive() {
  [ -n "$EXCLUSIVE_LABEL" ] && has_label "$1" "$EXCLUSIVE_LABEL" && return 0
  [ -n "$EXCLUSIVE_PATTERN" ] || return 1
  jqr --argjson n "$1" '.[] | select(.number == $n) | .body // ""' <<<"$ISSUES" | grep -qE "$EXCLUSIVE_PATTERN" && return 0
  guard 10 git -C "$CLONE" show "origin/main:docs/plans/issue-$1.md" 2>/dev/null | grep -qE "$EXCLUSIVE_PATTERN"
}
exclusive_busy() {
  local m
  for m in $(managed); do [ "$(st_get "$m" exclusive)" = 1 ] && is_open "$m" && { echo "$m"; return 0; }; done
  return 1
}

# MILESTONE_KEY_JQ: the jq def of the milestone order, for the queue and the monitor's milestone bars: the title's
# leading number, "Parallel tracks" between 2 and 3, a title without a number after the numbered
# ones, no milestone (null) last
MILESTONE_KEY_JQ='def milestone_key: if . == null then 1e9
  elif test("^\\s*parallel tracks\\b"; "i") then 2.5
  else ((capture("^\\s*(?<d>[0-9]+)") | .d | tonumber) // 1e8) end;'
# candidates: the fast lane: ready issues with no milestone or labelled fast, not taken yet and in
# no package (the issues of a step run as its packages), in order: the milestone's leading number ("Parallel
# tracks" between 2 and 3; a title without a number after the numbered ones; no milestone last),
# the epic's Order: line, the issue number
candidates() {
  local m; m=" $(managed | tr '\n' ' ') "
  jqr "$MILESTONE_KEY_JQ"'( [ .[] | select(any(.labels[]; .name == "epic")) | .body // "" | split("\n")[]
           | select(test("^\\s*\\**Order:")) | [scan("#([0-9]+)")[] | tonumber] ]
         | map(to_entries | map({ key: (.value | tostring), value: .key })) | add // [] | from_entries ) as $ord
    | [ .[] | select([.labels[].name] as $l | ($l | index("ready")) and
                     ([$l[] | select(IN("epic", "checkpoint", "in-progress", "needs-you", "awaiting-accept"))] | length == 0)
                     and (.milestone == null or ($l | index("fast"))))
        | { n: .number, o: ($ord[.number | tostring] // 99999),
            m: (.milestone.title // null | milestone_key) } ]
    | sort_by(.m, .o, .n)[] | .n' <<<"$ISSUES" |
    while read -r n; do [[ $m == *" $n "* ]] || [ "$(unit_of_issue "$n")" != "$n" ] || echo "$n"; done
}

# waiting_for_po: open issues the user has not released yet: not an epic, neither ready nor
# blocked, not in progress or managed, and not the digest issue
waiting_for_po() {
  local n
  jqr --argjson d "${DIGEST_ISSUE:-0}" '.[] | select(.number != $d) | select([.labels[].name] as $l
      | ($l | index("ready") | not) and ($l | index("blocked") | not) and ($l | index("epic") | not)
        and ($l | index("in-progress") | not)) | .number' <<<"$ISSUES" |
    while read -r n; do is_managed "$n" || echo "$n"; done
}

# queue_list [max runnable] [max lines]: the candidates in the order they are taken, one per line
# "<n><TAB><0: runnable, 1: waits><TAB><why it waits>", honouring the one-at-a-time lock. Stops
# after max runnable ones (each line costs a blockers read) or max lines.
queue_list() {
  local max=${1:-999} lim=${2:-999} n c=0 l=0 busy b
  busy=$(exclusive_busy)
  for n in $(candidates); do
    (( c < max && l < lim )) || break
    l=$((l + 1))
    b=$(blockers_open "$n" | sort -u | tr '\n' ' ')
    if [ -n "${b// }" ]; then printf '%s\t1\tblocked by %s\n' "$n" "${b% }"; continue; fi
    if is_exclusive "$n"; then
      [ -n "$busy" ] && { printf '%s\t1\twaits: one-at-a-time issue #%s is open\n' "$n" "$busy"; continue; }
      busy=$n   # one such issue per list too
    fi
    printf '%s\t0\t\n' "$n"; c=$((c + 1))
  done
}

# runnable [max]: candidates whose blockers are all closed, honouring the one-at-a-time lock
# (VERBOSE=1: why the others wait, on stderr)
runnable() {
  local n w why
  while IFS=$'\t' read -r n w why; do
    if (( w )); then [ -n "${VERBOSE:-}" ] && echo "  #$n $why" >&2
    else echo "$n"; fi
  done < <(queue_list "${1:-999}")
  return 0
}
