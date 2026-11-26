# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): release-reds. A project's own release
# workflow files an issue labelled RELEASE_RED_LABEL ("release red at <sha7>") when CI on
# BASE_BRANCH is red; most are flaky checks or a registry or runner fault, which cost a worker's
# whole investigation. The dispatcher reruns the failed jobs at that commit once (no AI run) and
# only a red rerun leaves the issue as work. The project's workflow and its tagging stay as they
# are: the next green push tags as usual.
#
# Per issue, release-red/<n> (key=value) holds rr: rerun (the failed runs rerun, waiting), ordinary
# (work as any issue: red again, or nothing to rerun) or closed (green: closed by the dispatcher);
# rr_runs "<run id>:<attempt>" pairs, rr_at, rr_sha and rr_infra (the first run's infrastructure
# error line). release-red/<n>.jobs and .digest keep the first run's failed jobs and their digest.

rr_file() { echo "$CANCCU_HOME/release-red/$1"; }
rr_get() { kv_get "$(rr_file "$1")" "@rr$1" "$2"; }
rr_set() { local n=$1; shift; kv_set "$(rr_file "$n")" "@rr$n" "$@"; }

# release_red_issues: this pass's open issues labelled RELEASE_RED_LABEL (none when it is empty)
release_red_issues() {
  [ -n "${RELEASE_RED_LABEL:-}" ] || return 0
  jqr --arg l "$RELEASE_RED_LABEL" '.[] | select(any(.labels[]; .name == $l)) | .number' <<<"$ISSUES"
}
# release_red_held <n>: a release-red whose rerun has not decided yet: not taken as work
release_red_held() {
  [ -n "${RELEASE_RED_LABEL:-}" ] || return 1
  [ "$(jqr --argjson n "$1" --arg l "$RELEASE_RED_LABEL" '[.[] | select(.number == $n) | .labels[].name] | index($l) != null' <<<"$ISSUES")" = true ] || return 1
  [ "$(rr_get "$1" rr)" != ordinary ]
}

# release_red_sha <n>: the full SHA the issue names: its title's "release red at <sha7>", else the
# first 40-hex word of its body, resolved on GitHub (gh run list --commit wants the full SHA)
release_red_sha() {
  local s
  s=$(jqr --argjson n "$1" '.[] | select(.number == $n) | ((.title | capture("release red at (?<s>[0-9a-f]{7,40})\\b").s)
      // ((.body // "") | capture("\\b(?<s>[0-9a-f]{40})\\b").s) // empty)' <<<"$ISSUES" | head -n1)
  [ -n "$s" ] || return 0
  ghj api "repos/$REPO/commits/$s" -q .sha 2>/dev/null | grep -xE '[0-9a-f]{40}'
}

# release_red_tick: each open release-red takes its next step; nothing here starts an AI run, so it
# runs paused or backing off too
release_red_tick() {
  local n
  for n in $(release_red_issues); do
    case $(rr_get "$n" rr) in
      "") release_red_start "$n" ;;
      rerun) release_red_judge "$n" ;;
    esac
  done
}

