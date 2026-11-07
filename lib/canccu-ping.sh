# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): pings. When something needs the user,
# the dispatcher posts one comment as REVIEWER_LOGIN that @mentions USER_LOGIN, so GitHub's
# mobile app pushes it (docs/canccu-dispatch.md, "Pings"). One ping per state: pings/<issue>
# holds the state last pinged; it goes once the state clears, so the state coming back pings again.

# ping_states: "<issue> <kind> <pr>" for every issue that needs the user now (pr: the PR the
# line names, a checkpoint's step, or -), read from the pass's fetch and the state files as the last pass left them
# (both from the same moment), then "END": a list without it stopped half-way. Kinds: needs-you,
# plan or question (an open issue labelled needs-you, or a managed unit in phase needs-you whose
# label did not land; its ny_kind tells a plan to approve and an escalated question apart),
# pr-needs-you (our open PR labelled needs-you), accept (a managed unit waits for the user's
# accept of its open PR) and checkpoint (a step waits for checkpoint-ok on this open checkpoint,
# labelled needs-you or not; listed first, as the most specific state of its issue). A state the
# user already answered by label (a plan labelled plan-ok, a checkpoint labelled checkpoint-ok by
# USER_LOGIN after the summary, a PR labelled accepted: this pass acts on it) is left out; a
# checkpoint-ok checkpoint_tick ignores is no answer, so the checkpoint still pings. A ping always goes on the issue (the unit's lead), never on a PR: the review-gate
# check reads the bot's comments there. An issue listed twice keeps its first line that
# PING_KINDS lets through (ping_tick).
ping_states() {
  local n k m kind pr ns rc
  local -A cpw=()
  while read -r n m; do
    cpw[$n]=$m; rc=0
    ping_cp_waits "$n" "$m" || rc=$?
    case $rc in 0) echo "$n checkpoint $m" ;; 2) return 1 ;; esac
  done < <(waiting_checkpoints)
  ns=$(jqr '.[] | select(any(.labels[]?; .name == "needs-you")) | .number' <<<"$ISSUES") || return 1
  for n in $ns; do
    [ -z "${cpw[$n]+x}" ] || continue   # a waiting checkpoint: above
    k=$(unit_of_issue "$n"); kind=needs-you
    is_managed "$k" && [ "$(st_get "$k" phase)" = needs-you ] && kind=$(ping_ny_kind "$k")
    [ "$kind" = plan ] && has_label "$n" plan-ok && continue
    echo "$n $kind -"
  done
  ns=$(jqr '.[] | select(any(.labels[]?; .name == "needs-you")) | .number' <<<"$PRS") || return 1
  for pr in $ns; do
    n=$(ping_pr_issue "$pr"); [ -n "$n" ] && echo "$n pr-needs-you $pr"
  done
  for k in $(managed); do
    case $(st_get "$k" phase) in
      needs-you)
        is_open "$k" || continue
        n=$(lead_of "$k"); kind=$(ping_ny_kind "$k")
        [ -n "$n" ] || continue
        [ "$kind" = plan ] && has_label "$n" plan-ok && continue
        echo "$n $kind -" ;;
      accept)
        pr=$(st_get "$k" pr); [ -n "$pr" ] && pr_is_open "$pr" || continue
        pr_has_label "$pr" accepted && continue
        n=$(lead_of "$k"); [ -n "$n" ] && echo "$n accept $pr" ;;
    esac
  done
  echo END
}

# ping_cp_waits <issue> <m>: 0 when step m's checkpoint is open and not answered: no checkpoint-ok,
# or one checkpoint_tick ignores (not USER_LOGIN's, or before the summary: label_by_user, its own
# rule); 1 when it is closed, gone or answered; 2 on a read error. Open and labels come from the
# checkpoint list checkpoint_tick reads (every checkpoint, not only the newest open issues), else
# (the steps' read failed) from the open issues.
ping_cp_waits() {
  local src=$ISSUES st
  (( ${STEPS_OK:-0} )) && src=$CHECKPOINTS
  st=$(jqr --argjson n "$1" '[.[] | select(.number == $n)] | first // empty
    | "\(.state // "OPEN") \([.labels[]?.name] | index("checkpoint-ok") != null)"' <<<"$src") || return 2
  case $st in
    "OPEN false") return 0 ;;
    "OPEN true") label_by_user "$1" checkpoint-ok "$(step_get "$2" checkpoint_at)" && return 1; return 0 ;;
    *) return 1 ;;
  esac
}

