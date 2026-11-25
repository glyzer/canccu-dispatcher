# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): actions: needs-you, resume, start, accept, act on a verdict, labels
# (the merge calls: lib/canccu-mergecall.sh).

# ---------------------------------------------------------------- actions

# comment_issue and edit_issue take a unit key too: they act on its lead issue
comment_issue() { local l; l=$(lead_of "$1"); [ -n "$l" ] || return 0; mut gh issue comment "$l" -R "$REPO" --body "$(home_tilde "$2")"$'\n\n'"$CANCCU_MARK"; }
# comment_issue_url <K> <body>: comment_issue, setting COMMENT_URL to the new comment's link (gh
# prints it), or to nothing. Not run in $(…), so a dry run's "would:" line goes where mut's go;
# gh's output goes to dispatch.log in the dispatcher, else to stderr.
comment_issue_url() {
  local l out rc; COMMENT_URL=""; l=$(lead_of "$1"); [ -n "$l" ] || return 0
  if (( CANCCU_DRY )); then mut gh issue comment "$l" -R "$REPO" --body "$(home_tilde "$2")"$'\n\n'"$CANCCU_MARK"; return 0; fi
  out=$(guard 60 gh issue comment "$l" -R "$REPO" --body "$(home_tilde "$2")"$'\n\n'"$CANCCU_MARK" 2>&1); rc=$?
  mut_show "$out"
  COMMENT_URL=$(grep -oE 'https://[^[:space:]]+#issuecomment-[0-9]+' <<<"$out" | tail -1)
  return $rc
}
# issue_url <K> / pr_url <pr>: the links a needs-you item has in the snapshot; its_url <url>: " · <url>",
# the end of the dispatcher's needs-you and awaiting-accept lines, or nothing without a link
issue_url() { local l; l=$(lead_of "$1"); [ -n "$l" ] && echo "https://github.com/$REPO/issues/$l"; return 0; }
pr_url() { echo "https://github.com/$REPO/pull/$1"; }
its_url() { [ -n "${1:-}" ] && printf ' · %s' "$1"; return 0; }
comment_pr() { mut gh pr comment "$1" -R "$REPO" --body "$(home_tilde "$2")"$'\n\n'"$CANCCU_MARK"; }
edit_issue() { local n; n=$(lead_of "$1"); shift; [ -n "$n" ] || return 0; mut gh issue edit "$n" -R "$REPO" "$@"; }
# needs_work_from_pr <K> <pr>: a `needs-work` the user put on the unit's PR moves to its lead
# issue, so every later check (run reservation, comments since, removal) reads one label. This
# pass's ISSUES and PRS follow, so resume_step handles it now. 1 on a gh error (the PR keeps it).
needs_work_from_pr() {
  local n=$1 pr=$2 l
  [ -n "$pr" ] && pr_has_label "$pr" needs-work || return 0
  # no lead issue (a health unit whose step issue is gone): nowhere to move it
  l=$(lead_of "$n"); [ -n "$l" ] || return 0
  # added before removed: an error between the two leaves the label on both, never on neither
  if ! { mut gh issue edit "$l" -R "$REPO" --add-label needs-work && mut gh pr edit "$pr" -R "$REPO" --remove-label needs-work; }; then
    log "#$n PR #$pr: gh error moving \`needs-work\`; retrying next pass"; return 1
  fi
  ISSUES=$(jq -c --argjson n "$l" 'map(if .number == $n then .labels += [{name: "needs-work"}] else . end)' <<<"$ISSUES")
  PRS=$(jq -c --argjson p "$pr" 'map(if .number == $p then .labels |= map(select(.name != "needs-work")) else . end)' <<<"$PRS")
  log "#$n PR #$pr: \`needs-work\` was on the PR; moved to issue #$l"
}
# edit_members <K> <gh issue edit args...>: the same on every issue of the unit
edit_members() { local k=$1 m; shift; for m in $(members_of "$k"); do mut gh issue edit "$m" -R "$REPO" "$@"; done; }

