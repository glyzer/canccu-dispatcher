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
fix_left() { (( $(fixes_used "$1" "$2") < $(fix_max) )); }
fix_count() { st_set "$1" fixes=$(( $(fixes_used "$1" "$2") + 1 )) fixes_pr="$2"; }
# may_start <K>: a follow-up run of the unit can start now: no back-off, and a slot. Checked before
# its state changes, so a refused start leaves the work for the next pass (the engine would refuse
# it anyway, and log that every pass)
may_start() { backing_off && return 1; room "$1"; }

# handoff <K> [kind]: what a fresh follow-up session gets instead of the old conversation: the PR,
# its body (Decisions made:, Follow-up:), the branch's commits and their diff stat, uncommitted
# files, the last report (not for kind limited), and the unit and its branch (the rules are in the
# repo and in SAFETY_BLOCK, not the first prompt again). Each part is cut to fit the prompt limit.
handoff() {
  local k=$1 pr wt body="" commits="" stat="" dirty="" rep="" br unit m
  pr=$(st_get "$k" pr); [ -n "$pr" ] || pr=$(pr_for "$k")
  wt=$(unit_wt "$k")
  [ -n "$pr" ] && body=$(pr_get "$pr" .body)
  if [ -e "$wt/.git" ]; then
    commits=$(guard 20 git -C "$wt" log --oneline origin/main..HEAD 2>/dev/null | head -n 30)
    stat=$(guard 20 git -C "$wt" diff --stat origin/main...HEAD 2>/dev/null | tail -n 25)
    dirty=$(guard 20 git -C "$wt" status --short 2>/dev/null | head -n 20)
  fi
  # a limited run's task carries its own handoff already: its last report would repeat it
  [ "${2:-}" = limited ] || rep=$(run_msg "$k" | tail -n 12)
  printf '%s' "This run is a fresh session, not a resume of your earlier one: your earlier work is in this worktree, on its branch. Build on it; never create the branch again or open a second PR."
  [ -n "$pr" ] && printf ' The PR: %s.' "$(pr_url "$pr")"
  [ -n "$body" ] && printf ' Its body: %s' "$(oneline 1500 "$body")"
  printf ' The commits on the branch (git log origin/main..HEAD): %s.' "$(oneline 1000 "${commits:-none read}")"
  [ -n "$stat" ] && printf ' Their diff stat (git diff --stat origin/main...HEAD): %s.' "$(oneline 800 "$stat")"
  [ -n "$dirty" ] && printf ' Uncommitted in the worktree: %s.' "$(oneline 400 "$dirty")"
  [ -n "$rep" ] && printf ' Your last report: %s' "$(oneline 1200 "$rep")"
  br=$(st_get "$k" branch); [ -n "$br" ] || [ ! -e "$wt/.git" ] || br=$(guard 20 git -C "$wt" branch --show-current 2>/dev/null)
  if [ -n "$(st_get "$k" pkg)" ]; then
    unit="work package \"$(st_get "$k" pkg)\" (issues"; for m in $(members_of "$k"); do unit+=" #$m,"; done; unit="${unit%,})"
  else unit="issue #$k"; fi
  printf ' This run is on %s, branch %s. The repo'"'"'s AGENTS.md and CLAUDE.md hold the full rules.' "$unit" "${br:-$k}"
}

# handoff_file <K>: the handoff a run nudged at the usage stop ended with (its final message); kept
# apart from .last, which the next run of the unit overwrites
handoff_file() { echo "$CANCCU_HOME/handoffs/$1.md"; }
# handoff_keep <K> <text>: store the handoff; an empty text removes it (a hard stop left none)
handoff_keep() {
  (( CANCCU_DRY )) && return 0
  if [ -z "$2" ]; then rm -f "$(handoff_file "$1")"; return 0; fi
  mkdir -p "$CANCCU_HOME/handoffs" && printf '%s\n' "$2" | head -n 60 > "$(handoff_file "$1")" ||
    log "#$1: cannot save the handoff"
}
# limited_task <K>: the task of the run after the usage reset. Fresh (resume adds the commits and
# their diff stat), from the stored handoff, or, cut off by the hard limit, from git status; with
# RESUME_ON naming limited the old resumed session's "continue".
limited_task() {
  local h
  if resume_on limited; then echo "Continue where you stopped: the usage limit has reset."; return; fi
  h=$(cat "$(handoff_file "$1")" 2>/dev/null)
  if [ -n "$h" ]; then
    echo "The usage limit has reset. Your earlier run stopped at the usage limit and ended with this handoff (done, left, next step, decisions made, test state, head): $(oneline 3000 "$h") Continue from its next step."
  else
    echo "The usage limit has reset. Your earlier run was cut off by the usage limit before it could write a handoff: check git status for uncommitted work and the commits below, then continue the task."
  fi
}

