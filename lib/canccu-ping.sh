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
# PING_KINDS lets through (ping_tick). An item of owner leader is left out: the leader reads it from
# the feed, and the mention goes to the product owner only (need_owner).
# ping_step_kind <n> <kind>: the kind snap_steps gives issue n when it is the issue of a step that
# reached STEP_BUDGET (budget) or holds an invalid plan (plan-invalid), else <kind>
ping_step_kind() {
  local f m
  for f in "$CANCCU_HOME"/steps/*; do
    m=${f##*/}; [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] && [ "$(step_issue "$m")" = "$1" ] || continue
    [ -n "$(step_get "$m" budget_ny)" ] && { echo budget; return 0; }
    [ "$(step_get "$m" phase)" = needs-you ] && [ "$(step_get "$m" ny_kind)" != stop ] && { echo plan-invalid; return 0; }
  done
  echo "$2"
}
ping_states() {
  local n k m kind pr ns rc o
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
    is_managed "$k" && [ "$(st_get "$k" phase)" = needs-you ] && kind=$(ny_item_kind "$k")
    [ "$kind" = plan ] && has_label "$n" plan-ok && continue
    # a step's issue: its owner by the snapshot's kind (budget, plan-invalid: po)
    o=$kind; is_managed "$k" || o=$(ping_step_kind "$n" "$kind")
    [ "$(need_owner "$k" "$o")" = po ] || continue
    echo "$n $kind -"
  done
  ns=$(jqr '.[] | select(any(.labels[]?; .name == "needs-you")) | .number' <<<"$PRS") || return 1
  for pr in $ns; do
    n=$(ping_pr_issue "$pr"); [ -n "$n" ] && [ "$(need_owner "$(unit_of_issue "$n")" pr-needs-you)" = po ] &&
      echo "$n pr-needs-you $pr"
  done
  for k in $(managed); do
    case $(st_get "$k" phase) in
      needs-you)
        is_open "$k" || continue
        n=$(lead_of "$k"); kind=$(ny_item_kind "$k")
        [ -n "$n" ] || continue
        [ "$kind" = plan ] && has_label "$n" plan-ok && continue
        [ "$(need_owner "$k" "$kind")" = po ] || continue
        echo "$n $kind -" ;;
      accept)
        pr=$(st_get "$k" pr); [ -n "$pr" ] && pr_is_open "$pr" || continue
        # a counting label on the PR or an issue: this pass acts on it
        accept_channel label && accept_label_held "$k" "$pr" && continue
        [ "$(need_owner "$k" accept)" = po ] || continue
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
# ping_kind_on <kind>: PING_KINDS lets this kind ping (unset: all; empty: none). Commas separate
# too, as in the other word lists and as `config set` accepts them
ping_kind_on() {
  local p=" ${PING_KINDS-all} "; p=${p//,/ }
  [[ $p == *" all "* || $p == *" $1 "* ]]
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

# ping_tick: ping every new state, forget every cleared one. The comment is @USER_LOGIN and the ask
# form (ask_form); pings/<issue> holds "<kind> <comment id>". A changed kind edits that comment
# (PATCH) instead of posting a new one; a settled item marks it closed (ping_close). A record
# without an id (an old one-word record, or gh printed no link) posts a new comment; so does an
# edit that failed for another reason than a time-out (the comment is gone). PING=off: nothing,
# and the records go (a state pinged before must ping again once pings are back on). A state of a
# kind PING_KINDS leaves out is skipped as if not listed: no ping, and its record goes too (it is
# the lead's; it stays in needs-you, the status and the monitor), its comment left as it is. A
# missing bot token or a failed post is logged (once, until it changes: no issue number in it) and
# nothing is recorded, so the ping goes out on a later pass once the token works; after one failed
# post the pass tries no other (the same token fails for them too). A post that timed out may have
# landed: it is recorded, so it is never posted twice (the next state change pings again). Records
# are dropped only when ping_states listed everything (its END line). The pass goes on either way.
ping_tick() {
  local d="$CANCCU_HOME/pings" posted_at n kind pr form text out rc f rk rid id prob='' checked='' stop='' complete=''
  local -A cur=() seen=()
  # NOTIFY sends no GitHub ping (telegram, off): as PING=off
  local ping=${PING:-on}; notify_on github || ping=off
  case $ping in
    on) ;;
    off) (( CANCCU_DRY )) || rm -rf "$d"; return 0 ;;
    *) warn_once ping-config "PING=$PING is neither on nor off: pings stay on" ;;
  esac
  ping_kinds_check
  while read -r n kind pr; do
    [ "$n" = END ] && { complete=1; continue; }
    [ -n "$n" ] && seen[$n]=1
    ping_kind_on "$kind" || continue
    [ -n "$n" ] && [ -z "${cur[$n]+x}" ] || continue
    cur[$n]=$kind
    rk='' rid=''; [ -f "$d/$n" ] && read -r rk rid < "$d/$n"
    [ "$rk" = "$kind" ] && continue
    if (( CANCCU_DRY )); then
      if [ "$kind" = checkpoint ]; then form=$(ask_form "$(unit_of_issue "$n")" checkpoint - "$pr")
      else form=$(ask_form "$(unit_of_issue "$n")" "$kind" "$pr"); fi
      echo "  would: ping #$n as $REVIEWER_LOGIN: @$USER_LOGIN ${form%%$'\n'*}"; continue
    fi
    # before the form: it costs gh calls (CI, auto-merge), pointless when nothing can be posted
    [ -z "$stop" ] || continue
    [ -n "$checked" ] || { prob=$(reviewer_token_problem); checked=1; }
    if [ -n "$prob" ]; then warn_once ping "ping: $prob; @$USER_LOGIN is pinged once the token works"; continue; fi
    auto_merge_read
    if [ "$kind" = checkpoint ]; then form=$(ask_form "$(unit_of_issue "$n")" checkpoint - "$pr")
    else form=$(ask_form "$(unit_of_issue "$n")" "$kind" "$pr"); fi
    text="@$USER_LOGIN"$'\n'"$(home_tilde "$form")"$'\n\n'"$CANCCU_MARK"
    rc=1 id=$rid
    if [ -n "$rid" ]; then
      out=$(as_reviewer gh api "repos/$REPO/issues/comments/$rid" -X PATCH -f "body=$text" 2>&1); rc=$?
      # timed out: the edit may not have landed, so the old kind stays recorded and it is tried again
      if (( rc == 124 || rc == 137 )); then
        stop=1; log "#$n ping edit as $REVIEWER_LOGIN timed out; tried again next pass"; continue
      fi
    fi
    if [ -z "$rid" ] || (( rc != 0 )); then
      posted_at=$(now)
      out=$(as_reviewer gh issue comment "$n" -R "$REPO" --body "$text" 2>&1); rc=$? id=''
      [[ $out =~ issuecomment-([0-9]+) ]] && id=${BASH_REMATCH[1]}
      # a post that timed out may have landed with no link printed: find it, or it is never closed
      (( rc == 124 || rc == 137 )) && id=$(ping_find "$n" "$posted_at")
    fi
    case $rc in
      0) rm -f "$CANCCU_HOME/.warned-ping"; log "#$n pinged @$USER_LOGIN as $REVIEWER_LOGIN: $kind${rk:+ (was $rk)}" ;;
      124|137) stop=1; log "#$n ping as $REVIEWER_LOGIN timed out; it may have landed, so it is not posted again for this state${id:+ (found as comment $id)}" ;;
      *) stop=1; warn_once ping "ping as $REVIEWER_LOGIN failed (gh: $(oneline 200 "${out:-no output}")); tried again next pass"; continue ;;
    esac
    mkdir -p "$d" && printf '%s\n' "$kind${id:+ $id}" > "$d/$n"
  done < <(ping_states)
  (( CANCCU_DRY )) && return 0
  if [ -z "$complete" ]; then
    warn_once ping-states "ping: the list of what needs you stopped half-way; no ping record is dropped this pass"
    return 0
  fi
  rm -f "$CANCCU_HOME/.warned-ping-states"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    n=${f##*/}
    [ -n "${cur[$n]+x}" ] && continue
    rk='' rid=''; read -r rk rid < "$f"
    if [ -n "$rid" ] && [ -z "${seen[$n]+x}" ]; then
      # the close is skipped when nothing can be posted this pass: the record stays, so a later pass closes it
      [ -z "$stop" ] && [ -z "$prob" ] || continue
      ping_close "$n" "$rid"
    fi
    rm -f "$f"
  done
  return 0
}

