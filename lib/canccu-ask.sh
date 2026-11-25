# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the ask form (docs/plan/contracts.md §4,
# docs/reference/pings.md). One renderer for every ask to the product owner: the ping's comment
# and the block at the top of the PR body. What goes in: the dispatcher's own shell values and
# the independent reviewer's three Change: lines, cut and stripped. Never the worker's text or
# the PR body: the worker's work is what is being judged.

ASK_NOSUM='  - (the reviewer gave no summary)'

# ask_what <issue> <kind> <pr|step>: the kind's one plain line. Fixed words, the numbers and the
# checkpoint summary's link only: never a reason, a title, a question or a run's output.
ask_what() {
  local url=''
  case $2 in
    checkpoint)
      [ "$3" = - ] || [ -z "$3" ] || url=$(step_get "$3" checkpoint_url)
      if [ -n "$url" ]; then url="($url)"; else url=above; fi
      echo "this checkpoint waits for your \`checkpoint-ok\`: read the summary $url, then label this issue \`checkpoint-ok\`, or close it." ;;
    plan) echo "the plan here waits for your OK: label this issue \`plan-ok\`, or comment." ;;
    question) echo "the worker's question here needs the product owner: answer it in a comment." ;;
    accept) echo "PR #$3 waits for your accept: $(accept_ways "$1")." ;;
    pr-needs-you) echo "PR #$3 needs you (\`needs-you\`): its latest comments say why." ;;
    *) echo "this issue needs you (\`needs-you\`): the latest comments say why." ;;
  esac
}

# ask_strip: stdin to stdout, one line stripped of what must not render or notify: markup first
# (so it cannot hide the rest), then every link form GitHub renders (`http…`, protocol-relative
# `//host`, `www.` autolinks; the `!` of an image goes with its link), then @ mentions
ask_strip() {
  sed -E 's#[`*_#<>]##g; s#[Hh][Tt][Tt][Pp][^[:space:]]*##g; s#//[^[:space:])]*##g; s#(^|[^[:alnum:]])[Ww][Ww][Ww]\.[^[:space:]]*#\1#g; s#!+\[#[#g; s#@[[:alnum:]_-]+##g; s#[[:space:]]+# #g; s#^ ##; s# $##'
}

