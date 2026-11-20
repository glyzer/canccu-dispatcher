# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): which accepts count (ACCEPT_CHANNELS),
# canccu-ship's accept record (accepts.log), the label's accept (accepted_by_user), an accept
# carried over merges of main (keep_accept, carry_accept),
# and the product owner's comments, without those posted while a run of the unit was alive.
# docs/reference/merging.md, "The accept channels".

# accept_channel <label|ship|reply|leader>: ACCEPT_CHANNELS lists it, or lists all. Commas
# separate too, as config set accepts them. An empty value lists none.
accept_channel() {
  local w ws
  IFS=$', ' read -ra ws <<<"${ACCEPT_CHANNELS-all}"
  for w in "${ws[@]}"; do [ "$w" = all ] || [ "$w" = "$1" ] && return 0; done
  return 1
}

# accept_label_held <K> <pr>: the PR or an issue of the unit carries `accepted`
accept_label_held() {
  local m; pr_has_label "$2" accepted && return 0
  for m in $(members_of "$1"); do has_label "$m" accepted && return 0; done
  return 1
}
# accept_ways <lead>: how to accept, by the channels that count (the ask form's first line).
# canccu-ship arms auto-merge: not offered in a repo without it.
accept_ways() {
  local w=""
  accept_channel label && w="label it \`accepted\`"
  auto_merge_read
  accept_channel ship && [ "$AUTO_MERGE_ALLOWED" != false ] && w="${w:+$w, or }\`canccu-ship $1\`"
  echo "${w:-as ACCEPT_CHANNELS ($ACCEPT_CHANNELS) allows}"
}

# ship_actor: who runs canccu-ship: leader, run or po, by the CANCCU_ACTOR marker (cfg_actor).
# canccu-ship refuses a run; a run that unsets the marker is what the hardened level shuts out.
ship_actor() { cfg_actor; }
# actor_channel <po|leader>: the channel that actor's canccu-ship accepts through
actor_channel() { [ "$1" = leader ] && echo leader || echo ship; }

# accept_record <K> <pr> <head> <actor>: canccu-ship's accept of that head, kept on the host: no
# GitHub label or comment can write it. 1 when the line could not be written.
accept_record() {
  (( CANCCU_DRY )) && return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" "$4" >> "$CANCCU_HOME/accepts.log"
}

# ship_recorded <pr> <head>: accepts.log holds a record of that PR and head whose actor's channel
# ACCEPT_CHANNELS lists
ship_recorded() {
  local a
  for a in $(awk -F '\t' -v p="$1" -v h="$2" '$3 == p && $4 == h { print $5 }' "$CANCCU_HOME/accepts.log" 2>/dev/null | sort -u); do
    accept_channel "$(actor_channel "$a")" && return 0
  done
  return 1
}

# ship_armed <K> <pr> <head>: auto-merge is armed and canccu-ship recorded its accept of this head
# (it armed the PR before the dispatcher managed it, or a pass raced it): that is the accept.
# merge_auto again sets the state as canccu-ship's own call would. 1: not such a PR.
ship_armed() {
  [ "$(pr_get "$2" '.autoMergeRequest != null')" = true ] && ship_recorded "$2" "$3" || return 1
  log "#$1 PR #$2: auto-merge armed on ${3:0:7} with canccu-ship's accept record; taken as the accept"
  merge_auto "$1" "$2" accepted "$3"
  return 0
}

# accepted_by_user <pr|issue> <since epoch>: its newest `accepted` label event is by USER_LOGIN
# (never the reviewer bot) and came after the accept request
accepted_by_user() { label_by_user "$1" accepted "${2:-0}"; }