# release_red_start <n>: the failed runs at the issue's SHA on BASE_BRANCH, their failed jobs'
# digest kept (and whether the first run's logs name an infrastructure error), then their failed
# jobs rerun once. No SHA, no failed run, or no rerun that starts: logged, and it is ordinary work.
release_red_start() {
  local n=$1 sha runs id att ids="" d
  sha=$(release_red_sha "$n")
  [ -n "$sha" ] || { log "#$n release-red: no commit SHA found in the issue; it stays an ordinary issue"; rr_set "$n" rr=ordinary; return 0; }
  runs=$(ghj run list -R "$REPO" --commit "$sha" --branch "$BASE_BRANCH" -L 50 --json databaseId,conclusion,attempt 2>/dev/null |
    jqr '.[] | select(.conclusion == "failure" or .conclusion == "timed_out") | "\(.databaseId) \(.attempt // 1)"')
  [ -n "$runs" ] || { log "#$n release-red: no failed run at ${sha:0:7} on $BASE_BRANCH; it stays an ordinary issue"; rr_set "$n" rr=ordinary rr_sha="$sha"; return 0; }
  d=$(rr_file "$n"); (( CANCCU_DRY )) || mkdir -p "${d%/*}"
  while read -r id _; do
    ghj run view "$id" -R "$REPO" --json jobs 2>/dev/null |
      jqr '.jobs[]? | select(.conclusion == "failure" or .conclusion == "timed_out") | [.name, (.databaseId | tostring), (.url // "")] | @tsv'
  done <<<"$runs" > "$d.jobs.tmp"
  ci_digest_jobs < "$d.jobs.tmp"
  if (( ! CANCCU_DRY )); then mv "$d.jobs.tmp" "$d.jobs"; printf '%s\n' "$DIGEST" > "$d.digest"; else rm -f "$d.jobs.tmp"; fi
  while read -r id att; do
    if mut_out gh run rerun "$id" --failed -R "$REPO"; then ids+=" $id:$att"
    else log "#$n release-red: rerun of run $id failed ($(oneline 200 "$MUT_OUT"))"; fi
  done <<<"$runs"
  if [ -z "$ids" ]; then
    log "#$n release-red: no rerun started at ${sha:0:7}; it stays an ordinary issue"
    rr_set "$n" rr=ordinary rr_sha="$sha"; return 0
  fi
  rr_set "$n" rr=rerun rr_runs="${ids# }" rr_at="$(now)" rr_sha="$sha" rr_infra="$(oneline 200 "$DIGEST_INFRA")"
  log "#$n release-red: failed jobs at ${sha:0:7} rerun once (runs${ids//:[0-9]*/}); not taken as work until they end${DIGEST_INFRA:+ (an infrastructure error)}"
}

