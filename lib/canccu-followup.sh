# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): follow-up runs: fresh session or
# resume (RESUME_ON) with the handoff, the scripted merge of main and red CI (the fix budgets:
# lib/canccu-fixbudget.sh).
# A resumed session reloads the whole build conversation and re-reads it every turn (measured
# ~8x the per-turn cost of a fresh run), so a follow-up starts fresh unless its kind is named.

# resume_on <kind>: RESUME_ON names the kind (or is `all`): its follow-up resumes the session
resume_on() { local r=",${RESUME_ON// /,},"; [[ $r == *",all,"* || $r == *",$1,"* ]]; }

# fix_kind <kind>: a fix run, which gets FIX_MODEL and FIX_EFFORT
fix_kind() { case $1 in fix|ci|needs-work) return 0 ;; esac; return 1; }

# may_start <K>: a follow-up run of the unit can start now: no back-off, no pause, and a slot.
# Checked before its state changes, so a refused start leaves the work for the next pass (the
# engine would refuse it anyway, and log that every pass)
may_start() { { backing_off || pause_holds; } && return 1; room "$1"; }

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
    commits=$(guard 20 git -C "$wt" log --oneline origin/$BASE_BRANCH..HEAD 2>/dev/null | head -n 30)
    stat=$(guard 20 git -C "$wt" diff --stat origin/$BASE_BRANCH...HEAD 2>/dev/null | tail -n 25)
    dirty=$(guard 20 git -C "$wt" status --short 2>/dev/null | head -n 20)
  fi
  # a limited run's or a continuation's task carries its own handoff already: its last report would repeat it
  case ${2:-} in limited|continue) ;; *) rep=$(run_msg "$k" | tail -n 12) ;; esac
  printf '%s' "This run is a fresh session, not a resume of your earlier one: your earlier work is in this worktree, on its branch. Build on it; never create the branch again or open a second PR."
  [ -n "$pr" ] && printf ' The PR: %s.' "$(pr_url "$pr")"
  [ -n "$body" ] && printf ' Its body: %s' "$(oneline 1500 "$body")"
  printf ' The commits on the branch (git log origin/%s..HEAD): %s.' "$BASE_BRANCH" "$(oneline 1000 "${commits:-none read}")"
  [ -n "$stat" ] && printf ' Their diff stat (git diff --stat origin/%s...HEAD): %s.' "$BASE_BRANCH" "$(oneline 800 "$stat")"
  [ -n "$dirty" ] && printf ' Uncommitted in the worktree: %s.' "$(oneline 400 "$dirty")"
  [ -n "$rep" ] && printf ' Your last report: %s' "$(oneline 1200 "$rep")"
  br=$(st_get "$k" branch); [ -n "$br" ] || [ ! -e "$wt/.git" ] || br=$(guard 20 git -C "$wt" branch --show-current 2>/dev/null)
  # the health pass has no members, and its limits are in no repo file
  if is_health "$k"; then
    unit="the health pass of step $(step_title "$(st_get "$k" step)") (cleanups only: change no behaviour; the PR has no \`Closes\` line)"
  elif [ -n "$(st_get "$k" pkg)" ]; then
    unit="work package \"$(st_get "$k" pkg)\" (issues"; for m in $(members_of "$k"); do unit+=" #$m,"; done; unit="${unit%,})"
  else unit="issue #$k"; fi
  printf ' This run is on %s, branch %s. The repo'"'"'s AGENTS.md and CLAUDE.md hold the full rules.' "$unit" "${br:-$k}"
  # the first prompt's test rule (RUN_RULES) is the dispatcher's, not the repo's: it goes again
  printf ' %s' "$(test_rule handoff)"
}

