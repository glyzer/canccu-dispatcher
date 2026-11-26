# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by lib/canccu-pipeline.sh; never run: the dispatcher pass, step 4 (resume).

# ---------------------------------------------------------------- 4. resume

# user_comments: lib/canccu-accepts.sh

# full_review_asked <comments>: the lead asks for a new full review with a line that is just
# `full review` (any case; spaces, `*`, `_`, backticks and a final . or ! allowed): the words
# inside a sentence ("no need for a full review") are no marker
full_review_asked() { grep -qiE '^[[:space:]*_`]*full review[[:space:]*_`.!]*$' <<<"$1"; }

# extra_round <n> <pr> <comments>: needs-work on a needs-you left in the fix round by a fix-check's
# open items (open_sha; not a refused accept, not a stopped merge, which park at merge) and no
# `full review` line: one more fix round, then a fix-check of open_sha..head against those items
# and the lead's comments. 1 when this needs-work is not one; 0 once handled or deferred.
extra_round() {
  local n=$1 pr=$2 c=$3 osha items cm=""
  osha=$(st_get "$n" open_sha)
  [ "$(st_get "$n" phase)" = needs-you ] && [ -n "$osha" ] && [ "$(st_get "$n" ny_stage)" != merge ] || return 1
  case $(st_get "$n" stage) in fixing|fixcheck) ;; *) return 1 ;; esac
  full_review_asked "$c" && return 1
  items=$(cat "$(open_file "$pr" "$osha")" 2>/dev/null)
  [ -n "$items" ] || items="The open items of the fix-check were not saved: read the newest PR comment ending in 'Review verdict: changes $osha' (gh pr view $pr -R $REPO --comments)."
  resume "$n" "The user asked for one more fix round on PR #$pr (needs-work) for the open items of its fix-check. Fix them and address their comments, rerun the checks, push once and stop: the dispatcher watches CI. A narrow fix-check of this fix diff against those items follows, then the merge or the product owner. The open items: $items Their comments: ${c:-none found; read the latest comments on the PR and the issue}" needs-work || return 0
  [ -n "$c" ] && cm=$'\n\n'"The user's needs-work comments (also to be fixed): $c"
  # rebuilt from the saved items each time, so a second needs-work in the round never appends
  save_findings "$n" "$pr" "$(findings_file "$pr" "$osha")" "$items$cm"
  edit_issue "$n" --remove-label needs-work
  rfix_count "$n" "$pr"
  st_set "$n" stage=fixing reviewed_sha="$osha"
  log "#$n PR #$pr: needs-work on the fix-check's open items; one more fix round, then a fix-check of ${osha:0:7}..head"
}

# owed_round <n> <pr> <comments> <comment|needs-work>: the lead's comment (or needs-work) on the
# needs-you of a full review's `changes` that had no review fix run left (fix_owed): that round
# goes on as a fix run (FIX_MODEL) on the saved findings, with the comments as more items, then a
# fix-check of reviewed_sha..head against both (check_pr), never a new full review: that one comes
# only with a `full review` line, or when the fix is over FIXCHECK_FULL_LINES (fix_cont). With
# such a line the owed round is dropped and 1 returned: the caller takes its full-review way. 1
# also when this needs-you is not one; 0 once handled or deferred.
owed_round() {
  local n=$1 pr=$2 c=$3 rsha ff items cm=""
  [ "$(st_get "$n" fix_owed)" = 1 ] && [ "$(st_get "$n" phase)" = needs-you ] || return 1
  if full_review_asked "$c"; then
    # review_asked: a pass of this head never stands in for the full review asked for
    st_set "$n" fix_owed= stage=review reviewed_sha= review_asked=1; return 1
  fi
  rsha=$(st_get "$n" reviewed_sha); ff=$(findings_file "$pr" "$rsha")
  items=$(cat "$ff" 2>/dev/null)
  [ -n "$items" ] || items="The review's findings were not saved: read the newest PR comment ending in 'Review verdict: changes $rsha' (gh pr view $pr -R $REPO --comments)."
  resume "$n" "The independent reviewer asked for changes on PR #$pr and the user commented on them: this is the review's fix round. Fix every blocking finding below and address the user's comments, rerun the checks, push once and stop: the dispatcher watches CI. Leave the review's non-blocking findings alone: they went to a follow-up issue. A narrow fix-check of your fix diff against the findings and the comments follows, then the merge or the product owner. The blocking findings: $(findings_inline "$items" "$ff") The user's comments: ${c:-none found; read the latest comments on the PR and the issue}" fix || return 0
  [ -n "$c" ] && cm=$'\n\n'"The user's comments on the review (also to be fixed): $c"
  save_findings "$n" "$pr" "$ff" "$items$cm"
  [ "$4" = needs-work ] && edit_issue "$n" --remove-label needs-work
  rfix_count "$n" "$pr"
  st_set "$n" fix_owed= fix_cont=1 stage=fixing
  log "#$n PR #$pr: the user's $4 on the review's changes; the worker fixes the findings of ${rsha:0:7}, then a fix-check"
}