# accept_held <n> <pr> <old>: the channel through which old's accept still counts: label (the
# PR's own `accepted`, the user's since the accept request: one taken off an issue of the unit has
# left no label to check again), ship or leader (canccu-ship's record of old), or the channel an
# earlier carry-over brought it to old by (carried, carried_by: the label went with that requeue).
# Each only while ACCEPT_CHANNELS lists it. 1: none.
accept_held() {
  local n=$1 pr=$2 old=$3 a by
  if accept_channel label && pr_has_label "$pr" accepted && accepted_by_user "$pr" "$(st_get "$n" accept_at)"; then echo label; return 0; fi
  for a in $(awk -F '\t' -v p="$pr" -v h="$old" '$3 == p && $4 == h { print $5 }' "$CANCCU_HOME/accepts.log" 2>/dev/null | sort -u); do
    by=$(actor_channel "$a"); accept_channel "$by" && { echo "$by"; return 0; }
  done
  by=$(st_get "$n" carried_by)
  [ -n "$old" ] && [ "$(st_get "$n" carried)" = "$old" ] && [ -n "$by" ] && accept_channel "$by" && { echo "$by"; return 0; }
  return 1
}

# keep_accept <n> <pr> <old> <head>: with KEEP_ACCEPT_ON_MAIN_MERGE=1, an accept of old that still
# counts (accept_held) carries over to head when head adds nothing to old but clean merges of main
# (main_merge_only): auto-merge on head. Merges of main with conflicts resolved only inside the
# PR's own files (resolved_outside) hold the accept for head's fix-check instead (carry_sha,
# carry_by; carry_accept spends it on the pass), and the caller's requeue reviews head. 1: not
# carried now, the caller's path. canccu-ship's own hold on head (carry_sha = head) is kept.
keep_accept() {
  local n=$1 pr=$2 old=$3 head=$4 by out
  [ "$(st_get "$n" carry_sha)" = "$head" ] || st_set "$n" carry_sha= carry_by=
  [ "${KEEP_ACCEPT_ON_MAIN_MERGE:-1}" = 1 ] && [ -n "$old" ] || return 1
  by=$(accept_held "$n" "$pr" "$old") || return 1
  pr_fetch "$pr"
  if main_merge_only "$old" "$head"; then
    st_set "$n" accept_sha="$head" carried="$head" carried_by="$by"
    log "#$n PR #$pr: \`accepted\` carried over from ${old:0:7} to ${head:0:7}: a merge of main only (KEEP_ACCEPT_ON_MAIN_MERGE=1)"
    merge_auto "$n" "$pr" accepted "$head"
    return 0
  fi
  out=$(resolved_outside "$old" "$head") || return 1
  if [ -n "$out" ]; then
    log "#$n PR #$pr: ${head:0:7} resolves a conflict outside the PR's own files ($(paste -sd, - <<<"$out" | sed 's/,/, /g')); a new accept is asked"
    return 1
  fi
  st_set "$n" carry_sha="$old" carry_by="$by"
  log "#$n PR #$pr: ${head:0:7} merges main with conflicts resolved in the PR's own files; the accept of ${old:0:7} holds until its fix-check"
  return 1
}

# carry_accept <n> <pr> <head> <what passed>: after_pass on a manual class. An accept held by
# keep_accept (carry_sha) carries over to head once head passed, when head still adds to carry_sha
# nothing but merges of main resolved inside the PR's own files (a commit of the PR's own since
# needs a new accept); canccu-ship's hold on head itself is that head's accept. 0: merged (or
# tried: 2 when merge_auto failed, the caller retries); 1: no such accept, the accept is asked.
carry_accept() {
  local n=$1 pr=$2 head=$3 old by out
  old=$(st_get "$n" carry_sha) by=$(st_get "$n" carry_by)
  [ -n "$old" ] && [ -n "$by" ] && accept_channel "$by" || return 1
  if [ "$old" != "$head" ]; then
    [ "${KEEP_ACCEPT_ON_MAIN_MERGE:-1}" = 1 ] || return 1
    pr_fetch "$pr"
    out=$(resolved_outside "$old" "$head") && [ -z "$out" ] || { st_set "$n" carry_sha= carry_by=; return 1; }
  fi
  merge_auto "$n" "$pr" accepted "$head" || return 2
  st_set "$n" carry_sha= carry_by= carried="$head" carried_by="$by" accept_sha="$head"
  if [ "$old" = "$head" ]; then log "#$n PR #$pr: canccu-ship's accept of ${head:0:7} holds: its $4 passed"
  else log "#$n PR #$pr: \`accepted\` carried over from ${old:0:7} to ${head:0:7}: a merge of main only (KEEP_ACCEPT_ON_MAIN_MERGE=1) (conflicts resolved, $4 pass)"; fi
  return 0
}

