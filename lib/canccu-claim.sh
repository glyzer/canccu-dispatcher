# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run; canccu-init sources it alone for
# claim_warning): the dispatcher claim, one dispatcher per repo across hosts (docs/hosts.md,
# "The dispatcher claim").
#
# The claim is the body of the repo's lowest-numbered open issue labelled dispatcher-claim: a
# marker, then "host: <id>", "label: <HOST_LABEL>" and "at: <UTC time>" lines. Only the body is
# ever edited (an edit notifies no watcher; a comment would), so it needs Issues write and
# nothing more. A released claim has an empty host. $CANCCU_HOME/claim caches what the last pass
# saw (issue, state ours|foreign|lost, holder, holder_label, at) and, in `wrote`, the time of the
# last claim of this host's that GitHub showed: on a gh error the pass acts until wrote plus
# CLAIM_EXPIRY_MIN, the moment another host may take the repo.

CLAIM_LABEL=dispatcher-claim CLAIM_TITLE="Dispatcher claim" CLAIM_MARK='<!-- canccu-claim -->'
CLAIM_ISSUE="" CLAIM_HOST="" CLAIM_HLABEL="" CLAIM_AT=""

# canccu-init calls claim_warning before canccu-common.sh is loaded: jq unguarded, and the clock
# (CANCCU_NOW too, as now() reads it) and iso_epoch of its own
_claim_jq() { if declare -F guard >/dev/null; then guard 20 jq "$@"; else jq "$@"; fi; }
declare -F now >/dev/null || now() { echo "${CANCCU_NOW:-$(date +%s)}"; }
declare -F iso_epoch >/dev/null || iso_epoch() { [ -n "$1" ] && date -u -d "$1" +%s 2>/dev/null; return 0; }

# host_id: this host's id, 16 random hex characters in $CANCCU_ROOT/host-id, written once
# (noclobber: two commands starting at once keep one). Never a hostname or a user name: the
# claim is public. A dry run writes nothing, so it may print an empty id.
host_id() {
  local f=$CANCCU_ROOT/host-id id
  { read -r id < "$f"; } 2>/dev/null
  if [ -z "${id:-}" ] && [ ! -e "$f" ]; then
    (( ${CANCCU_DRY:-0} )) && return 0
    id=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    mkdir -p "$CANCCU_ROOT" && ( set -o noclobber; printf '%s\n' "$id" > "$f" ) 2>/dev/null
    { read -r id < "$f"; } 2>/dev/null
  fi
  [[ ${id:-} =~ ^[0-9a-f]{16}$ ]] && printf '%s\n' "$id"
}

