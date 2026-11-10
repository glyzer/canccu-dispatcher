# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): follow-up runs: fresh session or
# resume (RESUME_ON) with the handoff, the fix-attempt cap, the scripted merge of main and red CI.
# A resumed session reloads the whole build conversation and re-reads it every turn (measured
# ~8x the per-turn cost of a fresh run), so a follow-up starts fresh unless its kind is named.

# resume_on <kind>: RESUME_ON names the kind (or is `all`): its follow-up resumes the session
resume_on() { local r=",${RESUME_ON// /,},"; [[ $r == *",all,"* || $r == *",$1,"* ]]; }

# fix_kind <kind>: a fix run, which gets FIX_MODEL and FIX_EFFORT
fix_kind() { case $1 in fix|ci|needs-work) return 0 ;; esac; return 1; }

# fixes_used <K> <pr>: the automatic fix runs (review fix rounds, red-CI fixes) on that PR so far;
# a count kept for another PR (the unit opened a new one) is not this PR's
fixes_used() { [ "$(st_get "$1" fixes_pr)" = "$2" ] && echo "$(( $(st_get "$1" fixes) + 0 ))" || echo 0; }
fix_left() { (( $(fixes_used "$1" "$2") < FIX_ATTEMPTS )); }
fix_count() { st_set "$1" fixes=$(( $(fixes_used "$1" "$2") + 1 )) fixes_pr="$2"; }

# handoff <K>: what a fresh follow-up session gets instead of the old conversation: the PR, its
# body (Decisions made:, Follow-up:), the branch's commits, uncommitted files, the last report
# and the standing orders of the first run. Each part is cut, so the task in front of it fits
# run_worker's prompt limit.
handoff() {
  local k=$1 pr wt body="" commits="" dirty="" rep
  pr=$(st_get "$k" pr); [ -n "$pr" ] || pr=$(pr_for "$k")
  wt=$(unit_wt "$k")
  [ -n "$pr" ] && body=$(pr_get "$pr" .body)
  if [ -e "$wt/.git" ]; then
    commits=$(guard 20 git -C "$wt" log --oneline origin/main..HEAD 2>/dev/null | head -n 30)
    dirty=$(guard 20 git -C "$wt" status --short 2>/dev/null | head -n 20)
  fi
  rep=$(run_msg "$k" | tail -n 12)
  printf '%s' "This run is a fresh session, not a resume of your earlier one: your earlier work is in this worktree, on its branch. Build on it; never create the branch again or open a second PR."
  [ -n "$pr" ] && printf ' The PR: %s.' "$(pr_url "$pr")"
  [ -n "$body" ] && printf ' Its body: %s' "$(oneline 1500 "$body")"
  printf ' The commits on the branch (git log origin/main..HEAD): %s.' "$(oneline 1000 "${commits:-none read}")"
  [ -n "$dirty" ] && printf ' Uncommitted in the worktree: %s.' "$(oneline 400 "$dirty")"
  [ -n "$rep" ] && printf ' Your last report: %s' "$(oneline 1200 "$rep")"
  printf ' The standing orders of the first run (the branch exists already): %s' "$(unit_prompt "$k")"
}