# the ping kinds PING_KINDS may list (besides all)
PING_KIND_NAMES='accept checkpoint plan question needs-you pr-needs-you'
# ping_kind_on <kind>: PING_KINDS lets this kind ping (unset: all; empty: none)
ping_kind_on() {
  [[ " ${PING_KINDS-all} " == *" all "* || " ${PING_KINDS-all} " == *" $1 "* ]]
}
# ping_kinds_check: a word in PING_KINDS that is no kind is logged (once): it pings nothing
ping_kinds_check() {
  local w bad=() s='' words=()
  read -ra words <<<"${PING_KINDS-all}"   # split, never glob-expanded
  for w in "${words[@]}"; do
    [[ " all $PING_KIND_NAMES " == *" $w "* ]] || bad+=("'$w'")
  done
  if (( ${#bad[@]} )); then
    (( ${#bad[@]} > 1 )) && s=s
    warn_once ping-kinds "PING_KINDS: unknown kind$s ${bad[*]} (known: all $PING_KIND_NAMES); it pings nothing"
  elif (( ! CANCCU_DRY )); then rm -f "$CANCCU_HOME/.warned-ping-kinds"; fi
}

# ping_ny_kind <K>: the ping kind of a managed unit in phase needs-you: plan, question or needs-you
ping_ny_kind() {
  case $(st_get "$1" ny_kind) in plan) echo plan ;; question) echo question ;; *) echo needs-you ;; esac
}

# ping_pr_issue <pr>: the issue a needs-you on the PR is pinged on: the lead issue of the unit it
# is ours for (see "Whose PRs"); nothing for a PR that is not ours
ping_pr_issue() {
  local j n k
  j=$(pr_get "$1" .)
  k=$(unit_of_branch "$(jqr '.headRefName // ""' <<<"$j")")
  if [ -n "$k" ]; then [ -z "$(pr_not_ours "$j" "$k")" ] && lead_of "$k"; return 0; fi
  for n in $(jqr '.closingIssuesReferences[]?.number' <<<"$j"); do
    [ -z "$(pr_not_ours "$j" "$n" adoptable)" ] && { echo "$n"; return 0; }
  done
  return 0
}

# ping_line <issue> <kind> <pr|step>: the comment's one line. Fixed words, the numbers, the user's
# login and the checkpoint summary's link only: never a reason, a title, a question or a run's output.
ping_line() {
  local u="@$USER_LOGIN" url=''
  case $2 in
    checkpoint)
      [ "$3" = - ] || url=$(step_get "$3" checkpoint_url)
      if [ -n "$url" ]; then url="($url)"; else url=above; fi
      echo "$u this checkpoint waits for your \`checkpoint-ok\`: read the summary $url, then label this issue \`checkpoint-ok\`, or close it." ;;
    plan) echo "$u the plan here waits for your OK: label this issue \`plan-ok\`, or comment." ;;
    question) echo "$u the worker's question here needs the product owner: answer it in a comment." ;;
    accept) echo "$u PR #$3 waits for your accept: label it \`accepted\`, or \`canccu-ship $1\`." ;;
    pr-needs-you) echo "$u PR #$3 needs you (\`needs-you\`): its latest comments say why." ;;
    *) echo "$u this issue needs you (\`needs-you\`): the latest comments say why." ;;
  esac
}

# ping_tick: ping every new state, forget every cleared one. PING=off: nothing, and the records
# go (a state pinged before must ping again once pings are back on). A state of a kind PING_KINDS
# leaves out is skipped as if not listed: no ping, and its record goes too (it is the lead's; it
# stays in needs-you, the status and the monitor). A missing bot token or a
# failed post is logged (once, until it changes: no issue number in it) and nothing is recorded,
# so the ping goes out on a later pass once the token works; after one failed post the pass
# tries no other (the same token fails for them too). A post that timed out may have landed: it
# is recorded, so it is never posted twice (the next state change pings again). Records are
# dropped only when ping_states listed everything (its END line). The pass goes on either way.
ping_tick() {
  local d="$CANCCU_HOME/pings" n kind pr line out rc f prob='' checked='' stop='' complete=''
  local -A cur=()
  case ${PING:-on} in
    on) ;;
    off) (( CANCCU_DRY )) || rm -rf "$d"; return 0 ;;
    *) warn_once ping-config "PING=$PING is neither on nor off: pings stay on" ;;
  esac
  ping_kinds_check
  while read -r n kind pr; do
    [ "$n" = END ] && { complete=1; continue; }
    ping_kind_on "$kind" || continue
    [ -n "$n" ] && [ -z "${cur[$n]+x}" ] || continue
    cur[$n]=$kind
    [ "$(cat "$d/$n" 2>/dev/null)" = "$kind" ] && continue
    line=$(ping_line "$n" "$kind" "$pr")
    if (( CANCCU_DRY )); then echo "  would: ping #$n as $REVIEWER_LOGIN: $line"; continue; fi
    [ -z "$stop" ] || continue
    [ -n "$checked" ] || { prob=$(reviewer_token_problem); checked=1; }
    if [ -n "$prob" ]; then warn_once ping "ping: $prob; @$USER_LOGIN is pinged once the token works"; continue; fi
    out=$(as_reviewer gh issue comment "$n" -R "$REPO" --body "$(home_tilde "$line")"$'\n\n'"$CANCCU_MARK" 2>&1); rc=$?
    case $rc in
      0) rm -f "$CANCCU_HOME/.warned-ping"; log "#$n pinged @$USER_LOGIN as $REVIEWER_LOGIN: $kind" ;;
      124|137) stop=1; log "#$n ping as $REVIEWER_LOGIN timed out; it may have landed, so it is not posted again for this state" ;;
      *) stop=1; warn_once ping "ping as $REVIEWER_LOGIN failed (gh: $(oneline 200 "${out:-no output}")); tried again next pass"; continue ;;
    esac
    mkdir -p "$d" && printf '%s\n' "$kind" > "$d/$n"
  done < <(ping_states)
  (( CANCCU_DRY )) && return 0
  if [ -z "$complete" ]; then
    warn_once ping-states "ping: the list of what needs you stopped half-way; no ping record is dropped this pass"
    return 0
  fi
  rm -f "$CANCCU_HOME/.warned-ping-states"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ -n "${cur[${f##*/}]+x}" ] || rm -f "$f"
  done
  return 0
}