# ping_find <issue> <epoch>: the id of the newest comment of the reviewer's mark on the issue
# created since the post started (a post that timed out before gh printed its link); an older
# ping, settled or not, is not that post. Empty when there is none or gh fails. The slack covers
# the clocks of this host and GitHub.
ping_find() {
  local since; since=$(iso $(( $2 - 30 )))
  as_reviewer gh api "repos/$REPO/issues/$1/comments" --paginate -q \
    "[.[] | select(.user.login == \"$REVIEWER_LOGIN\" and (.body | contains(\"$CANCCU_MARK\")) and .created_at >= \"$since\")] | last | .id // empty" 2>/dev/null | tail -n1
}

# ping_close <issue> <comment id>: the item settled: its comment's first line of the form becomes
# "Closed: <that line>" (an edit, so nobody is notified). A failure is logged; the record goes anyway.
ping_close() {
  local b
  b=$(as_reviewer gh api "repos/$REPO/issues/comments/$2" -q .body 2>/dev/null) &&
    b=$(awk '!d && /^For the product owner: / { $0 = "Closed: " $0; d = 1 } 1' <<<"$b") &&
    as_reviewer gh api "repos/$REPO/issues/comments/$2" -X PATCH -f "body=$b" >/dev/null 2>&1 &&
    { log "#$1 ping closed"; return 0; }
  log "#$1 ping: could not mark comment $2 closed"
}
