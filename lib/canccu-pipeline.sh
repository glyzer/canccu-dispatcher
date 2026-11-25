# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by canccu-dispatch after canccu-common.sh; never run: the dispatcher pass, steps 2 (reap) and 4 (resume).

# ---------------------------------------------------------------- 2. reap

# reap_worker, reap_review, reap_answer: the pass read the phase before the run ended; canccu-stop
# sets phase=stopped before it kills the run, so a run whose phase moved on meanwhile is not reaped
reap_worker() {
  local n=$1 started last kind status q r b="" p ph c fresh=""
  run_alive "$n" && return 0
  # starting: run_worker set it before the engine call, so a dispatcher killed in between leaves
  # a unit the reap still finds
  ph=$(st_get "$n" phase)
  case $ph in work|starting) ;; *) return 0 ;; esac
  started=$(st_get "$n" started); last="$WORKERS_DIR/$REPO_NAME-$n.last"
  if [ -e "$last" ] && (( $(stat -c %Y "$last") >= ${started:-0} )); then
    IFS='|' read -r kind status <<<"$(run_exit "$last")"; fresh=1
  elif [ "$ph" = starting ]; then
    (( $(now) - ${started:-0} < STARTING_GRACE )) && return 0
    kind=crashed status="killed while starting"
  else kind=none status="ended without an exit report"; fi
  [ -e "$(run_lock "$n")" ] && mut "$CANCCU_WORKER" --unlock "$REPO_NAME" "$n" >/dev/null
  [ "$ph" = starting ] && st_set "$n" phase=work prev_phase=
  # an older worker's report says `blocked` for the classifier's denials even when the run worked
  # around them: an open PR is the proof of the work, so check_pr judges it like any done run
  [ "$kind" = blocked ] && [ -n "$(pr_for "$n")" ] && kind="done"
  # a continuation's line says which it is (#127); what the run used counts against the work budget
  c=$(st_get "$n" cont)
  # a report older than the run is the run before's: not counted again
  is_deep "$n" || [ -z "$fresh" ] || used_add "$n"
  p=$(pr_for "$n"); spend_note "$n" "${started:-0}" "pr=${p:-none}" "rounds=$(fix_rounds "$n")" ${c:+"cont=$c"}
  if [ "$kind" = "done" ] && run_msg "$n" | grep -qxF 'Permission denials (information):'; then
    denied_ok "$n" "$p" || return 0
  fi
  case $kind in
    done)
      st_set "$n" crash_tries= retry_status= cont=
      q=$(worker_question "$(run_msg "$n")")
      # a run that finished with no PR is resumed afresh (resume); one nudged to stop mid-work is not
      p=$(pr_for "$n")
      [ -n "$p" ] || is_step_run "$n" || b=$(worker_blocked "$(run_msg "$n")")
      # a PR opened after this pass read the list: read it again before parking the run as blocked
      [ -n "$b" ] && fetch_prs && p=$(pr_for "$n") && [ -n "$p" ] && b=""
      [ -n "$p" ] || st_set "$n" no_pr=1
      # a question goes to the answerer even after a nudge (it waits for the reset anyway)
      if [ "$(st_get "$n" nudged)" = 1 ] && [ -z "$q" ]; then
        # stopped at a safe point at the usage stop: continue after the 5-hour reset
        # the reset it was nudged for; already passed: no back-off (it continues next pass)
        r=$(st_get "$n" nudge_reset); [[ $r =~ ^[0-9]+$ ]] && (( r > $(now) )) && set_backoff "$r"
        handoff_keep "$n" "$(run_msg "$n")"
        st_set "$n" phase=limited nudged= nudge_reset= no_pr=
        log "#$n stopped at a safe point (usage); resumes after the reset"
      elif [ -n "$b" ]; then st_set "$n" nudged=; wait_blocked "$n" "$b"
      elif [ -n "$q" ]; then st_set "$n" nudged=; ask "$n" "$q"
      else st_set "$n" phase=check check_at="$(now)"; log "#$n worker done"; fi ;;
    background)
      # what it pushed may be all of it: check_pr judges the PR, or gives a run without one its finish run
      [ -n "$p" ] || st_set "$n" no_pr=1
      st_set "$n" phase=check check_at="$(now)"; log "#$n worker ended with background work pending" ;;
    usage)
      set_backoff "$(usage_reset "$(run_msg "$n")")"
      handoff_keep "$n" ""   # cut off mid-step: no handoff, and an older one is not this stop's
      st_set "$n" phase=limited; log "#$n hit the usage limit; resumes after the back-off" ;;
    crashed|none|stalled)
      # an error result (run_exit's crashed too) is the run's own outcome: a retry would meet it again
      { [[ $status != error* ]] && crash_retry "$n" "$status"; } || needs_you "$n" "the worker stopped: $status" "$(run_msg "$n")" ;;
    budget) budget_stop "$n" "$status" ;;
    *) needs_you "$n" "the worker stopped: $status" "$(run_msg "$n")" ;;
  esac
}