# unit_runs <K>: "<start> <end>" epochs of the unit's runs: each finished one from the spend log
# (its end, minus its secs; a line without secs cannot be placed and is left out), and the live
# one from its `started` on, with no end yet
unit_runs() {
  local s
  awk -F '\t' -v r="$REPO_NAME" -v k="$1" '$2 == r && $3 == k && $1 ~ /^[0-9]+$/ && $16 ~ /^[0-9]+$/ { print $1 - $16, $1 }' \
    "$WORKERS_DIR/spend.log" 2>/dev/null
  if run_alive "$1"; then s=$(st_get "$1" started); [[ $s =~ ^[0-9]+$ ]] && echo "$s 99999999999"; fi
  return 0
}

# user_comments <n> <pr> <since epoch>: the user's comments on the issue and PR since then,
# without the dispatcher's own (its marker), review verdicts, or the answerer's (it posts as the
# user too). A verdict is what verdict_of reads: its last non-empty line matches VERDICT_RE; a
# lead's quote-reply holds a verdict line too but ends in the lead's own words, and counts. A
# comment posted while a run of the unit was alive is dropped (said once): the run holds the same
# login and could have written it. A time jq cannot read is kept, as before this check.
user_comments() {
  local n=$1 pr=$2 since runs j t; since=$(iso "${3:-0}")
  runs=$(unit_runs "$n" | jq -Rsc '[split("\n")[] | select(. != "") | split(" ") | map(tonumber)]') || return 1
  # a gh error on either read fails the call (pipefail), never a silently shorter list
  j=$({ ghj issue view "$(lead_of "$n")" -R "$REPO" --json comments || exit 1
        if [ -n "$pr" ]; then ghj pr view "$pr" -R "$REPO" --json comments || exit 1; fi; } |
    jqr -s -c --arg u "$USER_LOGIN" --arg s "$since" --arg m "$CANCCU_MARK" --arg vre "$VERDICT_RE" --argjson runs "$runs" '
      [ .[].comments[] | select(.author.login == $u and .createdAt > $s
                                and (.body | contains($m) | not)
                                and (.body | gsub("\r"; "") | split("\n") | map(select(test("\\S")))
                                     | last // "" | test($vre; "i") | not)
                                and (.body | test("^[\\s*_]*(Answer|Needs the product owner):") | not)) ]
      | sort_by(.createdAt)
      | map(. + {live: ((try (.createdAt | fromdateiso8601) catch null) as $t
                        | $t != null and any($runs[]; $t >= .[0] and $t <= .[1]))})') || return 1
  # warn_once writes dispatch.log itself; its stdout would join the comments, and stderr is copied
  # into dispatch.log a second time
  while read -r t; do
    [ -n "$t" ] && warn_once "live-comment-$n-$t" "#$n: a comment by $USER_LOGIN at $t was posted while a run was alive; not taken as the product owner's answer" >/dev/null
  done < <(jqr '.[] | select(.live) | .createdAt' <<<"$j")
  jqr 'map(select(.live | not) | .body) | join("\n\n---\n\n")' <<<"$j"
}

# ship_reviewed <K> <pr> <head>: head is one the dispatcher let through: the head the accept was
# asked on, the one armed, the last pass, or merges of main only since that pass
ship_reviewed() {
  local h p
  for h in accept_sha merge_sha pass_sha; do [ "$(st_get "$1" "$h")" = "$3" ] && return 0; done
  p=$(st_get "$1" pass_sha); [ -n "$p" ] || return 1
  pr_fetch "$2"
  main_merge_only "$p" "$3"
}