# needs_you <n> <reason> [message] [kind] [stage]: stop for the user. The kind (plan, question;
# default needs-you) is kept as ny_kind for the status snapshot, the stage it parked at (work, ci,
# no-checks, …; default: from its phase, pkg_stage) as ny_stage. ny_wait goes: check_pr sets
# it again after a park that only waits on CI (ci_unpark).
needs_you() {
  local n=$1 reason=$2 msg=${3:-} body stg=${5:-}
  # where it parked (the monitor's inbox shows it): the caller's stage (check_pr knows why it
  # stopped), else the pipeline step before needs-you
  [ -z "$stg" ] && [ -n "$(st_get "$n" phase)" ] && stg=$(pkg_stage "$n" 2>/dev/null)
  case $stg in needs-you) stg=$(st_get "$n" ny_stage) ;; accept|merging) stg=merge ;; esac
  body="**Needs you** (canccu-dispatch): $reason"
  [ -n "$msg" ] && body+=$'\n\n'"$(quote 1500 "$msg")"
  edit_issue "$n" --add-label needs-you
  comment_issue "$n" "$body"
  st_set "$n" phase=needs-you ny_at="$(now)" reason="$(oneline 200 "$reason")" ny_kind="${4:-}" ny_stage="$stg" ny_wait=
  log "#$n needs-you: $reason$(its_url "$(issue_url "$n")")"
}

# resume <n> <message> [kind]: the issue's worker follows up with the message. The kind (answer,
# plan, fix, ci, needs-work, merge, limited, blocked; default user: a comment, canccu-run) picks a
# resumed session where RESUME_ON names it, else a fresh one with the handoff (lib/canccu-followup.sh);
# a fix kind runs on FIX_MODEL and FIX_EFFORT. A PR armed for auto-merge is disarmed first
# (armed), and `accepted` dropped: the worker is about to change it.
resume() {
  local n=$1 pr msg=$2 kind=${3:-user} q how=resume fl=() model=$MODEL effort="" type budget; pr=$(st_get "$n" pr)
  blocked_held "$n" "the resumed worker" && return 1
  step_run_held "$n" "the resumed worker" && return 1
  if [ -n "$pr" ] && [ "$(st_get "$n" phase)" = merging ]; then
    armed "$n" "$pr" && mut gh pr merge "$pr" -R "$REPO" --disable-auto
    pr_has_label "$pr" accepted && mut gh pr edit "$pr" -R "$REPO" --remove-label accepted
  fi
  # a run that finished with no PR (it stopped blocked, asked, or built nothing) is not resumed:
  # reloading its context costs more than it holds. A fresh session gets the whole task.
  if [ "$(st_get "$n" no_pr)" = 1 ] && [ -z "$(pr_for "$n")" ]; then
    # the answer to a question needs the question: the old session that asked it is gone
    q=""; { [ "$(st_get "$n" phase)" = answer ] || [ "$(st_get "$n" ny_kind)" = question ]; } && q=$(q_get "$n")
    mut rm -f "$WORKERS_DIR/$REPO_NAME-$n.id"; msg="$(unit_prompt "$n")${q:+ Your earlier run stopped with this question: $(oneline 2000 "$q")} $msg"
    how=fresh fl=(--fresh)
  elif ! resume_on "$kind"; then
    # the rules first, then the task: only the end of the handoff may be cut
    msg="$SAFETY_BLOCK $(oneline 5000 "$msg") $(handoff "$n" "$kind")" how=fresh fl=(--fresh)
  fi
  # the run type spend.log names: a fix kind is a fix, a merge a merge, the rest build
  type=build; [ "$kind" = merge ] && type=merge
  if fix_kind "$kind"; then model=${FIX_MODEL:-$MODEL} effort=$(run_effort FIX_EFFORT) type=fix; fi
  # a resumed fix round has its first prompt's rule, but TEST_TIER may have changed since (a fresh
  # one gets it in the handoff)
  fix_kind "$kind" && [ "$how" = resume ] && msg+=" $(test_rule handoff)"
  # after the usage limit the run goes on with what is left of the work budget, never less than a
  # resume's (#127)
  case $kind in
    continue) budget=$(continue_budget "$n") ;;
    limited) budget=$(work_left "$n" "$(resume_budget "$n")") ;;
    *) budget=$(resume_budget "$n") ;;
  esac
  # workers never review: a resumed worker is told so as well
  MODEL=$model RUN_EFFORT=$effort run_worker "$n" "$msg Do not review your own work; run the checks only." "$budget" "$type" "${fl[@]}" || return 1
  has_label "$n" needs-you && edit_issue "$n" --remove-label needs-you
  if [ "$how" = fresh ]; then log "#$n resumed (fresh session, $kind): $(oneline 100 "$2")"
  else log "#$n resumed: $(oneline 100 "$2")"; fi
}