# reap_review <n>: the reviewer (a full review or a fix-check) wrote its review to a file and
# exited. The dispatcher checks that the file ends in a verdict for exactly the reviewed head,
# posts it as REVIEWER_LOGIN, then acts on the posted comment (the one the review-gate check reads
# too). Every run ends with one outcome line in the log: posted, post failed, post timed out, no
# valid verdict, or void (a push during the run).
reap_review() {
  local n=$1 pr sha j head kind status last started f at why what reason="" REVIEW_SETTLED REVIEW_PASSRULE REVIEW_CHANGED
  pr=$(st_get "$n" pr); sha=$(st_get "$n" review_sha)
  run_alive "review-$pr" && return 0
  [ "$(st_get "$n" phase)" = review ] || return 0
  [ -e "$(run_lock "review-$pr")" ] && mut "$CANCCU_WORKER" --unlock "$REPO_NAME" "review-$pr" >/dev/null
  j=$(pr_detail "$pr") || { log "#$n PR #$pr: gh error reading the review; retrying next pass"; return; }
  head=$(jqr .headRefOid <<<"$j")
  if [ "$(jqr .state <<<"$j")" != OPEN ] || [ "$head" != "$sha" ]; then
    outcome "$n" "$pr" "$sha" "void: the PR changed during the run (now ${head:0:7}); re-checking"
    spend_note "review-$pr" "$(st_get "$n" started)" verdict=void
    clear_post_ny "$n"
    st_set "$n" phase=check check_at="$(now)"; return
  fi
  # posted, but GitHub does not list it yet: wait POST_WAIT before calling it missing; a post that
  # timed out (it may not have landed) is posted again after the wait instead
  if [ -z "$(verdict_of "$j" "$(st_get "$n" verdict_at)")" ] && [ "$(st_get "$n" posted)" = "$sha" ]; then
    at=$(st_get "$n" posted_at)
    if (( $(now) - ${at:-0} < POST_WAIT )); then log "#$n PR #$pr: review posted; acting on it once GitHub lists it"; return; fi
    [ "$(st_get "$n" post_uncertain)" = 1 ] && st_set "$n" posted= post_uncertain=
  fi
  if [ -z "$(verdict_of "$j" "$(st_get "$n" verdict_at)")" ] && [ "$(st_get "$n" posted)" != "$sha" ]; then
    kind=none last="$WORKERS_DIR/$REPO_NAME-review-$pr.last" started=$(st_get "$n" started) f=$(review_file "$pr" "$sha")
    review_ctx "$n" "$pr" "$sha"
    [ -e "$last" ] && (( $(stat -c %Y "$last") >= ${started:-0} )) &&
      IFS='|' read -r kind status <<<"$(run_exit "$last")"
    spend_review_note "$n" "$pr" "$f" "$sha" "${started:-0}"
    if [ -e "$f" ] && (( $(stat -c %Y "$f") >= ${started:-0} )) && [ -n "$(file_verdict "$f" "$sha")" ]; then
      # 2: the post timed out and may have landed
      review_post "$n" "$pr" "$f" "$sha" || { (( $? == 2 )) && st_set "$n" posted="$sha" posted_at="$(now)" post_uncertain=1; return 0; }
      st_set "$n" posted="$sha" posted_at="$(now)" post_uncertain=
      j=$(pr_detail "$pr") || { log "#$n PR #$pr: review posted; reading it back next pass"; return; }
      [ -n "$(verdict_of "$j" "$(st_get "$n" verdict_at)")" ] || { log "#$n PR #$pr: review posted; acting on it once GitHub lists it"; return; }
    else
      if [ ! -e "$f" ]; then why="no review file"
      elif (( $(stat -c %Y "$f") < ${started:-0} )); then why="the review file is older than the run"
      elif [ -n "$(file_verdict_raw "$f" "$sha")" ]; then reason=$(review_miss "$f") why="a file: $reason"
      else why="the file's last line is no verdict for ${sha:0:7}"; fi
      if [ "$kind" = usage ]; then
        outcome "$n" "$pr" "$sha" "no valid verdict ($why; usage limit); again after the back-off"
        set_backoff "$(usage_reset "$(run_msg "review-$pr")")"
        st_set "$n" phase=check check_at="$(now)"
        return
      fi
      # a run that ended well but wrote no valid file is asked once per head to write it
      if [ "$kind" = "done" ] && [ "$(st_get "$n" file_retry)" != "$sha" ]; then
        may_start "$n" || return 0
        retry_review_file "$pr" "$n" "$sha" "${reason:-}" || return 0
        st_set "$n" file_retry="$sha" started="$(now)"
        log "#$n PR #$pr: the reviewer left $why; asked once to write the review file"
        return
      fi
      # a run cut off by its turn or time budget left nothing to resume from: one full review per
      # head (also after a fix-check, whose narrow diff has no verdict to build on)
      case ${status:-} in "stopped: turn"*|"stopped: time budget"*) kind_tt=1 ;; *) kind_tt= ;; esac
      if [ "$kind" = budget ] && [ -n "$kind_tt" ] && [ "$(st_get "$n" review_retry)" != "$sha" ]; then
        may_start "$n" || return 0
        if is_fixcheck_mode "$(st_get "$n" review_mode)"; then what="fix-check"; else what=reviewer; fi
        start_review "$pr" "$n" "$sha" || return 0
        st_set "$n" review_retry="$sha"
        log "#$n PR #$pr: the $what stopped at its budget with no verdict; one full review of ${sha:0:7}"
        return
      fi
      outcome "$n" "$pr" "$sha" "no valid verdict ($why; run ${status:-$kind})"
    fi
  fi
  # the review is acted on now (a post that timed out may have landed): a failed post's
  # needs-you goes; act_verdict sets it again when the verdict needs the user
  clear_post_ny "$n"
  act_verdict "$n" "$pr" "$j"
}

