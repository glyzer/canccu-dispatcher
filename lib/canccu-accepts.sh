# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): which accepts count (ACCEPT_CHANNELS),
# canccu-ship's accept record (accepts.log), the label's accept (accepted_by_user, keep_accept),
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

# ship_actor: who runs canccu-ship: leader (CANCCU_ACTOR=leader) or po. A run's marker counts as
# po here: a run holding the project login is what the hardened level shuts out, not this check.
ship_actor() { [ "${CANCCU_ACTOR-}" = leader ] && echo leader || echo po; }
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

# keep_accept <n> <pr> <old> <head>: with KEEP_ACCEPT_ON_MAIN_MERGE=1, an accept of old carries over
# to head when head adds nothing to old but merges of main (main_merge_only) and the PR's own
# `accepted` is still the user's, since the accept request: auto-merge on head. Only the PR's label
# counts: an accept taken off an issue of the unit has left no label to check again. Off by
# default: until package S2 a run can forge such a merge as easily as the label. 1: today's path.
keep_accept() {
  local n=$1 pr=$2 old=$3 head=$4
  [ "${KEEP_ACCEPT_ON_MAIN_MERGE:-0}" = 1 ] && [ -n "$old" ] && accept_channel label || return 1
  pr_has_label "$pr" accepted && accepted_by_user "$pr" "$(st_get "$n" accept_at)" || return 1
  pr_fetch "$pr"
  main_merge_only "$old" "$head" || return 1
  st_set "$n" accept_sha="$head"
  log "#$n PR #$pr: \`accepted\` carried over from ${old:0:7} to ${head:0:7}: a merge of main only (KEEP_ACCEPT_ON_MAIN_MERGE=1)"
  merge_auto "$n" "$pr" accepted "$head"
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