# blocked_held <K> <what>: the unit is labelled `blocked`, so nothing of it runs (said once)
blocked_held() { unit_blocked "$1" || return 1; warn_once "blocked-$1" "#$1 is labelled \`blocked\`: $2 waits until the label goes"; }

# issue_prompt <n> [title] [plan approved 0|1, default: its plan_ok] [branch, default: its own]:
# a new worker's whole task for issue n; with its plan merged (plan_back), the order to execute it.
# An issue started before its branch was kept gets the name from its title, as then.
issue_prompt() {
  local n=$1 title=${2:-} p=${3:-$(st_get "$1" plan_ok)} br=${4:-$(st_get "$1" branch)} prompt wp
  if [ -z "$br" ]; then
    [ -n "$title" ] || title=$(title_of "$n")
    [ -n "$title" ] || title=$(safe_title "$(ghj issue view "$n" -R "$REPO" --json title | jqr .title)")
    br=$(issue_branch "$n" "$title")
  fi
  wp=${WORKER_PROMPT//@BASE@/"$BASE_BRANCH"}
  # shellcheck disable=SC2059
  printf -v prompt "$wp" "$REPO" "$n" "$n" "$br" "${WORKER_EXTRA:+ $WORKER_EXTRA}"
  # after printf: a % in the host's sentence is text, not a format
  prompt=${prompt//@SKILLS@/"$(worker_skills)"}; prompt=${prompt//@TESTS@/"$(test_rule)"}
  prompt+=" $(contract_rule "$br")"
  [ "$p" = 1 ] && prompt+=" $(plan_merged_text "docs/plans/issue-$n.md")"
  printf '%s' "$prompt"
}
# issue_branch <n> <title>: the branch an issue's worker creates
issue_branch() { echo "$1-$(slug "$2")"; }
# unit_prompt <K>: the whole task of a unit's worker, for a fresh session
unit_prompt() {
  if is_health "$1"; then health_prompt "$(st_get "$1" step)" "$1"
  elif is_deep "$1"; then deep_prompt "$(st_get "$1" step)" "$(st_get "$1" branch)" "$(st_get "$1" deep_base)" "$(deep_head_of "$1")" "$(st_get "$1" round)"
  elif is_pkg "$1"; then package_prompt "$1"
  else issue_prompt "$1"; fi
}

# start_issue <n> [extra]: claim and start a new worker; extra is appended to its prompt
start_issue() {
  local n=$1 title prompt c=0 p="" pl=() br
  title=$(title_of "$n")
  [ -n "$title" ] || title=$(safe_title "$(ghj issue view "$n" -R "$REPO" --json title | jqr .title)")
  # plan-ok on an issue nobody manages: its plan PR merged (plan_back); the build executes it
  has_label "$n" plan-ok && { p=1 pl=(--remove-label plan-ok); }
  # kept in the state: is_contract_pr knows the issue's contract PR by it
  br=$(issue_branch "$n" "$title")
  prompt=$(issue_prompt "$n" "$title" "${p:-0}" "$br")
  [ -n "${2:-}" ] && prompt+=" The user adds: $2"
  is_exclusive "$n" && c=1
  run_worker "$n" "$prompt" "$BUDGET_WORK" || return   # SLOT_REFUSED: no shared slot, the issue waits
  edit_issue "$n" --add-label in-progress --remove-label ready --add-assignee "$USER_LOGIN" "${pl[@]}"
  st_set "$n" exclusive=$c plan_ok=$p branch="$br" used= cont=; new_cycle "$n"
  log "#$n started: $title"
}

# plan_merged_text <plan file>: what a worker starting on a merged, approved plan is told
plan_merged_text() { echo "The plan $1 is approved and merged on $BASE_BRANCH: execute it; the PR closes the issue.$(worker_skills)"; }

# accept_lines <n>: the Accept: and Reject: lines of the accept's form (ask_block). Only the
# channels that count are offered; canccu-ship arms auto-merge: not in a repo without it.
accept_lines() {
  local how; how=$(accept_ways "$(lead_of "$1")" "add the label \`accepted\` to this PR")
  printf '%s\n' "Accept: $how." "Reject: comment here and label issue #$(lead_of "$1") \`needs-work\`."
}

# to_accept <n> <pr> <reason> <head>: wait for the user's accept of this head, asked in the form at
# the top of the PR body (ask_block). An `accepted` label from before (an older head, or not the
# user's) is removed first: it never counts for this one.
to_accept() {
  local n=$1 pr=$2 reason=$3 head=$4
  drop_accepted "$n" "$pr"
  # armed by someone else (a worker acting as the user): a manual PR never merges on its own
  [ "$(pr_get "$pr" '.autoMergeRequest != null')" = true ] && mut gh pr merge "$pr" -R "$REPO" --disable-auto
  edit_issue "$n" --add-label awaiting-accept
  st_set "$n" phase=accept accept_sha="$head" accept_at="$(now)" reason="$(oneline 200 "$reason")" accept_reason="$(oneline 200 "$reason")"
  auto_merge_read
  ask_block "$n" "$pr" "$(accept_lines "$n")"
  log "#$n PR #$pr: awaiting accept ($reason)$(its_url "$(pr_url "$pr")")"
}

# new_cycle <n>: a new start, an adoption, plan-ok or needs-work: the next review is a full one
new_cycle() { st_set "$1" accept_sha= carry_sha= carry_by= carried= carried_by= stage= reviewed_sha= review_maccept= review_risk= open_sha= full_sha= pass_sha= passed_rev= extra_fix=; }

# after_pass <n> <pr> <head> <how>: that head passed (a review, a fix-check, or a merge of main only
# after a pass): classify, then merge it, carry an accept held for it over (carry_accept), or wait
# for the accept. 1 when nothing was done (classify
# could not read the PR, or the merge failed): the caller sees the pass again next pass.
after_pass() {
  local n=$1 pr=$2 head=$3 c
  c=$(classify "$pr" "$n")
  [[ $c == retry:* ]] && { log "#$n PR #$pr: $4 pass · $c; again next pass"; return 1; }
  log "#$n PR #$pr: $4 pass · $c"
  # the open items are fixed: cleared before the merge step, so a failed merge or accept
  # leaves none behind for a later needs-work, which then starts a new cycle
  st_set "$n" open_sha=
  if [ "$c" = auto ]; then merge_auto "$n" "$pr" auto "$head" || return 1; return 0; fi
  carry_accept "$n" "$pr" "$head" "$4"
  case $? in 0) ;; 2) return 1 ;; *) to_accept "$n" "$pr" "$c" "$head" ;; esac
}