# main_merge <K> <pr>: bring main into the PR's branch without an AI run, in the unit's worktree.
# Not run in $(…): MERGED is the outcome, MERGE_WHY its detail. MERGED is merged (pushed; CI runs
# again), current (main is in already), skipped (nothing merged; MERGE_WHY says why: no worktree,
# another branch checked out, uncommitted changes), conflict (aborted; MERGE_WHY the conflicting
# paths) or error (fetch or push failed; MERGE_WHY git's message). Untracked files (build output)
# do not stop it. Never a rebase or a force-push: the squash-merge flattens the branch anyway.
main_merge() {
  local k=$1 pr=$2 wt br behind
  wt=$(unit_wt "$k"); MERGE_WHY="" MERGED=skipped
  [ -e "$wt/.git" ] || { MERGE_WHY="no worktree of the run"; return 0; }
  br=$(pr_get "$pr" .headRefName)
  [ -n "$br" ] && [ "$(guard 20 git -C "$wt" branch --show-current 2>/dev/null)" = "$br" ] \
    || { MERGE_WHY="the worktree has another branch checked out"; return 0; }
  [ -z "$(guard 20 git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ] \
    || { MERGE_WHY="uncommitted changes in the worktree"; return 0; }
  MERGED=error
  MERGE_WHY=$(guard 120 git -C "$wt" fetch -q origin 2>&1) || { MERGE_WHY="git fetch: $(oneline 300 "$MERGE_WHY")"; return 0; }
  MERGE_WHY=""
  behind=$(guard 20 git -C "$wt" rev-list --count HEAD..origin/main 2>/dev/null)
  [[ $behind =~ ^[0-9]+$ ]] || { MERGE_WHY="git rev-list failed"; return 0; }
  (( behind > 0 )) || { MERGED=current; return 0; }
  if ! mut git -C "$wt" merge --no-edit origin/main; then
    MERGE_WHY=$(guard 20 git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    mut git -C "$wt" merge --abort
    MERGE_WHY=${MERGE_WHY% } MERGED=conflict; return 0
  fi
  MUT_OUT=""; mut git -C "$wt" push origin "HEAD:refs/heads/$br" || { MERGE_WHY="git push: $(oneline 300 "${MUT_OUT:-}")"; return 0; }
  MERGED=merged
}

# conflict_task <pr> <paths>: the task of a worker's merge run (kind merge: no fix attempt), for a
# merge of main that conflicts, whether red CI (ci_red) or GitHub's merge state (conflict_merge) found it
conflict_task() {
  printf 'Merging origin/main into the branch of PR #%s conflicts in: %s. Run git merge origin/main, resolve the conflicts keeping what both sides meant, rerun the checks, push once (a normal push, never a rebase or force-push) and stop: the dispatcher watches CI.' "$1" "$2"
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

# fix_max: FIX_ATTEMPTS, or its default 2 when it is no whole number (a typo must not break the
# (( )) tests or lift the cap)
fix_max() { [[ ${FIX_ATTEMPTS:-} =~ ^[0-9]+$ ]] && echo "$FIX_ATTEMPTS" || echo 2; }

# ci_red <K> <pr>: CI is red on the PR. Main is merged in first (by script: another merged PR may
# have caused the failure) and CI runs again; still red with main in, a fresh fix session gets the
# failing job's log tail. At most FIX_ATTEMPTS automatic fix runs per PR, one conflict run per
# head and MERGE_TRIES failed merges in a row, then needs-you: nothing repeats unbounded.
ci_red() {
  local k=$1 pr=$2 head mm at err task
  head=$(pr_get "$pr" .headRefOid); mm=$(st_get "$k" main_merged); at=$(st_get "$k" check_at)
  # pushed a merge of main, but GitHub still lists the old head: its red is not the new head's.
  # Only for a while: a push by someone else since would hold it forever.
  if [ -n "$mm" ] && [ "$head" != "$mm" ] && (( $(now) - ${at:-0} < 600 )); then log "#$k PR #$pr: main merged in; waiting for GitHub to list ${mm:0:7}"; return 0; fi
  (( $(fix_max) > 0 )) || { needs_you "$k" "CI is red on PR #$pr" "$(run_msg "$k")" "" ci; return; }
  main_merge "$k" "$pr"
  [ "$MERGED" = error ] || st_set "$k" mm_err=
  case $MERGED in
    merged)
      st_set "$k" main_merged="$(guard 20 git -C "$(unit_wt "$k")" rev-parse HEAD 2>/dev/null)" check_at="$(now)"
      log "#$k PR #$pr: CI red; merged main into the branch (no AI run), CI runs again"; return 0 ;;
    conflict)
      # one conflict run per head: one that pushed nothing gets no second try
      [ "$(st_get "$k" conflict_sha)" = "$head" ] && { needs_you "$k" "CI is red on PR #$pr and merging origin/main into it conflicts in: $MERGE_WHY; the worker's merge run pushed no resolution" "$(run_msg "$k")" "" ci; return; }
      may_start "$k" || return 0
      resume "$k" "$(conflict_task "$pr" "$MERGE_WHY")" merge || return 0
      st_set "$k" conflict_sha="$head"; return 0 ;;
    error)
      err=$(( $(st_get "$k" mm_err) + 1 ))
      (( err >= ${MERGE_TRIES:-3} )) && { st_set "$k" mm_err=; needs_you "$k" "CI is red on PR #$pr and merging main into it by script failed $err times: $MERGE_WHY" "" "" ci; return; }
      st_set "$k" mm_err="$err"; log "#$k PR #$pr: CI red; merging main failed ($MERGE_WHY), again next pass"; return 0 ;;
  esac
  fix_left "$k" "$pr" || { needs_you "$k" "CI is red on PR #$pr after $(fix_max) automatic fix runs (FIX_ATTEMPTS)" "$(run_msg "$k")" "" ci; return; }
  may_start "$k" || return 0
  if [ "$MERGED" = current ]; then task="CI is red on PR #$pr, with main already merged in, so the failure is the PR's. Fix it,"
  else task="CI is red on PR #$pr; main was not merged in by script ($MERGE_WHY). First run git merge origin/main (a normal merge and push, never a rebase or force-push), then fix what is still red,"; fi
  resume "$k" "$task rerun the checks, push once and stop: the dispatcher watches CI. $(ci_log_tail "$pr")" ci || return 0
  fix_count "$k" "$pr"
  log "#$k PR #$pr: CI red; fix run $(fixes_used "$k" "$pr") of $(fix_max)"
}

# finish_once <K>: a run that ended with work in its worktree but no PR (its turn ended while work
# ran in the background, or before its push) gets one fresh session to push it and open the PR
# before it is needs-you (#26). 1: nothing to finish, or its finish run was had already.
finish_once() {
  local k=$1 wt commits dirty
  [ "$(st_get "$k" finish_tried)" = 1 ] && return 1
  wt=$(unit_wt "$k"); [ -e "$wt/.git" ] || return 1
  commits=$(guard 20 git -C "$wt" log --oneline origin/main..HEAD 2>/dev/null | head -n1)
  dirty=$(guard 20 git -C "$wt" status --porcelain 2>/dev/null | head -n1)
  [ -n "$commits$dirty" ] || return 1
  may_start "$k" || return 0
  # the handoff (its commits, diff stat and uncommitted files) is this session's context, not the whole task again
  st_set "$k" no_pr=
  resume "$k" "Finish: your earlier run ended with work in this worktree and no PR (its turn ended while work ran in the background, or before its push). Run nothing in the background. Commit what is uncommitted, run the tests of the files you changed in the foreground, push the branch and open the PR, ready, with the body the task asks for; then stop: the dispatcher watches CI." finish || return 0
  st_set "$k" finish_tried=1
}
