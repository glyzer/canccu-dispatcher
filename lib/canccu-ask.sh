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
    accept) # canccu-ship arms auto-merge: not offered in a repo without it
      auto_merge_read
      if [ "$AUTO_MERGE_ALLOWED" = false ]; then echo "PR #$3 waits for your accept: label it \`accepted\`."
      else echo "PR #$3 waits for your accept: label it \`accepted\`, or \`canccu-ship $1\`."; fi ;;
    pr-needs-you) echo "PR #$3 needs you (\`needs-you\`): its latest comments say why." ;;
    *) echo "this issue needs you (\`needs-you\`): the latest comments say why." ;;
  esac
}

# ask_change <pr>: the three "  - " lines of the Change: section of the PR's newest review file,
# each stripped of links, @ mentions and markup and cut at 160 characters; the no-summary line
# three times when there is no such file, or its section is not exactly three "- " lines
ask_change() {
  local f='' x l in=0 out=()
  for x in "$CANCCU_HOME/reviews/$1"/*.md; do
    case $x in *.findings.md|*.open.md) continue ;; esac
    [ -f "$x" ] && { [ -z "$f" ] || [ "$x" -nt "$f" ]; } && f=$x
  done
  if [ -n "$f" ]; then
    while IFS= read -r l; do
      if (( ! in )); then [[ $l =~ ^[[:space:]]*Change:[[:space:]]*$ ]] && in=1; continue; fi
      [[ $l =~ ^[[:space:]]*-[[:space:]]+(.*)$ ]] || break
      l=$(sed -E 's#http[^[:space:]]*##g; s#@[[:alnum:]_-]+##g; s#[`*_#<>]##g; s#[[:space:]]+# #g; s#^ ##; s# $##' <<<"${BASH_REMATCH[1]}")
      out+=("  - ${l:0:160}")
    done < "$f"
  fi
  if (( ${#out[@]} == 3 )); then printf '%s\n' "${out[@]}"; else printf '%s\n' "$ASK_NOSUM" "$ASK_NOSUM" "$ASK_NOSUM"; fi
}

# ask_review <K> <pr>: "pass on <short sha>" (a pass in this cycle), "changes on <short sha>" (the
# review asked for changes: the fix or its check is under way) or "none", from the unit's state
ask_review() {
  local s
  [ "$(st_get "$1" pr 2>/dev/null)" = "$2" ] || { echo none; return 0; }
  s=$(st_get "$1" pass_sha 2>/dev/null)
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
    accept) [ -n "$r" ] && { echo "${r#manual: }"; return 0; } ;;
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
  local k=$1 kind=$2 pr=$3 step=${4:-} extra=${5:-} n what rv=none ci=none head=- link rec acc
  n=$(lead_of "$k"); n=${n:-$k}
  if [ "$pr" = - ]; then
    case $kind in needs-you|plan|question)
      pr=$(st_get "$k" pr 2>/dev/null); [ -n "$pr" ] && pr_is_open "$pr" || pr=- ;;
    esac
  fi
  what=$(ask_what "$n" "$kind" "$([ "$kind" = checkpoint ] && echo "${step:--}" || echo "$pr")")
  link="https://github.com/$REPO/issues/$n"
  if [ "$pr" != - ]; then
    rv=$(ask_review "$k" "$pr") link=$(pr_url "$pr")
    ci=$(ci_state "$pr" 2>/dev/null); case $ci in pending) ci=running ;; green|red|none) ;; *) ci=none ;; esac
    head=$(pr_get "$pr" '.headRefOid // ""' 2>/dev/null); head=${head:0:7}; head=${head:--}
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
  [ "$pr" = - ] || { echo "Change (reviewer's summary):"; ask_change "$pr"; }
  echo "Review: $rv · CI: $ci"
  echo "Recommended: $rec"
  echo "If you accept: $acc"
  [ -z "$extra" ] || printf '%s\n' "$extra"
  echo "No answer: this waits."
  echo "$link · head $head"
}

# ask_block <n> <pr> <lines after "If you accept:">: the accept's form at the top of the PR body,
# between the markers; what was between them before (an older head's form) goes, the rest of the
# body stays. Written, the head is kept as ask_sha; accept_step writes it again while ask_sha is not
# the accept's head (a gh error: logged, the accept goes on; a head kept by keep_accept).
ask_block() {
  local form rest f
  form=$(ask_form "$1" accept "$2" - "$3")
  rest=$(pr_get "$2" '.body // ""' | awk '/^<!-- canccu:ask -->$/ { s = 1; next }
    s && /^<!-- \/canccu:ask -->$/ { s = 0; next } !s' | sed '/./,$!d')
  if (( CANCCU_DRY )); then mut gh pr edit "$2" -R "$REPO" --body-file "<the PR body with the ask form>"; return 0; fi
  f=$(mktemp) || { log "#$1 PR #$2: gh error writing the ask block; tried again next pass"; return 0; }
  printf '%s\n%s\n%s\n' '<!-- canccu:ask -->' "$form" '<!-- /canccu:ask -->' > "$f"
  [ -z "$rest" ] || printf '\n%s\n' "$rest" >> "$f"
  if mut gh pr edit "$2" -R "$REPO" --body-file "$f"; then st_set "$1" ask_sha="$(st_get "$1" accept_sha)"
  else log "#$1 PR #$2: gh error writing the ask block; tried again next pass"; fi
  rm -f "$f"
}