# save_findings <n> <pr> <file> <text>: the items a fix-check checks (findings_file), or the open
# items a fix-check left (open_file), always written whole: a second needs-work never appends
save_findings() {
  (( CANCCU_DRY )) && return 0
  mkdir -p "${3%/*}" && printf '%s\n' "$4" > "$3" || log "#$1 PR #$2: cannot save ${3##*/}"
}

# fixcheck_short <n> <pr> <head> <fix-check body> <at>: a fix-check's pass that leaves a numbered
# finding of the review it checks without an outcome, or calls one not fixed or broken, is no pass
# (#229): needs-you with its text as the open items, as a changes would. 1: every finding fixed.
fixcheck_short() {
  local n=$1 pr=$2 head=$3 rsha g miss open r=""
  rsha=$(st_get "$n" reviewed_sha)
  g=$(fixcheck_gaps "$(cat "$(findings_file "$pr" "$rsha")" 2>/dev/null)" "$4"); [ -n "$g" ] || return 1
  miss=${g% | *} open=${g#* | }
  [ -n "$miss" ] && r="names no outcome for $(findings_word "$miss") of the review of ${rsha:0:7}"
  [ -n "$open" ] && r+="${r:+, and }says $(findings_word "$open") of the review of ${rsha:0:7} $( [[ $open == *' '* ]] && echo are || echo is) not fixed or broken"
  save_findings "$n" "$pr" "$(open_file "$pr" "$head")" "$4"
  needs_you "$n" "the fix-check of PR #$pr passed but $r: that is no pass. Check those findings on the PR. \`needs-work\` gives one more fix round and a fix-check of the review's findings; with \`needs-work\`, a line \`full review\` in your comment asks for a new full review instead" "$4"
  st_set "$n" verdict_at="$5" open_sha="$head"
  log "#$n PR #$pr: the fix-check of ${head:0:7} $r; needs-you"
}
# findings_word <numbers>: "finding 2", "findings 2, 3"
findings_word() { if [[ $1 == *' '* ]]; then echo "findings ${1// /, }"; else echo "finding $1"; fi; }

# act_verdict <n> <pr> <pr_detail json>. The flow is one full review, one fix by the worker, one
# fix-check, then merge or the product owner: no further loop. A `changes` from the full review
# resumes the worker once with the findings (stage fixing; the next review is the fix-check of
# reviewed_sha..head). A `changes` once the findings were given (from the fix-check, or a full
# review started by hand meanwhile) → needs-you with the open items, kept (open_sha and its open
# file) for the lead's needs-work: one more fix round and a fix-check of those (resume_step). That
# stop, and a full review's with no fix run left, first try extra_fix_round (FIX_EXTRA_IF_FEWER). The
# verdict counts as acted on (verdict_at) only once the merge, the accept request or the resume has
# happened: a failed step sees it again next pass.
act_verdict() {
  local n=$1 pr=$2 j=$3 v head at stage what body="" b ff ma mo mode rc REVIEW_SETTLED REVIEW_PASSRULE REVIEW_CHANGED
  v=$(verdict_of "$j" "$(st_get "$n" verdict_at)"); head=$(jqr .headRefOid <<<"$j"); at=$(verdict_at "$j")
  stage=$(st_get "$n" stage) mode=$(st_get "$n" review_mode)
  # before pass_sha moves: the posted verdict was decided in the same context (reap_review)
  review_ctx "$n" "$pr" "$head"
  what=review; is_fixcheck_mode "$mode" && what=fix-check
  # a push after a pass is checked against these (postpass_step); a full review's verdict is the
  # one a `full review` ask or a light upgrade waited for (light_upgrade may ask again below)
  case $v in pass|changes) is_fixcheck_mode "$mode" || st_set "$n" full_sha="$head" review_asked= ;; esac
  # non-blocking findings never reach the worker: they go to the wave's follow-up issue
  # the head of the last verdict that passed: its review file holds the Change: lines the ask form
  # shows after a merge of main (full_sha may be an older review that asked for changes)
  [ "$v" = pass ] && st_set "$n" passed_rev="$head"
  case $v in pass|changes) body=$(verdict_body "$j"); collect_nonblocking "$n" "$pr" "$head" "$body" "$at"
      history_record "$n" "$pr" "$head" "$body" "$at"; blocking_note "$n" "$body" "$at" "$head" ;; esac
  case $v in
    pass)
      [ "$mode" = fixcheck ] && fixcheck_short "$n" "$pr" "$head" "$body" "$at" && return 0
      light_upgrade "$n" "$pr" "$head" "$j" "$at" && return 0
      # any pass leaves the fix round: the next push is again measured against full_sha
      # (postpass_step), not taken for a fix of findings
      st_set "$n" pass_sha="$head" stage=review
      after_pass "$n" "$pr" "$head" "$what" || return 0
      st_set "$n" verdict_at="$at" ;;
    changes)
      # an accept held for this head's check (carry_accept) is void: the fix round's commits are
      # the PR's own, and their pass asks again
      st_set "$n" carry_sha= carry_by=
      # a light review rated high gets the full review first: its verdict drives the fix round
      light_upgrade "$n" "$pr" "$head" "$j" "$at" && return 0
      case $stage in
        fixing|fixcheck)
          save_findings "$n" "$pr" "$(open_file "$pr" "$head")" "$body"
          extra_fix_round "$n" "$pr" "$head" "$body" "$what"; rc=$?
          (( rc == 2 )) && return 0
          # its own Maintainer accept and Risk lines are kept like the full review's: the fix-check
          # after a needs-work may not copy them, and its pass must still wait for the product owner
          ma=$(oneline 200 "$(maintainer_accept_of "$j")") mo=$(st_get "$n" review_maccept)
          if [ -n "$ma" ] && [ "$ma" != "$mo" ]; then
            st_set "$n" review_maccept="$(oneline 200 "${mo:+$mo; }$ma")"
          fi
          st_set "$n" review_risk="$(risk_max "$(review_risk_of "$j")" "$(st_get "$n" review_risk)")"
          (( rc == 0 )) && { st_set "$n" verdict_at="$at"; return 0; }
          needs_you "$n" "the $what of PR #$pr still finds open items after the fix (one review, one fix, one fix-check: no further loop). \`needs-work\` gives one more fix round and a fix-check of these items; with \`needs-work\`, a line \`full review\` in your comment asks for a new full review instead" "$body"
          st_set "$n" verdict_at="$at" open_sha="$head" ;;
        *)
          if ! fix_left "$n" "$pr"; then
            extra_fix_round "$n" "$pr" "$head" "$body" "$what"; rc=$?
            (( rc == 2 )) && return 0
            if (( rc == 0 )); then
              st_set "$n" verdict_at="$at" review_maccept="$(oneline 200 "$(maintainer_accept_of "$j")")" review_risk="$(review_risk_of "$j")"
              return 0
            fi
            needs_you "$n" "the review of PR #$pr asks for changes and no automatic fix run is left ($(fix_max) per PR, FIX_ATTEMPTS): comment the way on and the worker follows up" "$body"
            st_set "$n" verdict_at="$at"; return 0
          fi
          # nothing of the round is saved or counted before its run can start: the next pass
          # does the whole case again
          may_start "$n" || return 0
          # only the blocking findings: the fix run fixes them and the fix-check checks them
          # saved before the run, which reads the whole of long ones there (findings_inline)
          b=$(blocking_numbered "$body") ff=$(findings_file "$pr" "$head")
          save_findings "$n" "$pr" "$ff" "$b"
          resume "$n" "The independent reviewer asked for changes on PR #$pr (full comment: gh pr view $pr -R $REPO --comments). This is your one fix round: fix every blocking finding below, rerun the checks, push once and stop: the dispatcher watches CI. Leave its non-blocking findings alone: they went to a follow-up issue. A narrow fix-check of your fix diff follows, then the merge or the product owner. The blocking findings: $(findings_inline "$b" "$ff")" fix || return 0
          fix_count "$n" "$pr"
          st_set "$n" stage=fixing reviewed_sha="$head" verdict_at="$at" review_maccept="$(oneline 200 "$(maintainer_accept_of "$j")")" \
            review_risk="$(review_risk_of "$j")"
          log "#$n PR #$pr: review changes; the worker fixes the findings of ${head:0:7}" ;;
      esac ;;
    *) needs_you "$n" "the $([ "$what" = fix-check ] && echo fix-check || echo reviewer) of PR #$pr left no review ending in \`Review verdict: pass|changes <head sha>\` (none posted as $REVIEWER_LOGIN)" "$(run_msg "review-$pr")" ;;
  esac
}

# ensure_labels: the labels the dispatcher uses, created in REPO where missing
CANCCU_LABELS="ready blocked in-progress epic needs-you plan-ok awaiting-accept needs-work accepted manual-accept checkpoint checkpoint-ok fast security follow-up dispatcher-claim"
ensure_labels() {
  local have l
  have=$(ghj label list -R "$REPO" -L 300 --json name | jqr '.[].name') || return 0
  for l in $CANCCU_LABELS; do
    if ! grep -qx "$l" <<<"$have"; then mut gh label create "$l" -R "$REPO" >/dev/null && log "label $l created"; fi
  done
}
