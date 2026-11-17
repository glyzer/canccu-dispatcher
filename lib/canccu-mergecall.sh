# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the merge calls: the method, auto-merge
# or a direct merge of the accepted head, their retries, a merge needs-you lifted, and the accept
# label dropped. docs/reference/merging.md.

# merge_flags <direct 0|1>: MF is the method a merge passes (merge_method_read): none for the
# merge queue; unknown → none for auto-merge, --squash for a direct merge (as before). Not run in
# $(…), so MERGE_METHOD stays read for the rest of the pass.
merge_flags() {
  merge_method_read
  MF=()
  case $MERGE_METHOD in --*) MF=("$MERGE_METHOD") ;; unknown) (( $1 )) && MF=(--squash) ;; esac
  return 0
}

# merge_auto <n> <pr> <how> <head>: merge exactly that head. Where the repo allows auto-merge (or
# the setting is unknown): arm it; a push in between fails it. Where it does not (the setting, or
# --auto's "not allowed" error), or where GitHub refuses --auto for a PR in clean status:
# merge_direct, now or on a later pass (merge_mode=direct).
merge_auto() {
  local n=$1 pr=$2 how=$3 head=$4
  is_full_sha "$head" || { needs_you "$n" "the head of PR #$pr ($head) is not a full commit sha; not merged"; return 1; }
  auto_merge_read
  if [ "$AUTO_MERGE_ALLOWED" != false ]; then
    merge_flags 0
    if mut_out gh pr merge "$pr" -R "$REPO" --auto "${MF[@]}" --match-head-commit "$head"; then
      st_set "$n" phase=merging how="$how" merge_sha="$head" merge_at="$(now)" merge_mode= merge_tries=
      log "#$n PR #$pr: auto-merge enabled ($how)"; return 0
    fi
    # GitHub refuses to arm a PR it can merge right now: merging that same head directly is what
    # auto-merge would have done a moment later. AUTO_MERGE_ALLOWED stays: the next PR arms again.
    if grep -qi 'clean status' <<<"$MUT_OUT"; then
      log "#$n PR #$pr: GitHub can merge it now (clean status); merging directly at ${head:0:7}"
      st_set "$n" phase=merging how="$how" merge_sha="$head" merge_at="$(now)" merge_mode=direct
      merge_direct "$n" "$pr"; return
    fi
    # a call that failed may still have armed it (a 502 after GitHub took the write, or an earlier
    # try's): armed on this head is the outcome asked for, and spends no try
    if grep -qi 'already enabled' <<<"$MUT_OUT" || armed_on "$pr" "$head"; then
      st_set "$n" phase=merging how="$how" merge_sha="$head" merge_at="$(now)" merge_mode= merge_tries=
      log "#$n PR #$pr: auto-merge is armed already ($how)"; return 0
    fi
    if ! grep -qiE 'auto.?merge is not allowed' <<<"$MUT_OUT"; then
      merge_retry "$n" "$pr" && return 1
      needs_you "$n" "\`gh pr merge $pr --auto${MF[*]:+ ${MF[*]}} --match-head-commit ${head:0:7}\` failed; merge it by hand or check the merge queue. gh: $(oneline 300 "$MUT_OUT")$MERGE_AFTER"; return 1
    fi
    AUTO_MERGE_ALLOWED=false
  fi
  st_set "$n" phase=merging how="$how" merge_sha="$head" merge_at="$(now)" merge_mode=direct
  merge_direct "$n" "$pr"
}

# armed_on <pr> <head>: a fresh read shows auto-merge armed on the PR at that head
armed_on() {
  local j; j=$(ghj pr view "$1" -R "$REPO" --json autoMergeRequest,headRefOid 2>/dev/null) || return 1
  [ "$(jq -r 'if .autoMergeRequest != null then .headRefOid else "" end' <<<"$j" 2>/dev/null)" = "$2" ]
}

# merge_retry <n> <pr>: the merge call failed (its output in MUT_OUT). 0 when the error looks
# transient (gh_transient, or the call killed by its timeout) and merge_tries is below MERGE_RETRY: the try is counted and logged and
# the phase kept, so the next pass's step (accept_step, merging_step, or check_pr acting on the same
# verdict again) runs the same merge. 1: raise the needs-you, with MERGE_AFTER appended to it.
merge_retry() {
  local n=$1 pr=$2 k max=${MERGE_RETRY:-3}
  MERGE_AFTER=""
  [[ ${MUT_RC:-} =~ ^(124|137)$ ]] || gh_transient "$MUT_OUT" || return 1
  k=$(st_get "$n" merge_tries); k=${k:-0}
  (( k >= max )) && { MERGE_AFTER=" (after $max tries)"; return 1; }
  st_set "$n" merge_tries=$(( k + 1 ))
  log "#$n PR #$pr: GitHub error on the merge (try $(( k + 1 )) of $max); trying again next pass: $(oneline 200 "$MUT_OUT")"
}

