# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the "What you will see" captures of a
# user-visible PR (PREVIEW_CMD; docs/reference/rules.md). The worker makes them and the reviewer
# checks them: the dispatcher itself never runs the repo's code.

PREVIEW_HEADING='## What you will see'

# preview_rule <branch>: the worker and package prompts' preview sentence, with a leading space;
# nothing when the repo makes no previews
preview_rule() {
  [ -n "${PREVIEW_CMD:-}" ] || return 0
  printf ' This repo makes previews: before marking the PR ready, if it changes what users see, run `%s <dir>` on origin/main and on your head, push the images to the branch canccu-previews (create it as an orphan branch; never merge it) under %s/before and %s/after, and add a section "%s" to the PR body with each text capture in a fenced block and each image linked from that branch, before and after.' \
    "$PREVIEW_CMD" "$1" "$1" "$PREVIEW_HEADING"
}

# has_preview_section <body>: the body has the heading line (a body edited on GitHub ends its
# lines in CRLF)
has_preview_section() { tr -d '\r' <<<"$1" | grep -qE "^${PREVIEW_HEADING}[[:space:]]*\$"; }

# preview_review_text <pr>: the reviewer prompt's capture check, with a leading space; nothing
# when the PR body has no section
preview_review_text() {
  has_preview_section "$(pr_get "$1" '.body // ""')" || return 0
  printf ' Check that the "What you will see" captures match the diff: a capture that shows something the diff does not do is a blocking correctness finding.'
}

# preview_missing <n> <pr> <pr_detail json>: with PREVIEW_CMD set, a PR the accept classifies
# `users see it` and whose body lacks the section never reaches a review: the worker adds it once
# (preview_fix; not a fix round of FIX_ATTEMPTS), then the user. 0 when it hit (the caller stops).
preview_missing() {
  local n=$1 pr=$2 j=$3 c p
  [ -n "${PREVIEW_CMD:-}" ] || return 1
  has_preview_section "$(jqr '.body // ""' <<<"$j")" && return 1
  # the accept's own classification: a PR sent back here is exactly one that will wait for a look
  c=$(classify "$pr" "$n")
  [[ $c == retry:* ]] && { log "#$n PR #$pr: $c; the preview check runs again next pass"; return 0; }
  p=${c#manual: users see it: }
  # a bad USER_VISIBLE_PATHS names no path to show: the accept waits anyway
  [ "$p" != "$c" ] && [ "$p" != "USER_VISIBLE_PATHS is not a valid pattern" ] || return 1
  if [ "$(st_get "$n" preview_fix)" = "$pr" ]; then
    needs_you "$n" "PR #$pr changes what users see but still has no \"$PREVIEW_HEADING\" section"
    return 0
  fi
  room "$n" || return 0
  resume "$n" "PR #$pr changes what users see ($p) but its body has no \"$PREVIEW_HEADING\" section. Make the captures as the rules say, add the section, push nothing else. Then stop." fix || return 0
  st_set "$n" preview_fix="$pr"
  log "#$n PR #$pr: no \"What you will see\" section; the worker adds it"
}