# main_merge <K> <pr>: bring main into the PR's branch without an AI run, in the unit's worktree.
# Not run in $(…): MERGED is the outcome, CONFLICTS the conflicting paths. MERGED is merged (pushed; CI runs again), current (main already in, or nothing to merge in: no worktree,
# another branch checked out, uncommitted files), conflict (aborted; an AI run resolves it,
# CONFLICTS) or error (a git or push failure; again next pass). Never a rebase
# or a force-push: the squash-merge flattens the branch anyway.
main_merge() {
  local k=$1 pr=$2 wt br behind
  wt=$(unit_wt "$k"); CONFLICTS="" MERGED=current
  [ -e "$wt/.git" ] || return 0
  br=$(pr_get "$pr" .headRefName)
  [ -n "$br" ] && [ "$(guard 20 git -C "$wt" branch --show-current 2>/dev/null)" = "$br" ] || return 0
  [ -z "$(guard 20 git -C "$wt" status --porcelain 2>/dev/null)" ] || return 0
  guard 120 git -C "$wt" fetch -q origin >/dev/null 2>&1 || { MERGED=error; return 0; }
  behind=$(guard 20 git -C "$wt" rev-list --count HEAD..origin/main 2>/dev/null)
  [[ $behind =~ ^[0-9]+$ ]] && (( behind > 0 )) || return 0
  if ! mut git -C "$wt" merge --no-edit origin/main; then
    CONFLICTS=$(guard 20 git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    mut git -C "$wt" merge --abort
    MERGED=conflict; return 0
  fi
  mut git -C "$wt" push origin "HEAD:refs/heads/$br" || { MERGED=error; return 0; }
  MERGED=merged
}

# ci_log_tail <pr>: the newest log lines of the first failing job of a red CI (its check links to
# a GitHub Actions job); else how to read them
ci_log_tail() {
  local pr=$1 url jid t=""
  url=$(jqr --argjson p "$pr" '.[] | select(.number == $p) | [.statusCheckRollup[]?
      | select(((.conclusion // .state // "") | ascii_upcase) | IN("FAILURE", "TIMED_OUT", "ERROR", "STARTUP_FAILURE"))
      | .detailsUrl // empty | select(test("/actions/runs/[0-9]+/job/[0-9]+"))] | first // empty' <<<"$PRS")
  jid=$(grep -oE '/job/[0-9]+' <<<"$url" | grep -oE '[0-9]+$')
  [ -n "$jid" ] && t=$(ghj run view --job "$jid" -R "$REPO" --log-failed 2>/dev/null | tail -n "${CI_LOG_LINES:-60}")
  if [ -n "$t" ]; then printf 'The failing job (%s), the tail of its log: %s' "$url" "$(oneline 2500 "$t")"
  else printf 'Read the failing checks with gh pr checks %s -R %s and their logs with gh run view --log-failed.' "$pr" "$REPO"; fi
}

# ci_red <K> <pr>: CI is red on the PR. Main is merged in first (by script: another merged PR may
# have caused the failure) and CI runs again; still red with main in, a fresh fix session gets the
# failing job's log tail. At most FIX_ATTEMPTS automatic fix runs per PR, then needs-you.
ci_red() {
  local k=$1 pr=$2 head mm at
  head=$(pr_get "$pr" .headRefOid); mm=$(st_get "$k" main_merged); at=$(st_get "$k" check_at)
  # pushed a merge of main, but GitHub still lists the old head: its red is not the new head's.
  # Only for a while: a push by someone else since would hold it forever.
  if [ -n "$mm" ] && [ "$head" != "$mm" ] && (( $(now) - ${at:-0} < 600 )); then log "#$k PR #$pr: main merged in; waiting for GitHub to list ${mm:0:7}"; return 0; fi
  (( FIX_ATTEMPTS > 0 )) || { needs_you "$k" "CI is red on PR #$pr" "$(run_msg "$k")" "" ci; return; }
  main_merge "$k" "$pr"
  case $MERGED in
    merged)
      st_set "$k" main_merged="$(guard 20 git -C "$(unit_wt "$k")" rev-parse HEAD 2>/dev/null)" check_at="$(now)"
      log "#$k PR #$pr: CI red; merged main into the branch (no AI run), CI runs again"; return 0 ;;
    conflict)
      backing_off && return 0; room "$k" || return 0
      resume "$k" "Merging origin/main into the branch of PR #$pr conflicts in: ${CONFLICTS% }. Run git merge origin/main, resolve the conflicts keeping what both sides meant, rerun the checks, push once (a normal push, never a rebase or force-push), and stop when CI is green." merge
      return 0 ;;
    error) log "#$k PR #$pr: CI red; merging main failed, again next pass"; return 0 ;;
  esac
  fix_left "$k" "$pr" || { needs_you "$k" "CI is red on PR #$pr after $FIX_ATTEMPTS automatic fix runs (FIX_ATTEMPTS)" "$(run_msg "$k")" "" ci; return; }
  backing_off && return 0; room "$k" || return 0
  resume "$k" "CI is red on PR #$pr, with main already merged in, so the failure is the PR's. Fix it, rerun the checks, push once, and stop when CI is green. $(ci_log_tail "$pr")" ci || return 0
  fix_count "$k" "$pr"
  log "#$k PR #$pr: CI red; fix run $(fixes_used "$k" "$pr") of $FIX_ATTEMPTS"
}
