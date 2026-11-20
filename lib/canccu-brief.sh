# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# lib/canccu-brief.sh — the lines canccu-status and `canccu-dispatcher leader brief`
# (libexec/canccu-brief) share, so both tell one truth; and the brief's own parts. Sourced after
# lib/canccu-common.sh and lib/canccu-snapshot-steps.sh, never run. Read only: nothing here writes.

# status_header: the state, model, usage, project and runs lines that open canccu-status
status_header() {
  local state="running" free lim rv lp w
  if pause_holds; then state="PAUSED (canccu-resume to continue)"
  elif paused; then state="PAUSED, work in flight finishes (canccu-resume to continue)"; fi
  dispatcher_running || state+=" · canccu-dispatch is NOT running (canccu-up, or run it in the window dispatch)"
  backing_off && state+=" · usage limit until $(iso "$(backoff_until)")"
  free=$(disk_low) && state+=" · disk low: $free MB (DISK_MIN_MB ${DISK_MIN_MB:-200})"
  lim=$(gh_limit_until); [ -n "$lim" ] && state+=" · GitHub rate limit until $(iso "$lim")"
  echo "canccu-dispatcher $CANCCU_VERSION · $REPO · $state"
  if [ -n "$REVIEWER_LOGIN" ]; then rv="reviews post as $REVIEWER_LOGIN"; else rv="reviews: REVIEWER_LOGIN is not set"; fi
  echo "model: ${MODEL:-the account default} · $rv"
  echo "accepts: ${ACCEPT_CHANNELS-all}"
  lp=$(login_problem)
  [ -n "$lp" ] && echo "$lp: the dispatcher does nothing for this project until it is set"
  echo "usage: $(usage_text)"
  echo "project: $CANCCU_PROJECT (${CANCCU_HOME/#$HOME/\~}, tmux $TMUX_SESSION) · runs: $(running_count) of CAP $CAP · all projects: $(total_running) of TOTAL_CAP $TOTAL_CAP"
  w=$(waiting_for); [ -n "$w" ] && echo "waiting for a slot held by $w"
  return 0
}
# status_queue: the next 5 runnable issues (after fetch)
status_queue() {
  local q; q=$(runnable 5 | sed 's/^/#/' | tr '\n' ' ')
  echo "queue (fast lane, next 5 runnable): ${q:-none}"
}
# status_step <milestone>: the step's line: title, wave, phase, spend, checkpoint (after fetch_steps)
status_step() {
  local m=$1 sp c cs
  read -r sp _ <<<"$(step_spend "$m")"; c=$(step_get "$m" checkpoint)
  cs=$(cur "$m" '.checkpoint.state // empty'); [ "$(step_get "$m" phase)" = checkpoint ] && cs=waiting
  echo "step: $(step_title "$m") · wave $(step_get "$m" wave) · $(step_get "$m" phase || true) · \$$sp/\$$STEP_BUDGET${c:+ · checkpoint #$c ${cs:-open}}"
}

# status_step_waiting <m>: one line per ready issue of the step waiting for its next wave (#236)
status_step_waiting() {
  local n; for n in $(step_waiting "$1"); do echo "  #$n · $(title_of "$n") · waiting for $(next_wave_why "$1")"; done
}

# brief_open <owner>: the feed's open lines of that owner, oldest first, as "<id> · <kind> · <unit>
# · PR <pr> · <text>". Open: no later closed line's text starts with "closes <id>:" (§3).
brief_open() {
  local out
  out=$(awk -F '\t' -v o="$1" '
    $5 == "closed" { if (match($9, /^closes [0-9]+:/)) shut[substr($9, 8, RLENGTH - 8)] = 1; next }
    $3 == o { id[++n] = $2; l[n] = sprintf("  %s · %s · %s · %s · %s", $2, $5, $6, ($7 == "-" ? "no PR" : "PR " $7), $9) }
    END { for (i = 1; i <= n; i++) if (!(id[i] in shut)) print l[i] }' "$(feed_file)" 2>/dev/null)
  echo "${out:-  none}"
}

# brief: the leader's first command (docs/reference/leader.md)
brief() {
  local m f=$CANCCU_HOME/actions.log
  status_header
  echo "open for the leader:"; brief_open leader
  echo "open for the product owner:"; brief_open po
  echo "next:"
  if fetch; then
    if fetch_steps; then for m in $(current_step_ids); do echo "  $(status_step "$m")"; status_step_waiting "$m" | sed 's/^/  /'; done
    else echo "  steps: gh error reading the milestones"; fi
    echo "  $(status_queue)"
  else echo "  queue: gh error"; fi
  echo "actions (last 10):"
  if [ -s "$f" ]; then tail -n 10 "$f" | sed 's/^/  /'; else echo "  none"; fi
}