# ask_change <pr> [head sha]: the three "  - " lines of the Change: section of the review file of the
# head the form shows (reviews/<pr>/<head>.md; without a head, the newest by mtime), each through
# ask_strip and cut at 160 characters; the no-summary line three times when there is no such
# file, or its section is not exactly three "- " lines
ask_change() {
  local f='' x l in=0 out=()
  if [ -n "${2:-}" ]; then
    [ -f "$CANCCU_HOME/reviews/$1/$2.md" ] && f="$CANCCU_HOME/reviews/$1/$2.md"
  else
    for x in "$CANCCU_HOME/reviews/$1"/*.md; do
      case $x in *.findings.md|*.open.md) continue ;; esac
      [ -f "$x" ] && { [ -z "$f" ] || [ "$x" -nt "$f" ]; } && f=$x
    done
  fi
  if [ -n "$f" ]; then
    while IFS= read -r l; do
      if (( ! in )); then [[ $l =~ ^[[:space:]]*Change:[[:space:]]*$ ]] && in=1; continue; fi
      [[ $l =~ ^[[:space:]]*-[[:space:]]+(.*)$ ]] || break
      l=$(ask_strip <<<"${BASH_REMATCH[1]}")
      out+=("  - ${l:0:160}")
    done < "$f"
  fi
  if (( ${#out[@]} == 3 )); then printf '%s\n' "${out[@]}"; else printf '%s\n' "$ASK_NOSUM" "$ASK_NOSUM" "$ASK_NOSUM"; fi
}

# ask_review <K> <pr> [head]: "pass on <short sha>" (a pass in this cycle, for the head the form
# shows: a push that landed since is not that pass), "changes on <short sha>" (the review asked
# for changes: the fix or its check is under way) or "none", from the unit's state
ask_review() {
  local s
  [ "$(st_get "$1" pr 2>/dev/null)" = "$2" ] || { echo none; return 0; }
  s=$(st_get "$1" pass_sha 2>/dev/null)
  [ -n "$s" ] && [ -n "${3:-}" ] && [[ $3 != "$s"* ]] && s=''
  [ -n "$s" ] && { echo "pass on ${s:0:7}"; return 0; }
  s=$(st_get "$1" reviewed_sha 2>/dev/null)
  case $(st_get "$1" stage 2>/dev/null) in
    fixing|fixcheck) [ -n "$s" ] && { echo "changes on ${s:0:7}"; return 0; } ;;
  esac
  echo none
}

# ask_why <K> <kind>: the owner reason: an accept's own reason, else the rule of contracts §1
# that made the item the product owner's
ask_why() {
  local r; r=$(st_get "$1" reason 2>/dev/null)
  case $2 in
    accept) [ -n "$r" ] && { ask_strip <<<"${r#manual: }"; return 0; } ;;
    checkpoint) echo "a checkpoint is always the product owner's"; return 0 ;;
  esac
  [ "${LEADER:-off}" = on ] || { echo "no leader runs for this project (LEADER=off)"; return 0; }
  [ "$2" = question ] && [[ $r == *"needs the product owner"* || $r == *"always for the product owner"* ]] &&
    { echo "the answerer escalated this question to the product owner"; return 0; }
  [ "$2" = plan ] && unit_manual_accept "$1" && { echo "an issue of the unit is labelled manual-accept"; return 0; }
  echo "it waits for the product owner"
}

# ask_form <K> <kind> <pr|-> [step] [lines after "If you accept:"]: the form of contracts §4, line
# for line. A needs-you, plan or question without a PR takes the unit's PR when it is open. With
# NOTIFY_CONTENT=link only the first and the last line (the link) are printed.
ask_form() {
  auto_merge_read   # here, not in the $(…) of ask_what: the once-per-pass value stays
  local k=$1 kind=$2 pr=$3 step=${4:-} extra=${5:-} n what rv=none ci=none head=- link rec acc full='' chg fs
  n=$(lead_of "$k"); n=${n:-$k}
  if [ "$pr" = - ]; then
    case $kind in needs-you|plan|question)
      pr=$(st_get "$k" pr 2>/dev/null); [ -n "$pr" ] && pr_is_open "$pr" || pr=- ;;
    esac
  fi
  what=$(ask_what "$n" "$kind" "$([ "$kind" = checkpoint ] && echo "${step:--}" || echo "$pr")")
  link="https://github.com/$REPO/issues/$n"
  if [ "$pr" != - ]; then
    full=$(pr_get "$pr" '.headRefOid // ""' 2>/dev/null)
    rv=$(ask_review "$k" "$pr" "$full") link=$(pr_url "$pr")
    ci=$(ci_state "$pr" 2>/dev/null); case $ci in pending) ci=running ;; green|red|none) ;; *) ci=none ;; esac
    head=${full:0:7}; head=${head:--}
  fi
  if [ "$kind" = accept ]; then
    if [[ $rv == pass* ]] && [ "$ci" = green ]; then rec="accept, review passed and CI is green"
    elif [[ $rv == changes* ]]; then rec="do not accept, the review asked for changes"
    elif [[ $rv != pass* ]]; then rec="do not accept, no review passed"
    else case $ci in
      red) rec="do not accept, CI is red" ;; running) rec="do not accept, CI is running" ;; *) rec="do not accept, CI reports no check" ;;
    esac; fi
    acc="it merges at $head once CI is green"
  else
    rec="answer needed, $what"
    case $kind in plan) acc="the build starts" ;; checkpoint) acc="the next step starts" ;; *) acc="the worker resumes with your answer" ;; esac
  fi
  if [ "${NOTIFY_CONTENT:-full}" != full ]; then
    printf '%s\n' "For the product owner: $what" "$link · head $head"; return 0
  fi
  echo "For the product owner: $what"
  echo "Why you: $(ask_why "$k" "$kind")"
  if [ "$pr" != - ]; then
    # a head that is a merge of main only has no review file: the last verdict that passed has (passed_rev)
    chg=$full
    if [ -n "$full" ] && [[ $rv == pass* ]] && [ ! -f "$CANCCU_HOME/reviews/$pr/$full.md" ]; then
      fs=$(st_get "$k" passed_rev 2>/dev/null); [ -f "$CANCCU_HOME/reviews/$pr/$fs.md" ] && chg=$fs
    fi
    echo "Change (reviewer's summary):"; ask_change "$pr" "$chg"
  fi
  echo "Review: $rv · CI: $ci"
  echo "Recommended: $rec"
  echo "If you accept: $acc"
  [ -z "$extra" ] || printf '%s\n' "$extra"
  echo "No answer: this waits."
  echo "$link · head $head"
}

# ask_block <n> <pr> <lines after "If you accept:">: the accept's form at the top of the PR body,
# between the markers; what was between them before (an older head's form) goes, the rest of the
# body stays. The body is read fresh (the pass-start snapshot may be older than an edit made in
# this pass); when that read fails the body is not written at all, or it would be replaced by the
# form alone. Carriage returns go first (a body edited on the web ends lines in CRLF); an opening
# marker with no closing one strips nothing, so the body is kept as it is. Written, the head is
# kept as ask_sha; accept_step writes it again while ask_sha is not the accept's head (a gh error:
# logged, the accept goes on; a head kept by keep_accept).
ask_block() {
  local form rest f body
  form=$(home_tilde "$(ask_form "$1" accept "$2" - "$3")")
  if (( CANCCU_DRY )); then mut gh pr edit "$2" -R "$REPO" --body-file "<the PR body with the ask form>"; return 0; fi
  body=$(ghj pr view "$2" -R "$REPO" --json body -q .body) ||
    { log "#$1 PR #$2: gh error reading the PR body; the ask block is tried again next pass"; return 0; }
  rest=$(tr -d '\r' <<<"$body" | awk '{ l[NR] = $0 }
    !o && /^<!-- canccu:ask -->$/ { o = NR } o && !c && NR > o && /^<!-- \/canccu:ask -->$/ { c = NR }
    END { for (i = 1; i <= NR; i++) if (!c || i < o || i > c) print l[i] }' | sed '/./,$!d')
  f=$(mktemp) || { log "#$1 PR #$2: gh error writing the ask block; tried again next pass"; return 0; }
  printf '%s\n%s\n%s\n' '<!-- canccu:ask -->' "$form" '<!-- /canccu:ask -->' > "$f"
  [ -z "$rest" ] || printf '\n%s\n' "$rest" >> "$f"
  if mut gh pr edit "$2" -R "$REPO" --body-file "$f"; then st_set "$1" ask_sha="$(st_get "$1" accept_sha)"
  else log "#$1 PR #$2: gh error writing the ask block; tried again next pass"; fi
  rm -f "$f"
}