# test_rule [worker|handoff|fixcheck]: the test rule of TEST_TIER (#250) for the first prompt, a
# follow-up run's or the fix-check's. Any value but full is targeted: a typo must not turn a
# host's runs into full-suite runs. CI runs the full suite on every push at either tier.
test_rule() {
  local t=targeted; [ "${TEST_TIER:-}" = full ] && t=full
  { case ${1:-worker}-$t in
    worker-targeted) echo 'Tests (test tier targeted): while working and before marking the PR ready, run only the test files of the areas you touched (the affected-tests command CLAUDE.md names, when it has one), in the foreground; do not run the full suite locally: CI runs it on every push.' ;;
    worker-full) echo 'Tests (test tier full): while working, run only the tests of the files you change, in the foreground; before marking the PR ready, run the full suite once, in the foreground, bounded with timeout 9m (a foreground command may run 10 minutes at most; CI runs it on every push too).' ;;
    handoff-targeted) echo 'Tests (test tier targeted): run only the test files of the areas you touched and the repo checks, in the foreground; CI runs the full suite on every push. Never paste whole test logs; never run a command in the background.' ;;
    handoff-full) echo 'Tests (test tier full): run the tests of the files you change, and the full suite once before marking the PR ready, in the foreground, bounded with timeout 9m; CI runs it on every push too. Never paste whole test logs; never run a command in the background.' ;;
    fixcheck-targeted) echo 'Tests (test tier targeted): run at most the test files of the files the fix diff touches, in the foreground; never the full suite: CI runs it.' ;;
    fixcheck-full) echo 'Tests (test tier full): you may run the full suite once, in the foreground, bounded with timeout 9m; CI runs it too.' ;;
  esac
  # the worktree's pre-push hook (#328) refuses a push its check fails: a worker must fix, not skip it
  [ -z "${PRE_PUSH_CMD:-}" ] || [ "${1:-worker}" = fixcheck ] ||
    printf ' A pre-push hook runs `%s` on the changed files before every push. A refused push means: fix what it shows first, then push again. Never use `--no-verify`.' "$PRE_PUSH_CMD"
  } | tr -d '\n'; echo
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
  behind=$(guard 20 git -C "$wt" rev-list --count HEAD..origin/$BASE_BRANCH 2>/dev/null)
  [[ $behind =~ ^[0-9]+$ ]] || { MERGE_WHY="git rev-list failed"; return 0; }
  (( behind > 0 )) || { MERGED=current; return 0; }
  if ! mut git -C "$wt" merge --no-edit origin/$BASE_BRANCH; then
    MERGE_WHY=$(guard 20 git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    mut git -C "$wt" merge --abort
    MERGE_WHY=${MERGE_WHY% } MERGED=conflict; return 0
  fi
  MUT_OUT=""; mut git -C "$wt" push origin "HEAD:refs/heads/$br" || { MERGE_WHY="git push: $(oneline 300 "${MUT_OUT:-}")"; return 0; }
  MERGED=merged
}

# contract_resume <n> <pr> <c>: the draft waited for its contract PR #c, which is on main now. With
# MERGE_MAIN_ANY_PHASE=1 main is merged in by script first; when its last run (the one that stopped
# for the contract) reported its own work done (contract_done), the PR is marked ready by script
# and no run starts. A merge that could not run (a conflict among them) or unfinished work goes to
# a merge run (MERGE_MODEL). 1: nothing done (no run could start, or marking it ready failed).
contract_resume() {
  local n=$1 pr=$2 c=$3 t
  may_start "$n" || return 1
  t="The contract PR #$c merged into $BASE_BRANCH. Run git merge origin/$BASE_BRANCH in your branch, finish the package's work in PR #$pr and mark it ready."
  if [ "${MERGE_MAIN_ANY_PHASE:-1}" = 1 ]; then
    main_merge "$n" "$pr"
    case $MERGED in
      merged|current)
        if contract_done "$n"; then
          mut gh pr ready "$pr" -R "$REPO" || { log "#$n PR #$pr: marking it ready failed (gh); again next pass"; return 1; }
          log "#$n PR #$pr: contract PR #$c merged, main merged in, the package's work done: marked ready, no run"
          return 0
        fi
        log "#$n PR #$pr: contract PR #$c merged, main merged in; the package's work is unfinished: the worker finishes it"
        t="The contract PR #$c merged into $BASE_BRANCH, and $BASE_BRANCH is merged into your branch already. Finish the package's work in PR #$pr and mark it ready." ;;
      *) log "#$n PR #$pr: contract PR #$c merged; main could not be merged in ($MERGED${MERGE_WHY:+: $MERGE_WHY}): the worker merges it" ;;
    esac
  fi
  resume "$n" "$t" merge
}
# contract_done <n>: the run that stopped for the contract PR ended its report with "Package work:
# done" (contract_rule asks for the line). No line, or any other value, is unfinished work.
contract_done() {
  [ "$(grep -iE '^[[:space:]*_]*Package work:' <<<"$(run_msg "$1")" | tail -1 |
       sed -E 's/^[[:space:]*_]*Package work:[[:space:]*_]*//I; s/[[:space:]*_.]*$//' | tr 'A-Z' 'a-z')" = "done" ]
}

