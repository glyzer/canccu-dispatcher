# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by lib/canccu-pipeline.sh: a worker that stops at its turn or time budget while its PR
# moves on continues on its own (#127). A big build can need several runs, and each needs-you in
# between is a wait for a person; the unit's USD work budget, not the turn count, is the real cap.

# run_mark <K>: at a run's start, what its progress is measured against: its PR's head and draft
run_mark() {
  local p h="" d=""; p=$(pr_for "$1")
  [ -z "$p" ] || { h=$(pr_get "$p" .headRefOid); d=$(pr_get "$p" .isDraft); }
  st_set "$1" run_head="$h" run_draft="$d"
}

# used_add <K>: the reaped run's turns, USD and seconds (its exit report's header) added to the
# unit's "used" ("<turns> <usd> <secs>" since it started); an unknown cost counts 0
used_add() {
  local h; h=$(head -1 "$WORKERS_DIR/$REPO_NAME-$1.last" 2>/dev/null) || return 0
  [ -n "$h" ] || return 0
  st_set "$1" used="$(awk -F ' · ' -v u="$(st_get "$1" used)" 'NF >= 5 {
    t = $(NF - 2); sub(/ turns$/, "", t); c = $(NF - 1); sub(/^\$/, "", c); s = $NF
    m = s; sub(/m.*/, "", m); sub(/^[0-9]+m/, "", s); sub(/s$/, "", s)
    split(u, o, " ")
    printf "%d %.2f %d\n", o[1] + (t ~ /^[0-9]+$/ ? t : 0), o[2] + (c ~ /^[0-9.]+$/ ? c : 0), o[3] + m * 60 + s
  }' <<<"$h")"
}

# work_full <K>: the unit's work budget (a package's scaled by its size, #216)
work_full() { if [ -n "$(st_get "$1" pkg)" ]; then pkg_budget "$BUDGET_WORK" "$(budget_factor "$1")"; else echo "$BUDGET_WORK"; fi; }
# resume_budget <K>: a follow-up run's budget
resume_budget() { if [ -n "$(st_get "$1" pkg)" ]; then pkg_budget "$BUDGET_RESUME" "$(budget_factor "$1")"; else echo "$BUDGET_RESUME"; fi; }
# work_left <K> [floor]: the work budget less what the unit used, each part at least the floor's
work_left() {
  local f u l; f=$(work_full "$1") u=$(st_get "$1" used) l=${2:-0 0 0}
  awk -v f="$f" -v u="$u" -v l="$l" 'function hi(a, b) { return a > b ? a : b }
    BEGIN { split(f, F, " "); split(u, U, " "); split(l, L, " ")
      printf "%d %s %d\n", hi(F[1] - U[1], L[1]), hi(F[2] - U[2], L[2]) + 0, hi(F[3] - int(U[3] / 60), L[3]) }'
}
# continue_budget <K>: a continuation's: a run's turns and minutes afresh (the budget it stopped
# on is per run), and only the USD the unit has left
continue_budget() {
  local t m u; read -r t _ m <<<"$(work_full "$1")"; read -r _ u _ <<<"$(work_left "$1")"
  echo "$t $u $m"
}

# budget_stop <K> <status>: a run stopped at a budget. At its turn or time budget with progress
# (its PR's head moved, or the PR left draft, since the run started) it continues: phase
# continue, which resume_step starts like any resume. Otherwise needs-you, saying which: no
# progress, CONTINUE_MAX used, the USD work budget used, or a cost-budget stop.
budget_stop() {
  local n=$1 s=$2 max=${CONTINUE_MAX:-3} c p h="" d="" what fu uu
  [[ $max =~ ^[0-9]+$ ]] || max=3
  case $s in "stopped: turn"*) what="turn budget" ;; "stopped: time budget"*) what="time budget" ;; *) what="" ;; esac
  if [ -z "$what" ] || (( max == 0 )) || is_deep "$n"; then needs_you "$n" "the worker stopped: $s" "$(run_msg "$n")"; return; fi
  c=$(st_get "$n" cont); [[ $c =~ ^[0-9]+$ ]] || c=0
  # the pass read the list before the run's last push
  fetch_prs; p=$(pr_for "$n")
  [ -z "$p" ] || { h=$(pr_get "$p" .headRefOid); d=$(pr_get "$p" .isDraft); }
  if [ -z "$p" ]; then needs_you "$n" "the worker stopped: $s, with no PR to show progress" "$(run_msg "$n")"; return; fi
  if [ "$h" = "$(st_get "$n" run_head)" ] && ! { [ "$(st_get "$n" run_draft)" = true ] && [ "$d" = false ]; }; then
    needs_you "$n" "the worker stopped: $s, with no new pushed commits on PR #$p" "$(run_msg "$n")"; return
  fi
  if (( c >= max )); then needs_you "$n" "the worker stopped: $s; its $max continuations (CONTINUE_MAX) are used" "$(run_msg "$n")"; return; fi
  read -r _ fu _ <<<"$(work_full "$n")"; read -r _ uu _ <<<"$(st_get "$n" used)"
  if awk -v f="$fu" -v u="${uu:-0}" 'BEGIN { exit !(u >= f) }'; then
    needs_you "$n" "the worker stopped: $s; the work budget of \$$fu is used (\$$uu)" "$(run_msg "$n")"; return
  fi
  c=$((c + 1))
  handoff_keep "$n" "$(run_msg "$n")"
  st_set "$n" phase=continue cont="$c" cont_why="$what"
  log "#$n stopped at its $what with progress (PR #$p at ${h:0:7}); continuation $c of $max"
}

continue_task() {
  local h; h=$(cat "$(handoff_file "$1")" 2>/dev/null)
  echo "Your earlier run stopped at its $(st_get "$1" cont_why) while it made progress: this is continuation $(st_get "$1" cont) of ${CONTINUE_MAX:-3}. It ended with this handoff: $(oneline 3000 "${h:-none; read the git log of the branch and the PR}"). Continue the task from where the branch and this handoff leave it; push at least every 30 turns."
}