resume_step() {
  local n=$1 phase pr c since refused=""
  run_alive "$n" && return 0
  phase=$(st_get "$n" phase); pr=$(st_get "$n" pr); needs_work_from_pr "$n" "$pr" || return 0
  if has_label "$n" plan-ok; then
    room "$n" || return 0
    # the lead's answers to the plan's questions ("split; build package 1 only") shape what gets
    # built; a gh error keeps plan-ok for the next pass rather than resume without them
    since=$(st_get "$n" ny_at); c=$(user_comments "$n" "$pr" "${since:-$(st_get "$n" started)}") ||
      { log "#$n: gh error reading the comments for plan-ok; retrying next pass"; return 0; }
    resume "$n" "The user approved the plan. Execute it.$(worker_skills) Build it in this PR: replace each \`Plan for #<n>\` line with \`Closes #<n>\` and set the real \`Tier:\` line.${c:+ The user answered the questions of the plan: $c}" plan || return 0
    edit_issue "$n" --remove-label plan-ok   # only once the worker runs: a failed start keeps the signal
    st_set "$n" plan_ok=1; new_cycle "$n"
  elif has_label "$n" needs-work; then
    room "$n" || return 0
    # the user's comments since the PR reached them: the accept request, else the merge or the verdict
    # the newest of them; none at all (no verdict yet) → since the worker started
    since=$(newest_of "$(st_get "$n" accept_at)" "$(st_get "$n" merge_at)" "$(iso_epoch "$(st_get "$n" verdict_at)")")
    # a gh error decides nothing (it could hide a `full review` line): needs-work stays for the next pass
    c=$(user_comments "$n" "$pr" "${since:-$(st_get "$n" started)}") ||
      { log "#$n PR #$pr: gh error reading the comments for needs-work; retrying next pass"; return 0; }
    owed_round "$n" "$pr" "$c" needs-work && return 0
    extra_round "$n" "$pr" "$c" && return 0
    # a refused accept (or a Maintainer accept or Risk: high kept only in the state, read before
    # new_cycle clears them) asks for a full review: a reused pass would merge without the accept
    { has_label "$n" awaiting-accept || [ "$phase" = accept ] || [ -n "$(st_get "$n" review_maccept)" ] ||
      [ "$(st_get "$n" review_risk)" = high ]; } && refused=1
    resume "$n" "The user rejected PR #$pr (needs-work). Address their comments, rerun the checks, push once and stop: the dispatcher watches CI. Their comments: ${c:-none found; read the latest comments on the PR and the issue}" needs-work || return 0
    # a full review asked for re-reviews the open items: nobody fixed or answered them yet
    full_review_asked "$c" || history_answer "$pr"
    edit_issue "$n" --remove-label needs-work
    # a needs-work after a review is a review fix (REVIEW_FIX_ATTEMPTS), never a CI one
    [ -n "$pr" ] && rfix_count "$n" "$pr"
    has_label "$n" awaiting-accept && edit_issue "$n" --remove-label awaiting-accept
    new_cycle "$n"
    # kept until the full review's verdict is acted on: it holds for the next head, even the same
    # one, and through a review run that ends with no verdict (check_pr)
    { [ -n "$refused" ] || full_review_asked "$c"; } && st_set "$n" review_asked=1
  elif [ "$phase" = needs-you ]; then
    c=$(user_comments "$n" "$pr" "$(st_get "$n" ny_at)")
    [ -n "$c" ] && room "$n" && owed_round "$n" "$pr" "$c" comment && return 0
    # the answer to a worker's Question: is the one follow-up whose conversation matters
    [ -n "$c" ] && room "$n" && resume "$n" "The user answered: $c" "$([ "$(st_get "$n" ny_kind)" = question ] && echo answer || echo user)"
  elif [ "$phase" = limited ]; then
    room "$n" && resume "$n" "$(limited_task "$n")" limited && handoff_keep "$n" ""
  elif [ "$phase" = continue ]; then
    # PACE=pause holds it like a new start: a continuation is a whole new run (#127)
    pace_holds && { warn_once "pace-continue-$n" "#$n: PACE=pause holds its continuation"; return 0; }
    room "$n" && resume "$n" "$(continue_task "$n")" continue && handoff_keep "$n" ""
  elif [ "$phase" = retry ]; then
    room "$n" && resume "$n" "$(crash_task "$n")" crash
  elif [ "$phase" = waiting ]; then
    unit_blocked "$n" || { blocked_unmark "$(lead_of "$n")"; room "$n" && resume "$n" "The issue is no longer labelled \`blocked\`: check its blockers again, then do the work." blocked; }
  fi
  return 0
}