# claim_parse <json array of {number, body}>: CLAIM_ISSUE (empty: no claim issue), CLAIM_HOST,
# CLAIM_HLABEL and CLAIM_AT (epoch; empty when the body has no readable time)
claim_parse() {
  local at out
  CLAIM_ISSUE="" CLAIM_HOST="" CLAIM_HLABEL="" CLAIM_AT=""
  # an answer jq cannot read is an error, never "no claim issue": that would create a second one
  out=$(_claim_jq -r '
    sort_by(.number) | .[0] // empty | (.body // "" | split("\n")) as $l
    | def f($k): [$l[] | select(startswith($k + ":")) | .[($k | length) + 1:] | gsub("^\\s+|\\s+$"; "")] | first // "";
      [(.number | tostring), f("host"), f("at"), f("label")] | join("\u001f")' <<<"$1") || return 1
  [ -n "$out" ] || return 0
  IFS=$'\x1f' read -r CLAIM_ISSUE CLAIM_HOST at CLAIM_HLABEL <<<"$out"
  CLAIM_AT=$(iso_epoch "$at")
  return 0
}
# claim_read [<new issue> <host>]: the claim as GitHub has it now; 1 on a gh error. GitHub lists a
# new issue a few seconds late: the claim issue this pass created counts as listed, with its body.
claim_read() {
  local j
  j=$(ghj issue list -R "$REPO" -s open -l "$CLAIM_LABEL" -L 20 --json number,body) || return 1
  # only when the list shows no claim issue at all: with another listed, the lowest number wins
  if [ -n "${1:-}" ] && [ "$(_claim_jq 'length' <<<"$j")" = 0 ]; then
    j=$(_claim_jq -c --argjson n "$1" --arg b "host: $2"$'\n'"at: $(iso "$(now)")" \
      '. + [{number: $n, body: $b}]' <<<"$j") || return 1
  fi
  claim_parse "$j"
}
# claim_free: the claim read is released (no host) or older than CLAIM_EXPIRY_MIN
claim_free() { [ -z "$CLAIM_HOST" ] || [ -z "$CLAIM_AT" ] || (( $(now) - CLAIM_AT >= ${CLAIM_EXPIRY_MIN:-30} * 60 )); }
# claim_holder: the holder of the claim read, as the messages name it: "<label> (<id>)" or "<id>"
claim_holder() { if [ -n "$CLAIM_HLABEL" ]; then echo "$CLAIM_HLABEL ($CLAIM_HOST)"; else echo "$CLAIM_HOST"; fi; }

claim_get() { kv_get "$CANCCU_HOME/claim" @claim "$1"; }
claim_set() { kv_set "$CANCCU_HOME/claim" @claim "$@"; }

# claim_body_file <host>: a temp file with the claim's body for that host (empty: released), now.
# HOST_LABEL goes through oneline: a newline in it would add a line of its own to the body.
claim_body_file() {
  local f; f=$(mktemp) || return 1
  printf '%s\nOne canccu dispatcher at a time works on this repo, and this issue says which. Its dispatcher edits this body to keep the claim fresh; an edit notifies no one. Leave it as it is: `canccu-dispatch --take-over` moves the claim by hand (docs/hosts.md, "The dispatcher claim").\n\nhost: %s\nlabel: %s\nat: %s\n' \
    "$CLAIM_MARK" "$1" "$([ -n "$1" ] && oneline 60 "${HOST_LABEL:-}")" "$(iso "$(now)")" > "$f"
  echo "$f"
}
# claim_write <issue> <host>: the claim's body set to that host at the current time
claim_write() {
  local f rc
  f=$(claim_body_file "$2") || return 1
  mut gh issue edit "$1" -R "$REPO" --body-file "$f" >/dev/null; rc=$?
  rm -f "$f"
  return "$rc"
}
# claim_create <host>: a new claim issue, pinned (a failed pin only warns: the label finds it);
# CLAIM_NEW is its number
claim_create() {
  local f rc
  CLAIM_NEW=""
  f=$(claim_body_file "$1") || return 1
  mut_out gh issue create -R "$REPO" --title "$CLAIM_TITLE" --label "$CLAIM_LABEL" --body-file "$f"; rc=$?
  # a repo without the label (ensure_labels runs once at startup and a rate limit skips it): create
  # it, then try once more
  if (( rc != 0 )) && ! (( CANCCU_DRY )) && mut gh label create "$CLAIM_LABEL" -R "$REPO" >/dev/null 2>&1; then
    mut_out gh issue create -R "$REPO" --title "$CLAIM_TITLE" --label "$CLAIM_LABEL" --body-file "$f"; rc=$?
  fi
  rm -f "$f"
  (( rc == 0 )) || return 1
  (( CANCCU_DRY )) && return 0
  CLAIM_NEW=$(grep -oE '/issues/[0-9]+' <<<"$MUT_OUT" | tail -1); CLAIM_NEW=${CLAIM_NEW##*/}
  log "claim: created #${CLAIM_NEW:-?} ($CLAIM_TITLE) for this host"
  [ -n "$CLAIM_NEW" ] && { mut gh issue pin "$CLAIM_NEW" -R "$REPO" >/dev/null ||
    warn_once claim-pin "could not pin the claim issue #$CLAIM_NEW; pin it by hand (the label finds it anyway)"; }
  return 0
}

# claim_refuse <text>: the pass does nothing for the project: logged once (the text must not
# change with the holder's renewals), in the snapshot and canccu-status
claim_refuse() { warn_once claim "$1"; want_write; write_status "$1"; return 1; }
# claim_ours: the claim read is this host's: cached, and the warnings may come again
claim_ours() {
  claim_set issue="$CLAIM_ISSUE" state=ours holder= holder_label= at="$CLAIM_AT" wrote="$CLAIM_AT"
  (( CANCCU_DRY )) || rm -f "$CANCCU_HOME/.warned-claim" "$CANCCU_HOME/.warned-claim-gh"
  return 0
}
# claim_foreign: another host holds a fresh claim. wrote is cleared: from now on a gh error
# never counts as this host's claim.
claim_foreign() {
  claim_set issue="$CLAIM_ISSUE" state=foreign holder="$CLAIM_HOST" holder_label="$CLAIM_HLABEL" at="$CLAIM_AT" wrote=
  claim_refuse "$REPO is claimed by host $(claim_holder) (#$CLAIM_ISSUE): project $CANCCU_PROJECT does nothing on this host (canccu-dispatch --take-over takes the claim)"
}
# claim_gh_error: the claim could not be read or written. The pass acts only while this host's
# last claim is fresh; it never takes or creates one.
claim_gh_error() {
  local w; w=$(claim_get wrote)
  if [[ $w =~ ^[0-9]+$ ]] && (( $(now) < w + CLAIM_EXPIRY_MIN * 60 )); then
    warn_once claim-gh "gh error on the dispatcher claim: working on under this host's claim until $(iso $(( w + CLAIM_EXPIRY_MIN * 60 )))"
    return 0
  fi
  [ "$(claim_get state)" = foreign ] || claim_set state=lost
  claim_refuse "gh error on the dispatcher claim, and this host holds no fresh claim: project $CANCCU_PROJECT does nothing until the claim is read again"
}

# claim_tick: once a pass, before it reads anything else. 0: this host holds the repo (or holds a
# fresh claim through a gh error); 1: the pass does nothing for the project. A free claim is
# taken, a missing one created; both are read again, and of two hosts writing at once the one
# GitHub shows holds it. Our own claim is written at most every CLAIM_RENEW_MIN. There is no
# compare-and-set: two hosts taking a free claim in the same moment can both read their own id
# back and act for one pass (the next pass refuses the loser), and claim_release can blank a
# take-over that lands between its read and its write (docs/hosts.md).
claim_tick() {
  local id
  CLAIM_NEW=""
  id=$(host_id)
  if [ -z "$id" ]; then
    (( CANCCU_DRY )) && { echo "  would: write $(canccu_tilde "$CANCCU_ROOT")/host-id, then claim the repo"; return 0; }
    claim_refuse "$(canccu_tilde "$CANCCU_ROOT")/host-id is not 16 hex characters: project $CANCCU_PROJECT does nothing until it is (remove it: a new one is written)"
    return
  fi
  claim_read || { claim_gh_error; return; }
  if [ -z "$CLAIM_ISSUE" ]; then
    claim_create "$id" || { claim_gh_error; return; }
  elif [ "$CLAIM_HOST" = "$id" ]; then
    if (( $(now) - ${CLAIM_AT:-0} >= CLAIM_RENEW_MIN * 60 )); then
      claim_write "$CLAIM_ISSUE" "$id" || { claim_gh_error; return; }
      CLAIM_AT=$(now)
    fi
    claim_ours; return
  elif claim_free; then
    claim_write "$CLAIM_ISSUE" "$id" || { claim_gh_error; return; }
    log "claim: took #$CLAIM_ISSUE ($(if [ -n "$CLAIM_HOST" ]; then echo "held by $(claim_holder), last written $(iso "${CLAIM_AT:-0}")"; else echo released; fi))"
  else
    claim_foreign; return
  fi
  (( CANCCU_DRY )) && return 0
  claim_read "$CLAIM_NEW" "$id" || { claim_gh_error; return; }
  if [ "$CLAIM_HOST" = "$id" ]; then claim_ours; return; fi
  # a re-read that lists no claim issue at all is a gh error, not a lost race
  [ -n "$CLAIM_ISSUE" ] || { claim_gh_error; return; }
  # another host created one at the same moment and its issue is the lower: ours goes
  [ -n "${CLAIM_NEW:-}" ] && [ "$CLAIM_NEW" != "$CLAIM_ISSUE" ] && mut gh issue close "$CLAIM_NEW" -R "$REPO" >/dev/null
  claim_foreign
}

# claim_release: at a clean stop of the loop, the claim is released, after a read shows it is
# still ours (another host may have taken it meanwhile). A gh error leaves it to expire.
claim_release() {
  local id; id=$(host_id)
  [ -n "$id" ] && claim_read && [ -n "$CLAIM_ISSUE" ] && [ "$CLAIM_HOST" = "$id" ] || return 0
  claim_write "$CLAIM_ISSUE" "" || { log "claim: could not release #$CLAIM_ISSUE; it expires after CLAIM_EXPIRY_MIN"; return 0; }
  claim_set state= wrote=
  log "claim: released #$CLAIM_ISSUE"
}

# claim_take_over: canccu-dispatch --take-over: print whose the claim is, take it for this host
claim_take_over() {
  local id; id=$(host_id); CLAIM_NEW=""
  [ -n "$id" ] || die "$(canccu_tilde "$CANCCU_ROOT")/host-id is not 16 hex characters (remove it: a new one is written)"
  claim_read || die "gh error reading the dispatcher claim of $REPO; nothing taken"
  if [ -z "$CLAIM_ISSUE" ]; then
    echo "$REPO has no claim issue yet: creating it for this host ($id)"
    claim_create "$id" || die "gh error creating the claim issue; nothing taken"
  else
    if [ "$CLAIM_HOST" = "$id" ]; then echo "this host holds #$CLAIM_ISSUE already: written again"
    elif [ -z "$CLAIM_HOST" ]; then echo "#$CLAIM_ISSUE is released (no host)"
    else echo "#$CLAIM_ISSUE is held by $(claim_holder), last written $(iso "${CLAIM_AT:-0}")$(claim_free && echo " (expired)")"; fi
    claim_write "$CLAIM_ISSUE" "$id" || die "gh error writing the claim on #$CLAIM_ISSUE; nothing taken"
  fi
  (( CANCCU_DRY )) && return 0
  claim_read "$CLAIM_NEW" "$id" && [ "$CLAIM_HOST" = "$id" ] || die "the claim on #${CLAIM_ISSUE:-?} does not show this host after the write; read it again with canccu-status"
  claim_ours
  log "claim: #$CLAIM_ISSUE taken over by hand (canccu-dispatch --take-over)"
  echo "this host ($id${HOST_LABEL:+, $HOST_LABEL}) holds #$CLAIM_ISSUE now"
}

# claim_text: what canccu-status and the snapshot say while the project does nothing for the
# claim; nothing while this host holds it
claim_text() {
  local h l a
  case $(claim_get state) in
    foreign) h=$(claim_get holder) l=$(claim_get holder_label) a=$(claim_get at)
             echo "CLAIMED BY ANOTHER HOST: ${l:+$l (}$h${l:+)} on #$(claim_get issue), last written $(iso "${a:-0}"): this dispatcher does nothing for $CANCCU_PROJECT (canccu-dispatch --take-over takes the claim)" ;;
    lost) echo "CLAIM NOT HELD: a gh error on the claim, and this host holds no fresh claim: this dispatcher does nothing for $CANCCU_PROJECT until it reads the claim again" ;;
  esac
}

# claim_warning <repo>: canccu-init's warning for a repo another host holds a fresh claim on;
# nothing otherwise, a gh error included (init never refuses for it)
claim_warning() {
  local j id
  j=$(timeout 30 gh issue list -R "$1" -s open -l "$CLAIM_LABEL" -L 20 --json number,body 2>/dev/null) || return 0
  claim_parse "$j" && [ -n "$CLAIM_ISSUE" ] || return 0
  { read -r id < "$CANCCU_ROOT/host-id"; } 2>/dev/null
  [ "$CLAIM_HOST" = "${id:-}" ] && return 0
  claim_free && return 0
  echo "warning: $1 is claimed by host $(claim_holder) (#$CLAIM_ISSUE, last written $(date -u -d "@$CLAIM_AT" +%Y-%m-%dT%H:%M:%SZ)): its dispatcher here will do nothing until that claim expires or canccu-dispatch --take-over takes it"
}