# no_checks_why <pr>: the no-checks needs-you's question. GitHub runs no pull_request checks on a
# PR that conflicts with main, so asking whether CI is set up would send the user the wrong way.
no_checks_why() {
  if [ "$(pr_get "$1" '.mergeStateStatus // ""')" = DIRTY ]; then echo "it conflicts with main, so GitHub runs no checks; merge main into it or say how"
  else echo "is CI set up for this repo, or did a path filter skip it?"; fi
}

# conflict_task <pr> <paths>: the task of a worker's merge run (kind merge: no fix attempt), for a
# merge of main that conflicts, whether red CI (ci_red) or GitHub's merge state (conflict_merge) found it
conflict_task() {
  local f='Merging origin/@BASE@ into the branch of PR #%s conflicts in: %s. Run git merge origin/@BASE@, resolve the conflicts keeping what both sides meant, commit the merge and push it at once (a normal push, never a rebase or force-push), then run only the tests of the files that conflicted and push a fix if one fails, and stop: the dispatcher watches CI.'
  # shellcheck disable=SC2059  # the format is ours; only the branch name goes in
  printf "${f//@BASE@/"$BASE_BRANCH"}" "$1" "$2"
}

# CI_TIMEDOUT: per Actions job id, whether its cancel was its own time limit (true/false). A job's
# result never changes, so it is asked once per process; ci_timeouts_load fills it outside the
# $(...) subshells that read it.
declare -gA CI_TIMEDOUT=()
# ci_job_timed_out <job id>: GitHub reports a job past its timeout-minutes as CANCELLED, like a
# hand or concurrency cancel; only the job's annotation tells them apart. A failed lookup is not
# kept: the next pass asks again.
ci_job_timed_out() {
  local r
  if [ -z "${CI_TIMEDOUT[$1]:-}" ]; then
    r=$(ghj api "repos/$REPO/check-runs/$1/annotations" -q '[.[].message // ""] | any(test("exceeded the maximum execution time"))' 2>/dev/null) || return 1
    CI_TIMEDOUT[$1]=$r
  fi
  [ "${CI_TIMEDOUT[$1]}" = true ]
}
# ci_timeouts_load <pr>: CI_TIMEDOUT asked for every cancelled job of the PR's head
ci_timeouts_load() {
  local j
  for j in $(jqr --argjson p "$1" --arg ign "${REVIEW_CHECKS:-}" "$CI_CHECKS"' ci_checks | .[]
      | select(.s == "COMPLETED" and .c == "CANCELLED") | .u | capture("/actions/runs/[0-9]+/job/(?<j>[0-9]+)").j // empty' <<<"$PRS"); do
    ci_job_timed_out "$j" || true
  done
}

# ci_failed <pr>: the checks that make ci_state red (the newest run per check, REVIEW_CHECKS left
# out: they wait for the verdict, no rerun or fix makes them pass), one per line:
# "<run id>\t<name>\t<conclusion>\t<job id>", the ids empty for a check that is no GitHub Actions
# run. A cancel by the job's own time limit is TIMED_OUT here.
ci_failed() {
  local run name c jid
  jqr --argjson p "$1" --arg ign "${REVIEW_CHECKS:-}" "$CI_CHECKS"' ci_checks | .[]
      | select(.s == "COMPLETED" and (.c | ci_bad))
      | [(.u | capture("/actions/runs/(?<id>[0-9]+)/").id // ""), .n, .c, (.u | capture("/actions/runs/[0-9]+/job/(?<j>[0-9]+)").j // "")] | join("\u001f")' <<<"$PRS" |
    # a tab would do as the separator, but read folds a run of tabs: an empty run id would vanish
    while IFS=$'\x1f' read -r run name c jid; do
      [ "$c" = CANCELLED ] && [ -n "$jid" ] && ci_job_timed_out "$jid" && c=TIMED_OUT
      printf '%s\t%s\t%s\t%s\n' "$run" "$name" "$c" "$jid"
    done
}
# ci_names <pr>: the failed checks' names, comma-separated, at most 5 then …; one that did not
# fail outright says how it ended: "CI (timed out)", "CI (cancelled)"
ci_names() {
  ci_failed "$1" | awk -F'\t' '{ c = tolower($3); gsub("_", " ", c); print (c == "failure" ? $2 : $2 " (" c ")") }' |
    awk 'NR <= 5 { o = o (NR > 1 ? ", " : "") $0 } NR == 6 { o = o ", …" } END { printf "%s", o }'
}
# ci_timed_out <pr>: the timed-out checks' names, comma-separated
ci_timed_out() { ci_failed "$1" | awk -F'\t' '$3 == "TIMED_OUT" { o = o (o == "" ? "" : ", ") $2 } END { printf "%s", o }'; }
# ci_fresh <pr> <epoch>: a failed check of the head completed after that time (a rerun since has ended)
ci_fresh() {
  [ "$(jqr --argjson p "$1" --arg ign "${REVIEW_CHECKS:-}" --arg at "$(iso "$2")" "$CI_CHECKS"' [ci_checks | .[]
      | select(.s == "COMPLETED" and (.c | ci_bad) and .t > $at)] | length' <<<"$PRS")" != 0 ]
}

# ci_run_busy <pr> <run id>: a check of that Actions run on the PR's head has not completed
ci_run_busy() {
  [ "$(jqr --argjson p "$1" --arg id "$2" '[.[] | select(.number == $p) | .statusCheckRollup[]?
      | select(((.detailsUrl // .targetUrl // "") | capture("/actions/runs/(?<id>[0-9]+)/").id // "") == $id)
      | select(((.status // "COMPLETED") | ascii_upcase) != "COMPLETED")] | length' <<<"$PRS")" != 0 ]
}

# rerun_wait <K> <pr> <head> <run id> <why>: the rerun of that run waits (<why>, a log phrase) because
# GitHub refuses it as already running: for at most 600 s per head (ci_wait_at = <head>:<epoch of
# the first wait>), then needs-you instead of holding the PR for ever. Always 0: the caller has
# handled the pass. needs_you clears ci_wait_at, so a lifted needs-you starts a new wait.
rerun_wait() {
  local k=$1 pr=$2 head=$3 id=$4 w at
  w=$(st_get "$k" ci_wait_at)
  if [ "${w%%:*}" = "$head" ] && [[ ${w#*:} =~ ^[0-9]+$ ]]; then at=${w#*:}
  else at=$(now); st_set "$k" ci_wait_at="$head:$at"; fi
  if (( $(now) - at >= 600 )); then
    needs_you "$k" "CI is red on PR #$pr; its failed jobs could not be rerun for 10 minutes: run $id ($(ci_names "$pr")); last: $5" "$(run_msg "$k")" "" ci
  else warn_once "rerun-wait-$pr" "#$k PR #$pr: CI red; $5"; fi
  return 0
}

# busy_wait <K> <pr> <run id>: a job of the failed run still runs (a healthy run: the rest of its jobs
# finish first): the rerun waits for them, bounded like a pending CI by CI_WAIT_MIN from check_at.
busy_wait() {
  local k=$1 pr=$2 id=$3 at; at=$(st_get "$k" check_at); at=${at:-$(now)}
  if (( $(now) - at > CI_WAIT_MIN * 60 )); then
    needs_you "$k" "CI is red on PR #$pr; run $id still has jobs running after $CI_WAIT_MIN min ($(ci_names "$pr"))" "" "" ci
  else warn_once "rerun-wait-$pr" "#$k PR #$pr: CI red; run $id still has jobs running: the rerun waits for them"; fi
  return 0
}

# ci_rerun <K> <pr> <head>: the failed GitHub Actions runs of a red head rerun (--failed), once per
# head, before any fix run: a flaky check costs no AI run. 0 also while a job of such a run still
# runs, or GitHub refuses the rerun as already running (it waits, spending nothing: busy_wait, bounded by
# CI_WAIT_MIN; a refused rerun at most 600 s: rerun_wait). 1: none rerun (none to rerun, done for this head, or every rerun call
# failed), the fix run goes on in this pass.
ci_rerun() {
  local k=$1 pr=$2 head=$3 id ids done=0
  [ "$(st_get "$k" ci_rerun)" != "$head" ] || return 1
  ids=$(ci_failed "$pr" | cut -f1 | grep -E '^[0-9]+$' | sort -u)
  [ -n "$ids" ] || return 1
  # GitHub refuses `rerun --failed` while a job of the run still runs: waiting spends no rerun
  for id in $ids; do
    ci_run_busy "$pr" "$id" || continue
    busy_wait "$k" "$pr" "$id"; return 0
  done
  st_set "$k" ci_rerun="$head" ci_rerun_at= check_at="$(now)"
  for id in $ids; do
    if mut_out gh run rerun "$id" --failed -R "$REPO"; then done=1
    elif [[ $MUT_OUT == *"already running"* ]]; then
      # a job the rollup did not list yet still runs: judge the run once it ends, spend nothing
      # (a run already rerun in this pass keeps the once-per-head mark: ci_red waits for its result)
      if (( done )); then st_set "$k" ci_rerun_at="$(now)"; else st_set "$k" ci_rerun= ci_rerun_at=; fi
      rerun_wait "$k" "$pr" "$head" "$id" "rerun of run $id refused (still running): it waits"; return 0
    else log "#$k PR #$pr: rerun of run $id failed ($(oneline 200 "$MUT_OUT"))"; fi
  done
  (( done )) || return 1
  st_set "$k" ci_rerun_at="$(now)"
  log "#$k PR #$pr: CI red on ${head:0:7} ($(ci_names "$pr")); failed jobs rerun once before any fix run"
}

# ci_red <K> <pr>: CI is red on the PR. Main is merged in first (by script: another merged PR may
# have caused the failure) and CI runs again; still red with main in, its failed jobs are rerun once
# (ci_rerun); still red, a fresh fix session gets the failing jobs' digest (ci_digest). At most FIX_ATTEMPTS
# automatic fix runs per PR, one conflict run and one rerun per head and 3 failed merges in a row
# (a fixed bound, not a setting), then needs-you (naming the failed checks): nothing repeats unbounded.
ci_red() {
  local k=$1 pr=$2 head mm at err task f ra to
  head=$(pr_get "$pr" .headRefOid); mm=$(st_get "$k" main_merged); at=$(st_get "$k" check_at)
  # pushed a merge of main, but GitHub still lists the old head: its red is not the new head's.
  # Only for a while: a push by someone else since would hold it forever.
  if [ -n "$mm" ] && [ "$head" != "$mm" ] && (( $(now) - ${at:-0} < 600 )); then log "#$k PR #$pr: main merged in; waiting for GitHub to list ${mm:0:7}"; return 0; fi
  # rerun, but GitHub still lists the result from before it: bounded like the wait above
  ra=$(st_get "$k" ci_rerun_at)
  if [ -n "$ra" ] && [ "$(st_get "$k" ci_rerun)" = "$head" ] && (( $(now) - ra < 600 )) && ! ci_fresh "$pr" "$ra"; then
    log "#$k PR #$pr: failed jobs rerun; waiting for their result"; return 0
  fi
  ci_timeouts_load "$pr"
  f=$(ci_names "$pr"); f=${f:+; failed: $f}
  (( $(fix_max) > 0 )) || { needs_you "$k" "CI is red on PR #$pr$f" "$(run_msg "$k")" "" ci; return; }
  main_merge "$k" "$pr"
  [ "$MERGED" = error ] || st_set "$k" mm_err=
  case $MERGED in
    merged)
      st_set "$k" main_merged="$(guard 20 git -C "$(unit_wt "$k")" rev-parse HEAD 2>/dev/null)" check_at="$(now)"
      log "#$k PR #$pr: CI red; merged main into the branch (no AI run), CI runs again"; return 0 ;;
    conflict)
      # one conflict run per head: one that pushed nothing gets no second try
      [ "$(st_get "$k" conflict_sha)" = "$head" ] && { needs_you "$k" "CI is red on PR #$pr and merging origin/$BASE_BRANCH into it conflicts in: $MERGE_WHY; the worker's merge run pushed no resolution$f" "$(run_msg "$k")" "" ci; return; }
      may_start "$k" || return 0
      resume "$k" "$(conflict_task "$pr" "$MERGE_WHY")" merge || return 0
      st_set "$k" conflict_sha="$head"; return 0 ;;
    error)
      err=$(( $(st_get "$k" mm_err) + 1 ))
      (( err >= 3 )) && { st_set "$k" mm_err=; needs_you "$k" "CI is red on PR #$pr and merging main into it by script failed $err times: $MERGE_WHY$f" "" "" ci; return; }
      st_set "$k" mm_err="$err"; log "#$k PR #$pr: CI red; merging main failed ($MERGE_WHY), again next pass"; return 0 ;;
  esac
  ci_rerun "$k" "$pr" "$head" && return 0
  fix_left "$k" "$pr" || { needs_you "$k" "CI is red on PR #$pr after $(fix_max) automatic fix runs (FIX_ATTEMPTS)$f" "$(run_msg "$k")" "" ci; return; }
  may_start "$k" || return 0
  if [ "$MERGED" = current ]; then task="CI is red on PR #$pr, with $BASE_BRANCH already merged in, so the failure is the PR's. Fix it,"
  else task="CI is red on PR #$pr; $BASE_BRANCH was not merged in by script ($MERGE_WHY). First run git merge origin/$BASE_BRANCH (a normal merge and push, never a rebase or force-push), then fix what is still red,"; fi
  # a timed-out check's log often ends with no failure in it: the run is told what to look for
  to=$(ci_timed_out "$pr")
  if [ -n "$to" ]; then
    [[ $to == *,* ]] && to="$to were cancelled at their own time limit (timed out)" || to="$to was cancelled at its own time limit (timed out)"
    task="$task knowing that $to, so look for what runs too long or hangs,"
  fi
  resume "$k" "$task rerun the checks, push once and stop: the dispatcher watches CI. $(ci_digest "$pr")" ci || return 0
  fix_count "$k" "$pr"
  log "#$k PR #$pr: CI red; fix run $(fixes_used "$k" "$pr") of $(fix_max)$f"
}

# finish_once <K>: a run that ended with work in its worktree but no PR (its turn ended while work
# ran in the background, or before its push) gets one fresh session to push it and open the PR
# before it is needs-you (#26). 1: nothing to finish, or its finish run was had already.
finish_once() {
  local k=$1 wt commits dirty
  [ "$(st_get "$k" finish_tried)" = 1 ] && return 1
  wt=$(unit_wt "$k"); [ -e "$wt/.git" ] || return 1
  commits=$(guard 20 git -C "$wt" log --oneline origin/$BASE_BRANCH..HEAD 2>/dev/null | head -n1)
  dirty=$(guard 20 git -C "$wt" status --porcelain 2>/dev/null | head -n1)
  [ -n "$commits$dirty" ] || return 1
  may_start "$k" || return 0
  # the handoff (its commits, diff stat and uncommitted files) is this session's context, not the whole task again
  st_set "$k" no_pr=
  resume "$k" "Finish: your earlier run ended with work in this worktree and no PR (its turn ended while work ran in the background, or before its push). Run nothing in the background. Commit what is uncommitted, run the tests of the files you changed in the foreground, push the branch and open the PR, ready, with the body the task asks for; then stop: the dispatcher watches CI." finish || return 0
  st_set "$k" finish_tried=1
}

# shellcheck source=canccu-fixbudget.sh
. "$_canccu_lib/canccu-fixbudget.sh"
# shellcheck source=canccu-cidigest.sh
. "$_canccu_lib/canccu-cidigest.sh"
# shellcheck source=canccu-releasered.sh
. "$_canccu_lib/canccu-releasered.sh"
