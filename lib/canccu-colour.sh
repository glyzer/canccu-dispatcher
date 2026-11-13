# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# Part of lib/canccu-common.sh, sourced by it: the colour of each issue in the pane and its tmux window.

# 6 well-separated ANSI 256 colours: blue, orange, purple, teal, pink, olive. Red, yellow and
# green are left out: they mean needs-you, waiting and merged.
CANCCU_PALETTE=(33 208 135 37 205 142)
# issue_live <n>: a run of the issue is live: its worker, its answerer or its PR's reviewer
issue_live() {
  local pr
  if run_alive "$1" || run_alive "answer-$1"; then return 0; fi
  pr=$(st_get "$1" pr); [ -n "$pr" ] && run_alive "review-$pr"
}
# issue_color <n>: the issue's palette index (0-5) from state/<n>, or nothing
issue_color() { local c; c=$(st_get "$1" color); [[ $c =~ ^[0-5]$ ]] && echo "$c"; return 0; }
# claim_color <n>: a run starts, or the issue becomes managed: an issue without a colour gets the
# lowest index no other managed issue holds. When all 6 are held, the holder that has waited
# longest (no live run, the oldest state file) gives its up (color=-, until its next run claims
# one); when every holder runs (only with CAP above 6), the index is shared. The state file goes
# on close, and the colour with it.
claim_color() {
  local n=$1 c m i victim="" vt=0 t
  local -A held=()
  [ -n "$(issue_color "$n")" ] && return 0
  for m in $(managed); do
    [ "$m" = "$n" ] && continue
    c=$(issue_color "$m"); [ -n "$c" ] && held[$c]=$m
  done
  for i in 0 1 2 3 4 5; do
    [ -n "${held[$i]+x}" ] || { st_set "$n" color="$i"; return 0; }
  done
  for i in 0 1 2 3 4 5; do
    m=${held[$i]}; issue_live "$m" && continue
    t=$(stat -c %Y "$(st_file "$m")" 2>/dev/null || echo 0)
    if [ -z "$victim" ] || (( t < vt )); then victim=$i vt=$t; fi
  done
  if [ -n "$victim" ]; then st_set "${held[$victim]}" color=-
  else victim=$n; [[ $n =~ ^[0-9]+$ ]] || victim=$(cksum <<<"$n" | cut -d' ' -f1)
    victim=$(( victim % 6 )); warn_once colours "more than 6 issues run at once: some share a colour"; fi
  st_set "$n" color="$victim"
}
# color_code <n>: the issue's ANSI 256 colour number, or nothing
color_code() { local c; c=$(issue_color "$1"); [ -n "$c" ] && echo "${CANCCU_PALETTE[c]}"; return 0; }
# paint_window <window name> <n>: the run's tmux window (only that one) gets the issue's colour.
# Never another window, a session option or the user's config; any tmux error is ignored.
paint_window() {
  local c w
  (( CANCCU_DRY )) && return 0
  [ -z "${NO_COLOR:-}" ] || return 0
  c=$(color_code "$2"); [ -n "$c" ] || return 0
  w=$(window_by_name "$1"); [ -n "$w" ] || return 0
  tmux set-option -w -t "$w" window-status-style "fg=colour$c" >/dev/null 2>&1
  tmux set-option -w -t "$w" window-status-current-style "fg=colour$c,bold" >/dev/null 2>&1
  return 0
}