# issue_comment_by <n> <since epoch> <regex>: newest issue comment by USER_LOGIN since then whose
# body matches; "<url>\t<body on one line>"
issue_comment_by() {
  ghj issue view "$(lead_of "$1")" -R "$REPO" --json comments |
    jqr --arg u "$USER_LOGIN" --arg s "$(iso "${2:-0}")" --arg re "$3" '[.comments[]
      | select(.author.login == $u and .createdAt > $s and (.body | test($re)))] | sort_by(.createdAt) | last
      | select(. != null) | "\(.url // "")\t\(.body | gsub("[\r\n\t]+"; " "))"'
}

# reap_answer <n>: ANSWERED → the worker resumes with the answer; ESCALATE or nothing → needs-you
reap_answer() {
  local n=$1 started last kind status out mark c url q a
  run_alive "answer-$n" && return 0
  [ "$(st_get "$n" phase)" = answer ] || return 0
  [ -e "$(run_lock "answer-$n")" ] && mut "$CANCCU_WORKER" --unlock "$REPO_NAME" "answer-$n" >/dev/null
  started=$(st_get "$n" started); last="$WORKERS_DIR/$REPO_NAME-answer-$n.last"; kind=none
  [ -e "$last" ] && (( $(stat -c %Y "$last") >= ${started:-0} )) && IFS='|' read -r kind status <<<"$(run_exit "$last")"
  q=$(q_get "$n")
  if [ "$kind" = usage ]; then
    set_backoff "$(usage_reset "$(run_msg "answer-$n")")"
    a=$(st_get "$n" answers); a=${a:-1}   # a round cut short by the limit doesn't count
    st_set "$n" phase=question answers=$(( a > 0 ? a - 1 : 0 ))
    log "#$n answerer hit the usage limit; asks again after the back-off"; return
  fi
  out=$(run_msg "answer-$n")
  mark=$(grep -oE '\b(ANSWERED|ESCALATE)\b' <<<"$out" | tail -1)
  spend_note "answer-$n" "${started:-0}" "answer=$(tr '[:upper:]' '[:lower:]' <<<"${mark:-none}")"
  if [ "$kind" = "done" ] && [ "$mark" = ANSWERED ]; then
    c=$(issue_comment_by "$n" "${started:-0}" '^[[:space:]*_]*Answer:'); url=${c%%$'\t'*}
    [ -n "$c" ] && c=${c#*$'\t'} || c=$out
    # logged for the digest only once the worker runs: a failed resume is retried, not listed twice
    resume "$n" "An answerer (not the user) answered your question from the repo's decisions and docs; the user may overrule it on the issue. $(oneline 4000 "$c") Continue with that." answer || return 0
    (( CANCCU_DRY )) || printf '%s\t%s\t%s\t%s\n' "$(now)" "$n" "${url:-#$n}" "$(oneline 200 "$q")" >> "$CANCCU_HOME/answers.log"
    log "#$n question answered${url:+: $url}"
  else
    c=$(issue_comment_by "$n" "${started:-0}" '^[[:space:]*_]*Needs the product owner:'); url=${c%%$'\t'*}
    needs_you "$n" "the worker's question needs the product owner${url:+ ($url)}$([ "$kind" = "done" ] || echo "; the answerer stopped: $status")" "$q" question
  fi
}

# check_pr <n>: the worker is done; the PR and its CI decide what happens next
check_pr() {
  local n=$1 pr j head at rsha fix c
  pr=$(pr_for "$n")
  if [ -z "$pr" ]; then
    # the health pass's or deep review's PR left the open list (closed or merged): health_pr_closed,
    # deep_tick or finish_unit takes it from here. Still open but not ours (another branch): needs-you below.
    is_step_run "$n" && pr=$(st_get "$n" pr) && [ -n "$pr" ] && ! pr_is_open "$pr" && return 0
    if is_health "$n" && grep -qE '^[[:space:]*_]*Health: nothing to do' <<<"$(run_msg "$n")"; then health_nothing "$n"; return; fi
    finish_once "$n" && return 0
    # pushed with commits ahead: the dispatcher opens the PR; the next pass checks it (#237)
    dispatcher_pr "$n" && return 0
    needs_you "$n" "the worker finished without an open PR" "$(run_msg "$n")" "" work; return
  fi
  st_set "$n" pr="$pr" finish_tried=
  c=$(st_get "$n" contract_merged)
  if [ "$(pr_get "$pr" .isDraft)" = true ]; then
    if [ -n "$c" ]; then
      contract_resume "$n" "$pr" "$c" || return 0
      st_set "$n" contract_merged=
    elif is_plan_pr "$n" "$pr"; then
      needs_you "$n" "plan ready for OK: $(pr_get "$pr" .url) — label this issue \`plan-ok\` to approve, or comment" "" plan work
    else needs_you "$n" "PR #$pr is still a draft" "$(run_msg "$n")" "" work; fi
    return
  fi
  [ -z "$c" ] || st_set "$n" contract_merged=
  # a conflicting PR gets no CI at all: main merged in now, not a no-checks needs-you later (fix-check waits on it too)
  [ "${MERGE_MAIN_ANY_PHASE:-1}" = 1 ] && conflict_merge "$n" "$pr" "$(pr_get "$pr" .headRefOid)" && return 0
  at=$(st_get "$n" check_at); at=${at:-$(now)}
  case $(ci_state "$pr") in
    red) ci_note "$n" "$at" ci=red; ci_red "$n" "$pr"; return ;;
    pending)
      (( $(now) - at > CI_WAIT_MIN * 60 )) && needs_you "$n" "CI on PR #$pr is still pending after $CI_WAIT_MIN min" "" "" ci &&
        st_set "$n" ny_wait=ci
      return ;;
    none)
      (( $(now) - at > ${NO_CHECKS_MIN:-10} * 60 )) &&
        needs_you "$n" "no CI checks on PR #$pr: $(no_checks_why "$pr")" "" "" no-checks &&
        st_set "$n" ny_wait=ci
      return ;;
  esac
  # ci=rerun-green: a rerun of failed jobs turned the head green (a flaky check)
  c=green; [ "$(st_get "$n" ci_rerun)" = "$(pr_get "$pr" .headRefOid)" ] && c=rerun-green
  ci_note "$n" "$at" "ci=$c"
  j=$(pr_detail "$pr") || { log "#$n PR #$pr: gh error; retrying next pass"; return; }
  contract_closes "$n" "$pr" "$j" && return
  head=$(jqr .headRefOid <<<"$j")
  if [ -n "$(verdict_of "$j" "$(st_get "$n" verdict_at)")" ]; then act_verdict "$n" "$pr" "$j"; return; fi
  # a reviewer started earlier (canccu-review) is still running: wait for it, on the head it reviews
  if run_alive "review-$pr"; then
    at=$(running_review_sha "$pr")
    st_set "$n" phase=review review_sha="${at:-$head}" posted= started="$(lock_get "$(run_lock "review-$pr")" started)" \
      review_mode="$(cat "$CANCCU_HOME/reviews/$pr.mode" 2>/dev/null)"
    return
  fi
  # a head that passed already: its verdict is reused, unless the lead asked for a full review
  # (review_asked), the worker's conflict merge run pushed nothing (postpass_step's needs-you), or
  # a fix round waits on that very head (the review's `changes` came after the pass: below, the
  # worker pushed no fix)
  rsha=$(st_get "$n" reviewed_sha)
  case $(st_get "$n" stage) in fixing|fixcheck) fix=1 ;; *) fix=0 ;; esac
  if [ -z "$(st_get "$n" review_asked)" ] && [ "$(st_get "$n" conflict_sha)" != "$head" ] &&
     ! { (( fix )) && [ "$head" = "$rsha" ]; } && passed_before "$n" "$pr" "$head"; then
    log "#$n PR #$pr: head ${head:0:7} passed review already; no new review (verdict reused)"
    after_pass "$n" "$pr" "$head" "earlier"; return
  fi
  # a fix round that pushed nothing is the needs-you below: no body send-back first
  { (( fix )) && [ "$head" = "$rsha" ]; } || ! body_lines_missing "$n" "$pr" "$j" || return
  postpass_step "$n" "$pr" "$head" && return
  # the worker fixed the full review's findings: the fix-check of reviewed_sha..head, never a
  # second full review. A push after a fix-check voids it (its verdict names the old head): a
  # new fix-check of the whole fix diff runs.
  if (( fix )) && [ -n "$rsha" ] && [ "$head" = "$rsha" ]; then
    needs_you "$n" "the worker pushed no fix for the review's findings on PR #$pr (the head is still the reviewed ${rsha:0:7}). If no fix was needed (a finding was wrong), \`canccu-review $pr\` reviews the head again: its pass merges, its \`changes\` comes back here; otherwise comment the way on and the worker resumes"; return
  fi
  { backing_off || pause_holds; } && return
  # with reviews refused the review cannot start: it waits for no shared slot
  if [ -n "$(reviewer_token_problem)" ]; then room || return; else room "$n" || return; fi
  if (( fix )) && [ -n "$rsha" ]; then start_fixcheck "$pr" "$n" "$rsha" "$head"
  else start_review "$pr" "$n" "$head"; fi
}

