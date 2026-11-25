# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): review findings. Only blocking findings
# start a fix round: a fix round costs a whole worker run, and minor findings rarely justify one.
# The reviewer lists the rest under `Non-blocking:`; they go to one follow-up ticket per step (the
# fast lane shares one), and canccu-status --findings counts the common ones across the records.

# The Non-blocking section: its heading line (markdown marks around it allowed, items may follow on
# it), up to a Maintainer accept:, Risk: or Review verdict: line, or the next markdown heading.
_NB_AWK='
  function stop(l) { return l ~ /^[[:space:]*_>]*(Maintainer accept:|Risk:|Review verdict:)/ || l ~ /^#+[[:space:]]/ }
  !on && tolower($0) ~ /^[[:space:]#*_>-]*non-blocking/ {
    on = 1; rest = $0; sub(/^[^:]*[Nn]on-[Bb]locking[^[:alnum:]]*/, "", rest); sub(/^[*_[:space:]]+/, "", rest)
    if (want && rest != "") print rest
    next
  }
  on && stop($0) { on = 0 }
  (on && want) || (!on && !want) { print }'

# nonblocking_of <review body>: what goes to the follow-up issue. A body with the block of §8
# (review_valid): every item but the blocking ones left (Non-blocking:, the demoted, Pre-existing:).
# Else (a verdict posted by hand, or from before §8) the items of its Non-blocking section, blank
# lines and "none" dropped.
nonblocking_of() {
  if review_valid "$1"; then _review_awk moved <<<"$1"; return; fi
  awk -v want=1 "$_NB_AWK" <<<"$1" | grep -v '^[[:space:]]*$' | grep -viE '^[[:space:]*_-]*(none|n/a|nothing)[[:space:].]*$' || true
}
# blocking_of <review body>: what the fix round fixes. With the block of §8, only the blocking
# items left; else the review without its Non-blocking section (findings, accept, risk, verdict).
blocking_of() {
  if review_valid "$1"; then _review_awk kept <<<"$1"; return; fi
  awk -v want=0 "$_NB_AWK" <<<"$1" | cat -s
}
# blocking_numbered <review body>: blocking_of with each finding as "Finding <i>: <item>", so the
# fix-check can be held to one line per finding (fixcheck_gaps). Without the block of §8 there
# are no items to number: blocking_of's text as it is.
blocking_numbered() {
  if review_valid "$1"; then _review_awk keptn <<<"$1"; return; fi
  blocking_of "$1"
}
# finding_count <findings>: the highest "Finding <i>:" number; 0 for unnumbered findings
finding_count() { grep -oE '^Finding [0-9]+:' <<<"$1" | grep -oE '[0-9]+' | sort -n | tail -1 | grep . || echo 0; }
# fixcheck_gaps <findings> <fix-check body>: "<missing> | <open>", the numbers (space-separated)
# the fix-check gives no outcome for, and those it says are not fixed or broken; nothing when it
# says each one is fixed. The reviewer may bold or list the line: only its number and word count.
fixcheck_gaps() {
  local n i w miss="" open=""
  n=$(finding_count "$1")
  for ((i = 1; i <= n; i++)); do
    w=$(grep -ioE "^[[:space:]>*_-]*finding[[:space:]]+${i}[*_]*:[*_[:space:]]*(fixed|not fixed|broken)" <<<"$2" | head -1)
    w=${w,,}
    case $w in *'not fixed'|*broken) open+=" $i" ;; *fixed) ;; *) miss+=" $i" ;; esac
  done
  [ -n "$miss$open" ] && echo "${miss# } | ${open# }"
  return 0
}

# followup_key <K>: whose follow-up ticket the unit's findings go to: its step's (every wave, the
# health pass, the deep review and the cadence rounds of it), or the fast lane's (an issue outside
# any step). The leader triages one ticket per step, not one per wave (#223).
followup_key() { local m; m=$(st_get "$1" step); if [ -z "$m" ]; then echo fast; else echo "step-$m"; fi; }
# followup_title <K> [part]
followup_title() {
  local m t; m=$(st_get "$1" step)
  if [ -z "$m" ]; then t="Follow-ups: fast lane"; else t="Follow-ups: step $(step_title "$m")"; fi
  (( ${2:-1} > 1 )) && t+=" (part $2)"
  echo "$t"
}
# GitHub refuses a body over 65536 characters; the margin leaves room for the line to the next part
FOLLOWUP_BODY_MAX=60000