# merge_unpark <n>: a needs-you at the merge step (ny_stage merge) whose label the user removed
# with no comment since it parked means "try again": back to accept, where accept_step checks the
# user's accept and the head again before it merges, so no new accept is asked. A push since the
# accept → requeue, as accept_step would. A comment leaves it to resume_step; a gh error reading
# the comments, to the next pass. A unit without an accept (accept_sha empty: auto-merged) is left
# as it is: in accept it would wait for a label nobody adds. 0 when it left needs-you.
merge_unpark() {
  local n=$1 pr c
  [ "$(st_get "$n" ny_stage)" = merge ] && [ -n "$(st_get "$n" accept_sha)" ] && ! has_label "$n" needs-you || return 1
  pr=$(st_get "$n" pr); [ -n "$pr" ] && pr_is_open "$pr" || return 1
  c=$(user_comments "$n" "$pr" "$(st_get "$n" ny_at)") || return 1
  [ -z "$c" ] || return 1
  if [ "$(pr_get "$pr" .headRefOid)" != "$(st_get "$n" accept_sha)" ]; then
    requeue "$n" "$pr" "new push since the merge needs-you"; return 0
  fi
  # the accept's own reason picks its owner again; its ask was answered already, so none is posted
  local kv=(phase=accept merge_tries=) r; r=$(st_get "$n" accept_reason)
  [ -z "$r" ] || kv+=(reason="$r")
  FEED_QUIET=1 st_set "$n" "${kv[@]}"
  log "#$n PR #$pr: needs-you lifted at the merge; trying the merge again"
}

# armed <n> <pr>: auto-merge may be armed on the PR: the state says auto-merge (merge_mode empty),
# or GitHub does, whatever merge_mode says (a stale one never keeps an unreviewed head armed)
armed() { [ -z "$(st_get "$1" merge_mode)" ] || [ "$(pr_get "$2" '.autoMergeRequest != null')" = true ]; }
# direct_ci <pr>: what a direct merge sees on the PR's head: ci_state, but pending while a
# REVIEW_CHECKS check still runs there (a required review-gate would refuse the merge)
direct_ci() { local c; c=$(ci_state "$1"); [ "$c" = green ] && review_checks_running "$1" && c=pending; echo "$c"; }

# merge_direct <n> <pr>: without auto-merge, merge merge_sha (merge_flags) --match-head-commit, but
# only while it is the PR's head (a push: merging_step reviews again) and CI is green on it
# (direct_ci; pending or none: wait; red: needs-you). merge_mode=merged after (merge_at: then):
# the PR is still in this pass's list, and finish_unit logs the merge once the issue closes. 1
# after a needs-you or a retry (merge_retry).
merge_direct() {
  local n=$1 pr=$2 sha; sha=$(st_get "$n" merge_sha)
  is_full_sha "$sha" || { needs_you "$n" "the head of PR #$pr ($sha) is not a full commit sha; not merged"; return 1; }
  [ "$(pr_get "$pr" .headRefOid)" = "$sha" ] || return 0
  case $(direct_ci "$pr") in
    green) ;;
    red) needs_you "$n" "CI is red on PR #$pr at ${sha:0:7}; not merged"; return 1 ;;
    *) return 0 ;;
  esac
  merge_flags 1
  if ! mut_out gh pr merge "$pr" -R "$REPO" "${MF[@]}" --match-head-commit "$sha"; then
    merge_retry "$n" "$pr" && return 1
    needs_you "$n" "\`gh pr merge $pr${MF[*]:+ ${MF[*]}} --match-head-commit ${sha:0:7}\` failed; merge it by hand. gh: $(oneline 300 "$MUT_OUT")$MERGE_AFTER"; return 1
  fi
  st_set "$n" merge_mode=merged merge_at="$(now)" merge_tries=
  log "#$n PR #$pr: merged directly ($(st_get "$n" how))"
}

# drop_accepted <n> <pr>: take `accepted` off the PR and off every issue of the unit (accept_step
# reads both places), so an old label never accepts a later head
drop_accepted() {
  local m
  pr_has_label "$2" accepted && mut gh pr edit "$2" -R "$REPO" --remove-label accepted
  for m in $(members_of "$1"); do has_label "$m" accepted && mut gh issue edit "$m" -R "$REPO" --remove-label accepted; done
  return 0
}
