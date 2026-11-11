# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): GitHub data of one pass, whose PRs, CI, verdicts and the merge classifier.

# ---------------------------------------------------------------- GitHub data (one pass)

ISSUES='[]' PRS='[]' AUTO_MERGE_ALLOWED="" MERGE_METHOD="" MF=()
fetch() {
  AUTO_MERGE_ALLOWED="" MERGE_METHOD=""   # read again (auto_merge_read, merge_method_read) in each pass that merges
  ISSUES=$(ghj issue list -R "$REPO" -s open -L 300 --json number,title,labels,milestone,body) && fetch_prs
}
# fetch_prs: this pass's open PRs (read again where a stale list would mislead: reap_worker)
fetch_prs() {
  local p
  p=$(ghj pr list -R "$REPO" -s open -L 300 --json number,title,url,isDraft,headRefOid,headRefName,author,isCrossRepository,autoMergeRequest,labels,closingIssuesReferences,body,statusCheckRollup) &&
    PRS=$p
}

# is_open, labels_of, has_label, title_of take a unit key too (lib/canccu-units.sh): a package is
# open while a member is; its labels and title are its lead issue's
is_open() { unit_open "$1"; }
labels_of() { local l; l=$(lead_of "$1"); [ -n "$l" ] || return 0; jqr --argjson n "$l" '.[] | select(.number == $n) | .labels[].name' <<<"$ISSUES"; }
has_label() { labels_of "$1" | grep -qx "$2"; }
title_of() { unit_title "$1"; }
# A PR is ours for issue n when it comes from a branch in REPO (not a fork), is authored by
# USER_LOGIN and its branch is the one the worker prompt names (<n>-<slug>; issue-<n>-… too: the
# name CLAUDE.md's `<n>` flow gives a branch, which a session by hand follows and whose PR the
# pass adopts), and the dispatcher manages n. Only such a PR is ever reviewed, merged or commented on.
# pr_foreign <pr json> <n>: why the PR itself is not ours for issue n; nothing when it is
pr_foreign() {
  if is_pkg "$2"; then
    jqr --arg b "$(unit_branch "$2")" --arg u "$USER_LOGIN" 'if .isCrossRepository != false then "PR #\(.number) is from a fork"
      elif (.author.login // "") != $u then "PR #\(.number) is by \(.author.login // "nobody"), not \($u)"
      elif $b == "" or ((.headRefName // "") | . != $b and . != "\($b)-contract") then "PR #\(.number) branch \(.headRefName) is not \($b)"
      else empty end' <<<"$1"
    return
  fi
  jqr --argjson n "$2" --arg u "$USER_LOGIN" 'if .isCrossRepository != false then "PR #\(.number) is from a fork"
    elif (.author.login // "") != $u then "PR #\(.number) is by \(.author.login // "nobody"), not \($u)"
    elif ((.headRefName // "") | test("^(issue-)?\($n)(-|$)") | not) then "PR #\(.number) branch \(.headRefName) is not \($n)-…"
    else empty end' <<<"$1"
}
# pr_not_ours <pr json> <n> [adoptable]: pr_foreign, plus the issue the dispatcher must manage
# (with "adoptable", an in-progress issue counts: the next pass adopts it). The one rule every
# caller uses.
pr_not_ours() {
  local why; why=$(pr_foreign "$1" "$2")
  if [ -z "$why" ] && ! is_managed "$2"; then
    [ "${3:-}" = adoptable ] && has_label "$2" in-progress || why="#$2 is not managed by the dispatcher"
  fi
  printf '%s' "$why"
}
# A unit's contract-first PR (a repo's rule "a contract change is its own PR and merges first") is
# the one on its branch plus -contract. It closes none of the unit's issues: it is reviewed and
# merged first (pr_for prefers it while open), then the unit goes on in its own PR (contract_back).
# is_contract_pr <K> <head branch>
is_contract_pr() { local b; b=$(unit_branch "$1"); [ -n "$b" ] && [ "$2" = "$b-contract" ]; }

# PR_ISSUES_JQ: jq defs; pr_named: the issues a PR (gh's JSON) names: those it closes and
# those a line "Plan for #n" names (a plan-only PR does not close its issue: the build follows);
# pr_issues: those, or with neither, the one its branch <n>-… (or issue-<n>-…) names
PR_ISSUES_JQ='def plan_for: [(.body // "") | split("\n")[] | select(test("^[\\s*_>`-]*plan for #[0-9]+"; "i"))
    | capture("#(?<n>[0-9]+)").n | tonumber];
  def pr_named: [.closingIssuesReferences[]?.number] + plan_for | unique;
  def pr_issues: pr_named as $r
    | if ($r | length) > 0 then $r
      else [(.headRefName // "") | capture("^(issue-)?(?<n>[0-9]+)(-|$)").n | tonumber] end;'
# pr_issues <pr json>: those issues, one per line
pr_issues() { jqr "$PR_ISSUES_JQ"' pr_issues[]' <<<"$1"; }

# not_ours <pr>: why an open PR is none of the dispatcher's business; nothing when it is ours
not_ours() {
  local j n why=""
  j=$(pr_get "$1" .)
  # a package's PR: its branch names the unit
  n=$(unit_of_branch "$(jqr '.headRefName // ""' <<<"$j")")
  if [ -n "$n" ]; then pr_not_ours "$j" "$n"; return 0; fi
  for n in $(pr_issues "$j"); do
    why=$(pr_not_ours "$j" "$n" adoptable); [ -z "$why" ] && return 0
  done
  echo "${why:-PR #$1 closes no issue}"
}
# pr_for <n>: the newest open PR for issue n (pr_issues, or its branch <n>-…) that is not foreign
# (pr_foreign)
pr_for() {
  local p b; b=$(unit_branch "$1")
  if [ -n "$b" ]; then
    for p in $(jqr --arg b "$b-contract" '[.[] | select(.headRefName == $b) | .number] | sort | reverse | .[]' <<<"$PRS"); do
      [ -z "$(pr_foreign "$(pr_get "$p" .)" "$1")" ] && { echo "$p"; return; }
    done
  fi
  if is_pkg "$1"; then
    for p in $(jqr --arg b "$b" '[.[] | select(.headRefName == $b) | .number] | sort | reverse | .[]' <<<"$PRS"); do
      [ -z "$(pr_foreign "$(pr_get "$p" .)" "$1")" ] && { echo "$p"; return; }
    done
    return 0
  fi
  for p in $(jqr --argjson n "$1" "$PR_ISSUES_JQ"' [.[] | select((pr_issues | index($n)) or ((.headRefName // "") | test("^(issue-)?\($n)(-|$)")))
               | .number] | sort | reverse | .[]' <<<"$PRS"); do
    [ -z "$(pr_foreign "$(pr_get "$p" .)" "$1")" ] && { echo "$p"; return; }
  done
}
pr_get() { jqr --argjson p "$1" ".[] | select(.number == \$p) | $2" <<<"$PRS"; }
pr_is_open() { [ -n "$(pr_get "$1" .number)" ]; }
pr_has_label() { pr_get "$1" '.labels[].name' | grep -qx "$2"; }

# auto_merge_read: AUTO_MERGE_ALLOWED is the repo's allow_auto_merge: true, false, or unknown (a gh
# error, or a token that does not see the setting; merge_auto then tries --auto, and its "not
# allowed" error makes it false). Read once per pass; not run in $(…), so the value stays.
auto_merge_read() {
  [ -n "$AUTO_MERGE_ALLOWED" ] && return 0
  AUTO_MERGE_ALLOWED=$(ghj api "repos/$REPO" --jq .allow_auto_merge 2>/dev/null)
  case $AUTO_MERGE_ALLOWED in true|false) ;; *) AUTO_MERGE_ALLOWED=unknown ;; esac
}
# merge_method_read: MERGE_METHOD is the method flag a merge passes: queue (none: the merge queue
# sets it), else the first the repo allows of --squash, --merge, --rebase; unknown on a gh error
# (auto-merge then passes none, a direct merge --squash, as before). Read once per pass.
merge_method_read() {
  [ -n "$MERGE_METHOD" ] && return 0
  MERGE_METHOD=$(ghj api graphql -F o="${REPO%%/*}" -F r="${REPO#*/}" \
    -f query='query($o: String!, $r: String!) { repository(owner: $o, name: $r) { mergeQueue { id } squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed } }' \
    -q '.data.repository | if .mergeQueue != null then "queue" elif .squashMergeAllowed == true then "squash"
          elif .mergeCommitAllowed == true then "merge" elif .rebaseMergeAllowed == true then "rebase" else "unknown" end' 2>/dev/null)
  case $MERGE_METHOD in queue) ;; squash|merge|rebase) MERGE_METHOD=--$MERGE_METHOD ;; *) MERGE_METHOD=unknown ;; esac
}
# is_full_sha <sha>: a full 40-character commit sha, the only kind --match-head-commit is given
is_full_sha() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }

# ci_state <pr>: green, red, pending (a check is running or queued) or none (no check reported:
# no CI, or a path filter skipped it; never green). The newest run per check counts.
# The checks in REVIEW_CHECKS wait for the review verdict, so they are left out here.
ci_state() {
  jqr --argjson p "$1" --arg ign "${REVIEW_CHECKS:-}" '($ign | split(" ") | map(select(. != ""))) as $ig
    | .[] | select(.number == $p) |
    [ .statusCheckRollup[]? | { n: (.name // .context), c: ((.conclusion // .state // "") | ascii_upcase),
        s: ((.status // "COMPLETED") | ascii_upcase), t: (.completedAt // .startedAt // "") }
      | select(.n as $x | $ig | index($x) | not) ]
    | group_by(.n) | map(max_by(.t))
    | if length == 0 then "none"
      elif any(.[]; .s == "COMPLETED" and (.c | IN("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"))) then "red"
      elif all(.[]; .s == "COMPLETED" and (.c | IN("SUCCESS", "NEUTRAL", "SKIPPED"))) then "green"
      else "pending" end' <<<"$PRS"
}

# review_checks_running <pr>: the newest run of a REVIEW_CHECKS check on the PR is still running,
# queued or pending (a direct merge waits for it, as the merge queue would)
review_checks_running() {
  [ "$(jqr --argjson p "$1" --arg ign "${REVIEW_CHECKS:-}" '($ign | split(" ") | map(select(. != ""))) as $ig
    | .[] | select(.number == $p) |
    [ .statusCheckRollup[]? | { n: (.name // .context), c: ((.conclusion // .state // "") | ascii_upcase),
        s: ((.status // "COMPLETED") | ascii_upcase), t: (.completedAt // .startedAt // "") }
      | select(.n as $x | $ig | index($x)) ]
    | group_by(.n) | map(max_by(.t)) | any(.[]; .s != "COMPLETED" or (.c | IN("", "PENDING", "EXPECTED")))' <<<"$PRS")" = true ]
}

# pr_detail <pr>: JSON with head, comments, commits, state, files is fetched separately
pr_detail() { ghj pr view "$1" -R "$REPO" --json number,url,state,isDraft,headRefOid,headRefName,author,isCrossRepository,comments,commits,body,closingIssuesReferences,labels; }
# pr_files_raw <pr>: one "<path>\t<old path of a rename, or nothing>" line per changed file
pr_files_raw() { ghj api --paginate "repos/$REPO/pulls/$1/files" -q '.[] | [.filename, (.previous_filename // "")] | @tsv'; }
# pr_files <pr>: every path the PR touches, a rename's old path too (it moves a file out of there)
pr_files() { local r; r=$(pr_files_raw "$1") || return 1; tr '\t' '\n' <<<"$r" | grep .; }
PR_FILES_CAP=3000   # the files API lists no more than this

# verdict_of <pr_detail json>: the verdict of the newest comment by REVIEWER_LOGIN whose last
# non-empty line is "Review verdict: <pass | changes> <full head sha>" for the PR's current head
# (bold or backticks around it are fine). A verdict for another head, by anyone else, without
# the sha, or any other word does not count. Empty when there is none. A line
# "Maintainer accept: <reason>" before it in that comment marks the PR manual
# (maintainer_accept_of). verdict_body prints the comment.
VERDICT_RE='^[\s`*_>]*Review verdict:[*_`]*\s*(?<v>pass|changes)\W+(?<sha>[0-9a-fA-F]{40})\W*$'
MACCEPT_RE='^[\s`*_>-]*Maintainer accept:[*_`]*\s*(?<r>\S.*?)[\s`*_]*$'
# a package's risk class: "Risk: <low|normal|high> — <why>" in a review before its verdict, or in the PR body
RISK_RE='^[\s`*_>-]*Risk:[*_`]*\s*(?<r>low|normal|high)\b'
MACCEPT_GREP='^[[:space:]`*_>-]*Maintainer accept:'
_verdict_jq='.headRefOid as $h
  | [ .comments[]? | select(.author.login == $rl)
      | (.body | gsub("\r"; "") | split("\n") | map(select(test("\\S")))) as $ls
      | ($ls | last // "" | capture($vre; "i")) as $m
      | select(($m.sha | ascii_downcase) == $h)
      | { at: .createdAt, v: ($m.v | ascii_downcase), body,
          ma: ([$ls[:-1][] | capture($mre; "i") | .r] | first // ""),
          rk: ([$ls[:-1][] | capture($rre; "i") | .r | ascii_downcase] | last // "") } ]
  | sort_by(.at) | last'
_vq() { jqr --arg rl "$REVIEWER_LOGIN" --arg vre "$VERDICT_RE" --arg mre "$MACCEPT_RE" --arg rre "$RISK_RE" "$@"; }
# An optional second argument (ISO time) ignores verdicts posted at or before it: one already acted on.
verdict_of() { _vq --arg a "${2:-}" "$_verdict_jq | select(.at > \$a) | .v // empty" <<<"$1"; }
verdict_body() { _vq "$_verdict_jq | .body // empty" <<<"$1"; }
verdict_at() { _vq "$_verdict_jq | .at // empty" <<<"$1"; }
maintainer_accept_of() { _vq "$_verdict_jq | .ma // empty" <<<"$1"; }
review_risk_of() { _vq "$_verdict_jq | .rk // empty" <<<"$1"; }
# pr_risk_of <body>: the PR body's Risk: class (the last such line), or nothing
pr_risk_of() { jqr -R -s --arg rre "$RISK_RE" '[split("\n")[] | capture($rre; "i") | .r | ascii_downcase] | last // empty' <<<"$1"; }
# risk_max <class...>: the highest of the classes given (low < normal < high); empty ones are skipped
risk_max() {
  local r best=""; local -A rank=([low]=1 [normal]=2 [high]=3)
  for r; do [ -n "$r" ] && [ -n "${rank[$r]:-}" ] || continue; { [ -z "$best" ] || (( rank[$r] > rank[$best] )); } && best=$r; done
  echo "$best"
}
# risk_source <plan> <pr> <reviewer> <paths>: the first source that says high
risk_source() {
  local s; for s in plan:$1 PR:$2 reviewer:$3 paths:$4; do [ "${s#*:}" = high ] && { echo "${s%%:*}"; return; }; done
}
# effective_risk <unit> <pr body> <changed paths> [the PR comments' reviewer class]: a package's
# risk class, the highest of the plan, the PR's Risk: line and the reviewer (the full review's too,
# after its fix-check); the health pass is high when it touches HIGH_RISK_PATHS. A high class names
# its first source ("high (plan)"). Empty for a unit with no class (a single issue).
effective_risk() {
  local n=$1 rp rpr rr rpath="" risk
  [ -n "$(st_get "$n" pkg)" ] || return 0
  rp=$(st_get "$n" risk) rpr=$(pr_risk_of "$2")
  rr=$(risk_max "${4:-}" "$(st_get "$n" review_risk)")
  is_health "$n" && { rpath=normal; [ -n "$HIGH_RISK_PATHS" ] && grep -qiE "$HIGH_RISK_PATHS" <<<"$3" && rpath=high; }
  risk=$(risk_max "$rp" "$rpr" "$rr" "$rpath")
  [ "$risk" = high ] && risk="high ($(risk_source "$rp" "$rpr" "$rr" "$rpath"))"
  echo "$risk"
}

# ---------------------------------------------------------------- merge classifier

is_plan_body() { grep -qiE '^[[:space:]*_]*Tier:[[:space:]*_]*plan\b' <<<"$1"; }

# automerge_until_problem: why AUTO_MERGE_UNTIL (optional) cannot be compared as a date, or nothing
automerge_until_problem() {
  [ -z "$AUTO_MERGE_UNTIL" ] && return 0
  [[ $AUTO_MERGE_UNTIL =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] &&
    [ "$(date -u -d "$AUTO_MERGE_UNTIL" +%F 2>/dev/null)" = "$AUTO_MERGE_UNTIL" ] && return 0
  echo "AUTO_MERGE_UNTIL ($AUTO_MERGE_UNTIL) is not a YYYY-MM-DD date"
}

# Paths that configure the agents that work on the repo (.claude/, .mcp.json, CLAUDE.md,
# AGENTS.md): always the user's call, in every project. GATED_PATHS (the rules) adds the
# project's own (the gates, a privileged host).
AGENT_PATHS='(^|/)\.claude/|(^|/)\.mcp\.json$|(^|/)(CLAUDE(\.local)?|AGENTS)\.md$'
gated_re() { echo "${GATED_PATHS:+$GATED_PATHS|}$AGENT_PATHS"; }

# classify_pure <files> <pr body> <issue labels> <maintainer accept reason> <repo> <plan approved 0|1> [risk]
#   risk: a package's effective class with its source, e.g. "high (plan)"
#   → "auto" or "manual: <first reason>"
classify_pure() {
  local files=$1 body=$2 labels=$3 maccept=$4 repo=$5 plan_ok=${6:-0} risk=${7:-} p
  [ "$repo" = "$REPO" ] || { echo "manual: another repo ($repo)"; return; }
  if (( ! plan_ok )) && { grep -qE '^docs/plans/(issue-[0-9]+|pkg-[0-9]+-[a-z0-9-]+)\.md$' <<<"$files" || is_plan_body "$body"; }; then
    echo "manual: plan tier"; return
  fi
  p=$(grep -m1 -E "$(gated_re)" <<<"$files")
  if [ -n "$p" ]; then
    if [ -z "$GATED_PATHS" ] || ! grep -qE "$GATED_PATHS" <<<"$p"; then echo "manual: changes agent config ($p)"
    elif [[ $p == */* ]] && grep -qE "$GATED_PATHS" <<<"${p%%/*}/"; then echo "manual: changes ${p%%/*}/ ($p)"
    else echo "manual: changes a gated path ($p)"; fi
    return
  fi
  grep -qx manual-accept <<<"$labels" && { echo "manual: the issue has manual-accept"; return; }
  [[ $risk == high* ]] && { echo "manual: risk $risk"; return; }
  [ -n "$maccept" ] && { echo "manual: maintainer accept: $maccept"; return; }
  p=$(automerge_until_problem); [ -n "$p" ] && { echo "manual: $p"; return; }
  [ -z "$AUTO_MERGE_UNTIL" ] || [[ $(date -u -d "@$(now)" +%F) < "$AUTO_MERGE_UNTIL" ]] ||
    { echo "manual: on or after AUTO_MERGE_UNTIL ($AUTO_MERGE_UNTIL)"; return; }
  echo auto
}

# classify <pr> [issue] [repo]: the same from GitHub. A gh error reading the PR → "retry: …" (a
# third answer: the caller tries again next pass; a blip must not cost a person's accept); any
# other gh error → manual. A PR for no issue or several (pr_issues), another issue than the one
# given, or that is not ours → manual.
classify() {
  local pr=$1 want=${2:-} repo=${3:-$REPO} j n refs files labels why ma m l head contract=0
  [ "$repo" = "$REPO" ] || { echo "manual: another repo ($repo)"; return; }
  j=$(pr_detail "$pr") || { echo "retry: gh error reading PR #$pr"; return; }
  refs=$(jqr "$PR_ISSUES_JQ"' pr_issues | map(tostring) | join(" ")' <<<"$j")
  head=$(jqr '.headRefName // ""' <<<"$j")
  [ -n "$want" ] || want=$(unit_of_branch "$head")
  # a single issue's contract branch <n>-…-contract names its issue
  [ -n "$want" ] || { [[ $refs != *" "* ]] && is_contract_pr "$refs" "$head" && want=$refs; }
  if [ -n "$want" ] && is_contract_pr "$want" "$head"; then
    # its merge must leave the issues open for the unit's own PR
    l=$(jqr '[.closingIssuesReferences[]?.number] | unique | map(tostring) | join(" ")' <<<"$j")
    [ -z "$l" ] || { echo "manual: PR #$pr closes $l on the contract branch $head"; return; }
    n=$want contract=1
  elif is_pkg "$want"; then
    # a package's PR closes exactly its issues (the health pass: none)
    m=$(members_of "$want" | sort -n | tr '\n' ' '); m=${m% }
    [ "$refs" = "$m" ] || { echo "manual: PR #$pr closes ${refs:-no issue}, not the package's ${m:-none}"; return; }
    n=$want
  else
    # the branch fallback finds the PR, but never makes it auto: one that names no issue would
    # merge and leave its issue open
    [ -n "$(jqr "$PR_ISSUES_JQ"' pr_named[]' <<<"$j")" ] || { echo "manual: PR #$pr closes no issue"; return; }
    [[ $refs == *" "* ]] && { echo "manual: PR #$pr closes more than one issue (${refs// /, })"; return; }
    n=$refs
    [ -z "$want" ] || [ "$n" = "$want" ] || { echo "manual: PR #$pr closes #$n, not #$want"; return; }
  fi
  # after plan-ok the PR is the build: a `Plan for` line alone would merge it and leave the issue open
  if [ "$(st_get "$n" plan_ok)" = 1 ] && (( ! contract )); then
    m=$(members_of "$n" | sort -n | tr '\n' ' '); m=${m% }
    l=$(jqr '[.closingIssuesReferences[]?.number] | unique | map(tostring) | join(" ")' <<<"$j")
    [ "$l" = "$m" ] || { echo "manual: PR #$pr closes ${l:-no issue} after plan-ok (the build must close #${m// /, #})"; return; }
  fi
  why=$(pr_not_ours "$j" "$n"); [ -n "$why" ] && { echo "manual: not ours: $why"; return; }
  files=$(pr_files_raw "$pr") || { echo "manual: gh error reading the files of PR #$pr"; return; }
  (( $(grep -c . <<<"$files") >= PR_FILES_CAP )) && { echo "manual: PR #$pr lists $PR_FILES_CAP+ files (the API's cap)"; return; }
  files=$(tr '\t' '\n' <<<"$files" | grep .)
  labels=""
  for m in $(members_of "$n"); do
    l=$(ghj issue view "$m" -R "$REPO" --json labels | jqr '.labels[].name') || { echo "manual: gh error reading issue #$m"; return; }
    labels+="$l"$'\n'
  done
  # a Maintainer accept line of the full review still holds after its fix-check passes
  ma=$(maintainer_accept_of "$j"); [ -n "$ma" ] || ma=$(st_get "$n" review_maccept)
  local body risk rrisk=""; body=$(jqr '.body // ""' <<<"$j")
  [ -n "$(st_get "$n" pkg)" ] && rrisk=$(review_risk_of "$j")
  risk=$(effective_risk "$n" "$body" "$files" "$rrisk")
  classify_pure "$files" "$body" "$labels" "$ma" "$repo" \
    "$([ "$(st_get "$n" plan_ok)" = 1 ] && echo 1 || echo 0)" "$risk"
}