# ci_unpark <n>: a needs-you that only waited on CI (ny_wait=ci: pending past CI_WAIT_MIN, or no
# checks past NO_CHECKS_MIN) goes back to check by itself once the PR's CI is green or red: the
# label comes off, nothing is resumed, and check_pr (called next) reviews it or parks it again for
# the red CI. A comment by the user since it parked leaves it to resume_step; a gh error
# reading the comments leaves it for the next pass. 0 when it is back in check.
ci_unpark() {
  local n=$1 pr c
  [ "$(st_get "$n" ny_wait)" = ci ] || return 1
  pr=$(st_get "$n" pr); [ -n "$pr" ] || return 1
  case $(ci_state "$pr") in green|red) ;; *) return 1 ;; esac
  c=$(user_comments "$n" "$pr" "$(st_get "$n" ny_at)") || return 1
  [ -z "$c" ] || return 1
  has_label "$n" needs-you && edit_issue "$n" --remove-label needs-you
  st_set "$n" phase=check ny_wait=
  log "#$n PR #$pr: CI is no longer pending; back to check"
}

# ready_unpark <n>: a needs-you of a finished worker (ny_stage work: it stopped, not a review or a
# fix round) or of a red CI (ny_stage ci: a flaky run re-run green costs no worker run) whose label
# the lead removed with no comment, and whose PR waits for review (open, not a draft, CI green),
# goes back to check; check_pr (called next) starts the review. A comment
# since it parked leaves it to resume_step. 0 when it is back in check.
ready_unpark() {
  local n=$1 pr c
  case $(st_get "$n" ny_stage) in work|ci) ;; *) return 1 ;; esac
  ! has_label "$n" needs-you || return 1
  pr=$(st_get "$n" pr); [ -n "$pr" ] && pr_is_open "$pr" || return 1
  [ "$(pr_get "$pr" .isDraft)" = false ] && [ "$(ci_state "$pr")" = green ] || return 1
  c=$(user_comments "$n" "$pr" "$(st_get "$n" ny_at)") || return 1
  [ -z "$c" ] || return 1
  st_set "$n" phase=check check_at="$(now)" no_pr=
  log "#$n PR #$pr: needs-you lifted, the PR waits for review; back to check"
}

# adopt: an open PR of ours (USER_LOGIN, not a fork, branch <n>-…) for an in-progress issue (pr_issues)
# nobody manages, with no worker running
adopt() {
  local pr n c j
  for pr in $(jqr '.[].number' <<<"$PRS"); do
    j=$(pr_get "$pr" .)
    for n in $(pr_issues "$j"); do
      is_managed "$n" && continue
      [ "$(unit_of_issue "$n")" = "$n" ] || continue   # a package's issue is never adopted alone
      [ -z "$(pr_foreign "$j" "$n")" ] || continue
      has_label "$n" in-progress && ! run_alive "$n" || continue
      c=0; is_exclusive "$n" && c=1
      st_set "$n" phase=check pr="$pr" check_at="$(now)" adopted=1 exclusive=$c; new_cycle "$n"
      claim_color "$n"
      log "#$n adopted (PR #$pr)"
    done
  done
}

# shellcheck source=canccu-resume.sh
. "$_canccu_lib/canccu-resume.sh"
# shellcheck source=canccu-exits.sh
. "$_canccu_lib/canccu-exits.sh"
# shellcheck source=canccu-prbody.sh
. "$_canccu_lib/canccu-prbody.sh"
