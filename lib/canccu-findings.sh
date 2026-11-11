# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): review findings. Only blocking findings
# start a fix round: a fix round costs a whole worker run, and minor findings rarely justify one.
# The reviewer lists the rest under `Non-blocking:`; they go to one follow-up issue per wave (the
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

# nonblocking_of <review body>: the items of its Non-blocking section, blank lines and "none" dropped
nonblocking_of() {
  awk -v want=1 "$_NB_AWK" <<<"$1" | grep -v '^[[:space:]]*$' | grep -viE '^[[:space:]*_-]*(none|n/a|nothing)[[:space:].]*$' || true
}
# blocking_of <review body>: the review without that section (its findings, accept, risk, verdict)
blocking_of() { awk -v want=0 "$_NB_AWK" <<<"$1" | cat -s; }

# followup_key <K>: whose follow-up issue the unit's findings go to: its step's wave, the step's
# health pass, or the fast lane (an issue outside any wave)
followup_key() {
  local m; m=$(st_get "$1" step)
  if [ -z "$m" ]; then echo fast
  elif is_health "$1"; then echo "step-$m-health"
  else echo "step-$m-wave-$(st_get "$1" wave)"; fi
}
followup_title() {
  local m; m=$(st_get "$1" step)
  case $(followup_key "$1") in
    fast) echo "Follow-ups: non-blocking review findings (fast lane)" ;;
    *-health) echo "Follow-ups: non-blocking review findings, step $(step_title "$m"), health pass" ;;
    *) echo "Follow-ups: non-blocking review findings, step $(step_title "$m"), wave $(st_get "$1" wave)" ;;
  esac
}

# file_nonblocking <K> <pr> <sha> <items>: the items go to the unit's follow-up issue: a comment on
# the recorded one while it is open (this pass's open issues list it), else a new issue, not
# `ready` (the maintainer decides what of it gets built). A recorded issue that is the unit or that
# the PR closes counts as not open: the merge would close the findings with it. A gh error is
# logged: the items are still in the PR's review comment, and the merge never waits for them.
file_nonblocking() {
  local k=$1 pr=$2 sha=$3 items=$4 key f="" text n
  key=$(followup_key "$k")
  f=$(awk -F '\t' -v k="$key" '$1 == k { n = $2 } END { print n }' "$CANCCU_HOME/followups" 2>/dev/null)
  # an item starts at column 0; its own indented lines (a "- Fix:") are not findings of their own
  n=$(grep -cE '^([0-9]+[.)]|[-*])[[:space:]]' <<<"$items"); (( n )) || n=$(grep -c . <<<"$items")
  text="From the review of PR #$pr ($(pr_what "$k"), head ${sha:0:7}), its non-blocking findings:"$'\n\n'"$items"
  if [ -n "$f" ] && [ "$f" != "$k" ] && [ "$(jqr --argjson n "$f" 'any(.[]; .number == $n)' <<<"$ISSUES")" = true ] &&
     [ "$(pr_get "$pr" '[.closingIssuesReferences[]?.number]' | jqr --argjson n "$f" 'index($n) == null')" != false ]; then
    mut gh issue comment "$f" -R "$REPO" --body "$(home_tilde "$text")"$'\n\n'"$CANCCU_MARK" ||
      { log "#$k PR #$pr: filing its non-blocking findings in #$f failed (gh); they stay in the review comment"; return 0; }
  else
    (( CANCCU_DRY )) && { mut gh issue create -R "$REPO" --title "$(followup_title "$k")"; return 0; }
    mut_out gh issue create -R "$REPO" --title "$(followup_title "$k")" \
      --body "Non-blocking review findings, collected by the dispatcher instead of a fix round. Pick what is worth building into issues of its own."$'\n\n'"$(home_tilde "$text")"$'\n\n'"$CANCCU_MARK" ||
      { log "#$k PR #$pr: creating the follow-up issue failed (gh); its non-blocking findings stay in the review comment"; return 0; }
    f=$(grep -oE '/issues/[0-9]+' <<<"$MUT_OUT" | grep -oE '[0-9]+$' | tail -1)
    [ -n "$f" ] || { log "#$k PR #$pr: created a follow-up issue but read no number from gh"; return 0; }
    { grep -v "^$key"$'\t' "$CANCCU_HOME/followups" 2>/dev/null; printf '%s\t%s\n' "$key" "$f"; } > "$CANCCU_HOME/followups.tmp" &&
      mv "$CANCCU_HOME/followups.tmp" "$CANCCU_HOME/followups"
    # this pass's list too: a second PR passing in the same pass comments instead of creating another
    ISSUES=$(jq -c --argjson n "$f" --arg t "$(followup_title "$k")" '. + [{number: $n, title: $t, labels: [], milestone: null, body: ""}]' <<<"$ISSUES")
  fi
  log "#$k PR #$pr: $n non-blocking finding(s) filed in #$f"
}

# collect_nonblocking <K> <pr> <sha> <review body> <verdict at>: file the verdict's non-blocking
# items once (nb_at): a step that fails after it sees the same verdict again next pass
collect_nonblocking() {
  local items
  [ "$(st_get "$1" nb_at)" = "$5" ] && return 0
  items=$(nonblocking_of "$4")
  [ -n "$items" ] && file_nonblocking "$1" "$2" "$3" "$items"
  st_set "$1" nb_at="$5"
}

# ---------------------------------------------------------------- the report

# findings_report: the most common findings across the review records (reviews/<pr>/<sha>.md, the
# files the reviewers wrote), so the maintainer can turn them into rules in AGENTS.md. Findings are
# free text: each item line is cut to its gist (file:line refs, list marks and markdown dropped,
# then everything from its first separator on, lower case), and equal gists are counted. The files
# cited most come after, each counted once per PR.
findings_report() {
  local files recs
  files=$(find "$CANCCU_HOME/reviews" -mindepth 2 -maxdepth 2 -name '*.md' ! -name '*.findings.md' ! -name '*.open.md' 2>/dev/null | sort)
  [ -n "$files" ] || { echo "no review records in ${CANCCU_HOME/#$HOME/\~}/reviews"; return 0; }
  # one record per item: G <pr> <gist>, and per cited file: F <pr> <file>. C locale: the dashes are
  # matched as their bytes.
  # shellcheck disable=SC2086
  recs=$(LC_ALL=C awk '
    FNR == 1 { pr = FILENAME; sub(/\/[^\/]*$/, "", pr); sub(/.*\//, "", pr) }
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]*_]*[^[:space:]]+\.[[:alnum:]]+:[0-9]+/ {
      l = $0
      while (match(l, /[[:alnum:]_.\/-]+\.[[:alnum:]]+:[0-9]+(-[0-9]+)?/)) {
        f = substr(l, RSTART, RLENGTH); sub(/:[0-9-]+$/, "", f); print "F\t" pr "\t" f
        l = substr(l, 1, RSTART - 1) " " substr(l, RSTART + RLENGTH)
      }
      gsub(/[*_`]/, "", l); sub(/^[[:space:]]*([-+]|[0-9]+[.)])?[[:space:]]*/, "", l)
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