# followup_lines <items> <links>: the items as checklist lines, so the leader ticks them off in one
# place; an item's own indented lines stay under it. <links>: "<item's first line>\t<issue>" lines,
# the security items' own issues. Without list marks, each line is an item.
followup_lines() {
  local marked=0
  grep -qE '^([0-9]+[.)]|[-*+])[[:space:]]' <<<"$1" && marked=1
  FU_LINKS=$2 awk -v marked=$marked '
    BEGIN { n = split(ENVIRON["FU_LINKS"], a, "\n"); for (i = 1; i <= n; i++) if (split(a[i], p, "\t") == 2) link[p[1]] = p[2] }
    /^[[:space:]]*$/ { next }
    /^([0-9]+[.)]|[-*+])[[:space:]]/ || (!marked && /^[^[:space:]]/) {
      t = $0; sub(/^([0-9]+[.)]|[-*+])[[:space:]]+/, "", t)
      print "- [ ] " t (($0 in link) ? " (security: #" link[$0] ")" : ""); next
    }
    { sub(/^[[:space:]]+/, ""); print "  " $0 }' <<<"$1"
}

# followup_security <K> <pr> <sha> <items> <first lines>: an issue of its own, labelled security,
# for each pre-existing security finding: it never blocks the PR, and in a ticket of nits it would
# wait its turn. Prints "<first line>\t<issue>" for each one made.
followup_security() {
  local l t body
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    t=${l#[-*+] }; t=${t:0:90}
    body="A pre-existing security finding of the review of PR #$2 $(pr_what "$1"), head ${3:0:7}; it does not block that PR:"$'\n\n'
    body+=$(FU_L=$l awk '$0 == ENVIRON["FU_L"] { on = 1; print; next } on && /^[^[:space:]]/ { exit } on' <<<"$4")
    mut_out gh issue create -R "$REPO" --title "Security (pre-existing): $t" --label security \
      --body "$(home_tilde "$body")"$'\n\n'"$CANCCU_MARK" || { log "#$1 PR #$2: creating the security issue failed (gh); the finding stays in the ticket"; continue; }
    t=$(grep -oE '/issues/[0-9]+' <<<"$MUT_OUT" | grep -oE '[0-9]+$' | tail -1)
    [ -n "$t" ] && printf '%s\t%s\n' "$l" "$t" && log "#$1 PR #$2: its pre-existing security finding is #$t"
  done <<<"$5"
}

# file_nonblocking <K> <pr> <sha> <items> [security first lines]: the items go into the body of the
# key's follow-up ticket, under a heading per verdict, never into comments: one list to triage
# (#223). The ticket recorded last for the key (followups: "<key>\t<issue>\t<part>" rows, appended,
# so the deep review sees each part) while it is open (this pass's open issues list it), else a new
# one, not `ready` (the leader decides what of it gets built), in the step's milestone. A recorded
# ticket that is the unit or that the PR closes counts as not open: the merge would close the
# findings with it. A body that would pass FOLLOWUP_BODY_MAX opens the next part, linked from the
# full one. A gh error is logged: the items are still in the PR's review comment, and the merge
# never waits for them.
file_nonblocking() {
  local k=$1 pr=$2 sha=$3 items=$4 key f="" part=1 n n2 w sec links="" body new ms="" m lead text
  key=$(followup_key "$k")
  [ -e "$CANCCU_HOME/followups" ] &&
    IFS=: read -r f part < <(awk -F '\t' -v k="$key" '$1 == k { n = $2; p = $3 } END { print n ":" (p > 1 ? p : 1) }' "$CANCCU_HOME/followups")
  # an item starts at column 0; its own indented lines (a "- Fix:") are not findings of their own
  n=$(grep -cE '^([0-9]+[.)]|[-*])[[:space:]]' <<<"$items"); (( n )) || n=$(grep -c . <<<"$items")
  [ -z "${5:-}" ] || links=$(followup_security "$k" "$pr" "$sha" "$items" "$5")
  w=$(pr_what "$k"); w=${w#(}; w=${w%)}
  sec="### PR #$pr ($w, ${sha:0:7})"$'\n\n'"$(followup_lines "$items" "$links")"
  if [ -n "$f" ] && [ "$f" != "$k" ] && [ "$(jqr --argjson n "$f" 'any(.[]; .number == $n)' <<<"$ISSUES")" = true ] &&
     [ "$(pr_get "$pr" '[.closingIssuesReferences[]?.number]' | jqr --argjson n "$f" 'index($n) == null')" != false ]; then
    body=$(jqr --argjson n "$f" '.[] | select(.number == $n) | .body // ""' <<<"$ISSUES" | tr -d '\r')
    body=$(printf '%s' "${body%"$CANCCU_MARK"}")
    new="$body"$'\n\n'"$(home_tilde "$sec")"$'\n\n'"$CANCCU_MARK"
    if (( ${#new} <= FOLLOWUP_BODY_MAX )); then
      mut gh issue edit "$f" -R "$REPO" --body "$new" ||
        { log "#$k PR #$pr: filing its non-blocking findings in #$f failed (gh); they stay in the review comment"; return 0; }
      ISSUES=$(jq -c --argjson n "$f" --arg b "$new" 'map(if .number == $n then .body = $b else . end)' <<<"$ISSUES")
      log "#$k PR #$pr: $n non-blocking finding(s) filed in #$f"; return 0
    fi
    lead="Part $((part + 1)); part $part is #$f."$'\n\n'; part=$((part + 1))
  else
    lead="" part=1 body=""
  fi
  m=$(st_get "$k" step)
  [ -z "$m" ] || ms=$(jqr --argjson m "$m" '.[] | select(.number == $m) | .title' <<<"$MILESTONES")
  if [ -z "$m" ]; then w="the fast lane (issues outside any step)"; else w="step $(step_title "$m")"; fi
  text="Non-blocking review findings of $w, collected by the dispatcher instead of a fix round: a section per review, a line per finding. Pick what is worth building into issues of its own, and tick a line once it is handled."
  text+=$'\n\n'"$lead$(home_tilde "$sec")"$'\n\n'"$CANCCU_MARK"
  mut_out gh issue create -R "$REPO" --title "$(followup_title "$k" "$part")" --label follow-up ${ms:+--milestone "$ms"} --body "$text" ||
    { log "#$k PR #$pr: creating the follow-up ticket failed (gh); its non-blocking findings stay in the review comment"; return 0; }
  (( CANCCU_DRY )) && return 0
  n2=$(grep -oE '/issues/[0-9]+' <<<"$MUT_OUT" | grep -oE '[0-9]+$' | tail -1)
  [ -n "$n2" ] || { log "#$k PR #$pr: created a follow-up ticket but read no number from gh"; return 0; }
  printf '%s\t%s\t%s\n' "$key" "$n2" "$part" >> "$CANCCU_HOME/followups"
  # the full part links the next; its findings stay as they are
  if [ -n "$lead" ]; then
    mut gh issue edit "$f" -R "$REPO" --body "$body"$'\n\n'"Continued in #$n2."$'\n\n'"$CANCCU_MARK" || log "#$k PR #$pr: linking #$n2 from #$f failed (gh)"
  fi
  # this pass's list too: a second PR passing in the same pass files into it instead of making another
  ISSUES=$(jq -c --argjson n "$n2" --arg t "$(followup_title "$k" "$part")" --arg b "$text" '. + [{number: $n, title: $t, labels: [{name: "follow-up"}], milestone: null, body: $b}]' <<<"$ISSUES")
  log "#$k PR #$pr: $n non-blocking finding(s) filed in #$n2"
}

# collect_nonblocking <K> <pr> <sha> <review body> <verdict at>: file the verdict's non-blocking
# (and demoted and pre-existing) items once (nb_at): a step that fails after it sees the same verdict again next pass.
# Once per head and kind too (nb_sha <pr>:<sha>:<light|full>): a second verdict of a kind on a
# head finds the same items (#214), but the full review after a light one looks deeper.
collect_nonblocking() {
  local items sec key kind=full
  [ "$(st_get "$1" nb_at)" = "$5" ] && return 0
  [ "$(cat "$(light_file "$2")" 2>/dev/null)" = "$3" ] && kind=light
  key=$2:$3:$kind
  if [ "$(st_get "$1" nb_sha)" = "$key" ]; then
    log "#$1 PR #$2: non-blocking findings of ${3:0:7} are filed already; not filed again"
    st_set "$1" nb_at="$5"; return 0
  fi
  items=$(nonblocking_of "$4")
  sec=$(preexisting_security "$4") || sec=""
  if [ -n "$items" ]; then file_nonblocking "$1" "$2" "$3" "$items" "$sec"; st_set "$1" nb_sha="$key"; fi
  st_set "$1" nb_at="$5"
}

# ---------------------------------------------------------------- the report

# findings_report: the most common findings across the review records (reviews/<pr>/<sha>.md, the
# files the reviewers wrote), so the leader can turn them into rules in AGENTS.md. Findings are
# free text: each item line is cut to its gist (file:line refs, list marks and markdown dropped, a
# leading [class] tag dropped, then everything from its first separator on cut, lower case), and
# equal gists are counted. The Change: block is no finding. The files cited most come after, each
# counted once per PR.
findings_report() {
  local files recs
  files=$(find "$CANCCU_HOME/reviews" -mindepth 2 -maxdepth 2 -name '*.md' ! -name '*.findings.md' ! -name '*.open.md' 2>/dev/null | sort)
  [ -n "$files" ] || { echo "no review records in ${CANCCU_HOME/#$HOME/\~}/reviews"; return 0; }
  # one record per item: G <pr> <gist>, and per cited file: F <pr> <file>. C locale: the dashes are
  # matched as their bytes.
  # shellcheck disable=SC2086
  recs=$(LC_ALL=C awk '
    FNR == 1 { pr = FILENAME; sub(/\/[^\/]*$/, "", pr); sub(/.*\//, "", pr); chg = 0 }
    # the Change: block (three plain sentences on what the PR changes) holds no findings
    /^Change:[[:space:]]*$/ { chg = 1; next }
    chg && /^[[:space:]]*[-*+][[:space:]]/ { next }
    { chg = 0 }
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]*_]*[^[:space:]]+\.[[:alnum:]]+:[0-9]+/ || /^[[:space:]*_]*[^[:space:]]+\/[^[:space:]]+:[0-9]+/ {
      l = $0
      while (match(l, /([[:alnum:]_.\/-]+\.[[:alnum:]]+|[[:alnum:]_.-]+(\/[[:alnum:]_.-]+)+):[0-9]+(,[0-9]+|-[0-9]+)*/)) {
        f = substr(l, RSTART, RLENGTH); sub(/:[0-9,-]+$/, "", f); print "F\t" pr "\t" f
        l = substr(l, 1, RSTART - 1) " " substr(l, RSTART + RLENGTH)
      }
      gsub(/[*_`]/, "", l); sub(/^[[:space:]]*([-+]|[0-9]+[.)])?[[:space:]]*/, "", l)
      sub(/^\[[[:alnum:]-]+\][[:space:]]*/, "", l)
      sub(/^([[:space:]:;,.-]|\342\200\224|\342\200\223)+/, "", l)
      sub(/[[:space:]]*(\342\200\224|\342\200\223| - |:|;|,|\.[[:space:]]|\.$).*/, "", l)
      l = tolower(l); gsub(/[[:space:]]+/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l)
      if (length(l) < 4 || l ~ /^(review verdict|maintainer accept|risk|non-blocking)/) next
      print "G\t" pr "\t" substr(l, 1, 80)
    }' $files)
  echo "the most common review findings (${FINDINGS_TOP:-15} at most):"
  LC_ALL=C awk -F '\t' '$1 == "G" { n[$3]++; if (!s[$3 SUBSEP $2]++) p[$3] = p[$3] (p[$3] ? ", " : "") "#" $2 }
    END { for (g in n) printf "%d\t%s\t%s\n", n[g], g, p[g] }' <<<"$recs" |
    sort -t $'\t' -k1,1nr -k2,2 | head -n "${FINDINGS_TOP:-15}" | awk -F '\t' '{ printf "  %d× %s (%s)\n", $1, $2, $3 }'
  echo "the files cited most:"
  awk -F '\t' '$1 == "F" && !s[$2 SUBSEP $3]++ { n[$3]++ } END { for (f in n) printf "%d\t%s\n", n[f], f }' <<<"$recs" |
    sort -t $'\t' -k1,1nr -k2,2 | head -n 10 | awk -F '\t' '{ printf "  %d× %s\n", $1, $2 }'
}