# release_red_judge <n>: the rerun runs once they have all ended (a newer attempt, completed):
# green → closed (a flaky check gets its flaky: issue; an infrastructure error files nothing),
# red → ordinary work with a comment. Not ended after CI_WAIT_MIN → ordinary, said so.
release_red_judge() {
  local n=$1 r id att v st c a green=1 sha
  sha=$(rr_get "$n" rr_sha)
  for r in $(rr_get "$n" rr_runs); do
    id=${r%%:*} att=${r#*:}
    v=$(ghj run view "$id" -R "$REPO" --json status,conclusion,attempt 2>/dev/null | jqr '"\(.status) \(.conclusion // "") \(.attempt // 1)"') || v=""
    read -r st c a <<<"$v"
    # right after the rerun GitHub may still show the first attempt's result
    if [ "$st" != completed ] || ! [[ ${a:-0} =~ ^[0-9]+$ ]] || (( a <= att )); then
      (( $(now) - $(rr_get "$n" rr_at) < CI_WAIT_MIN * 60 )) && return 0
      release_red_ordinary "$n" "The rerun of its failed jobs at \`${sha:0:7}\` did not end within $CI_WAIT_MIN minutes (CI_WAIT_MIN)."
      return 0
    fi
    [ "$c" = success ] || green=0
  done
  if (( ! green )); then
    release_red_ordinary "$n" "The dispatcher reran the failed jobs at \`${sha:0:7}\` once: red again, so this is no flaky check."
  elif [ -n "$(rr_get "$n" rr_infra)" ]; then
    release_red_close "$n" "The dispatcher reran the failed jobs at \`${sha:0:7}\` once: green. The first run failed on an infrastructure error, not the code: \`$(rr_get "$n" rr_infra)\`. Nothing is filed; the next green push tags as usual."
  else release_red_flaky "$n"; fi
}

# release_red_ordinary <n> <why>: red again (or no result): the issue stays as ordinary work, with
# the first run's digest
release_red_ordinary() {
  local n=$1 body=$2 d
  d=$(cat "$(rr_file "$n").digest" 2>/dev/null)
  [ -n "$d" ] && body+=$'\n\nThe failure digest of the first run:\n\n```\n'"$d"$'\n```'
  mut gh issue comment "$n" -R "$REPO" --body "$(home_tilde "$body")"$'\n\n'"$CANCCU_MARK"
  rr_set "$n" rr=ordinary
  log "#$n release-red: $(oneline 160 "$2") It stays an ordinary issue"
}

# release_red_close <n> <comment>: green after the rerun: said on the issue and closed
release_red_close() {
  mut gh issue comment "$1" -R "$REPO" --body "$(home_tilde "$2")"$'\n\n'"$CANCCU_MARK" &&
    mut gh issue close "$1" -R "$REPO" || { log "#$1 release-red: closing it failed (gh); again next pass"; return 0; }
  rr_set "$1" rr=closed
  log "#$1 release-red: rerun green; closed ($(oneline 120 "$2"))"
}

# release_red_flaky <n>: green after the rerun, no infrastructure error: each failed check of the
# first run goes to its flaky: issue, and the release-red is closed with links to them
release_red_flaky() {
  local n=$1 name jid url f links="" sha runs=""
  sha=$(rr_get "$n" rr_sha)
  for f in $(rr_get "$n" rr_runs); do runs+=" https://github.com/$REPO/actions/runs/${f%%:*}"; done
  while IFS=$'\t' read -r name jid url; do
    [ -n "$name" ] || continue
    [[ $links == *"\`flaky: $name\`"* ]] && continue
    flaky_file "$name" "$n" "$sha" "${url:-${runs# }}" "${runs# }" || { log "#$n release-red: filing flaky: $name failed (gh); again next pass"; return 0; }
    links+="${links:+, }#$FLAKY_NO (\`flaky: $name\`)"
  done < "$(rr_file "$n").jobs"
  [ -n "$links" ] || links="no failed job could be read"
  release_red_close "$n" "The dispatcher reran the failed jobs at \`${sha:0:7}\` once: green, so the failure was a flaky check: $links. The next green push tags as usual."
}

# FLAKY_SEEN: per check, "<issue>\t<count>" of a flaky: issue filed or counted in this pass, which
# the pass's issue list does not show yet
declare -gA FLAKY_SEEN=()
# flaky_file <check> <release-red n> <sha> <job url> <run urls>: open or update the one issue
# "flaky: <check>": its body's "Failures: <n>" line counts the failures, a comment per failure
# has the job, the runs and the failing lines. It gets `ready` once the count reaches
# FLAKY_FILE_AFTER (candidates puts it at the end of the queue). Its number goes to FLAKY_NO (not run
# in $(…): FLAKY_SEEN must outlive the call).
flaky_file() {
  local check=$1 n=$2 sha=$3 job=$4 runs=$5 t="flaky: $1" i="" c=0 body d note
  d=$(awk -v h="== $check " 'index($0, h) == 1 { on = 1; next } /^== / { on = 0 } on' "$(rr_file "$n").digest" 2>/dev/null)
  note="Failed at \`${sha:0:7}\` on \`$BASE_BRANCH\` (release-red #$n), green on a rerun at the same commit. Job: $job. Runs: $runs."
  [ -n "$d" ] && note+=$'\n\nThe failing lines:\n\n```\n'"$d"$'\n```'
  if [ -n "${FLAKY_SEEN[$check]:-}" ]; then IFS=$'\t' read -r i c <<<"${FLAKY_SEEN[$check]}"
  else
    IFS=$'\t' read -r i c < <(jqr --arg t "$t" '[.[] | select(.title == $t)][0] // empty
      | "\(.number)\t\((.body // "") | capture("(?m)^Failures: (?<c>[0-9]+)").c // "0")"' <<<"$ISSUES")
  fi
  c=$(( ${c:-0} + 1 ))
  body="The check \`$check\` failed on \`$BASE_BRANCH\` and passed when the dispatcher reran it at the same commit: a flaky check. Each failure is a comment below.

Failures: $c

It gets \`ready\` from $FLAKY_FILE_AFTER failures (FLAKY_FILE_AFTER)."
  if [ -z "$i" ]; then
    mut_out gh issue create -R "$REPO" --title "$t" --body "$body"$'\n\n'"$CANCCU_MARK" || return 1
    i=$(grep -oE '/issues/[0-9]+' <<<"$MUT_OUT" | grep -oE '[0-9]+$' | tail -1)
    (( CANCCU_DRY )) && i=${i:-0}
    [ -n "$i" ] || return 1
  else
    mut gh issue edit "$i" -R "$REPO" --body "$body"$'\n\n'"$CANCCU_MARK" || return 1
  fi
  mut gh issue comment "$i" -R "$REPO" --body "$(home_tilde "$note")"$'\n\n'"$CANCCU_MARK"
  (( c >= ${FLAKY_FILE_AFTER:-2} )) && mut gh issue edit "$i" -R "$REPO" --add-label ready
  FLAKY_SEEN[$check]="$i"$'\t'"$c"
  FLAKY_NO=$i
  log "#$n release-red: flaky: $check is #$i (failure $c)"
}
