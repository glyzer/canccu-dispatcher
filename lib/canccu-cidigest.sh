# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by lib/canccu-followup.sh, never run): the failure digest
# of a red CI's failing jobs, built by script (no AI), for a CI fix run's task and a release-red's
# comments. The real failures sit far above a log's tail, under compose logs and teardown: a fix
# run given only the tail re-reads the whole log on expensive turns.

# lines of no failure that a digest never shows, neither as a match nor as a line after one:
# docker compose's per-container output and lifecycle lines, Actions' group ends and cleanup, and
# its "##[error]Process completed with exit code 1.", which names no failure.
# A compose line "web-1 | Error: …" is the app's noise, not the check's failure.
CI_DIGEST_NOISE='^[A-Za-z0-9_.-]+-[0-9]+ +\| |^ *(Container|Network|Volume) [^ ]+ +(Creat|Start|Stop|Remov|Kill|Wait|Healthy|Running|Exited)|^##\[endgroup\]|^##\[error\].*exit code|^Post job cleanup|^Cleaning up orphan processes|^Terminate orphan process'
# a test runner's or linter's summary line: kept on its own, first in its job's block, so the cap
# never cuts it (it comes last in the log)
CI_DIGEST_SUMMARY='^ *(Test Files|Tests|Suites) +.*[0-9]+ failed|✖ [0-9]+ problems?|^ *[0-9]+ (failing|failed)([^a-z]|$)'

# ci_log_clean: a job log (stdin) as gh run view --log-failed prints it, without the "<job>\t<step>\t"
# columns, the timestamp, ANSI colour codes, carriage returns and the noise; each line cut to 300
# characters (a minified bundle's line would fill the digest alone). Where the step changes, a
# "##[group]" line (as Actions starts each step's command) marks the boundary for ci_log_digest.
ci_log_clean() {
  awk -F'\t' '{ l = $0; if (NF >= 3) { st = $2; sub(/^[^\t]*\t[^\t]*\t/, "", l) }
                if (NR > 1 && st != prev) print "##[group]"; prev = st; print l }' |
    sed -E $'s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//; s/\x1b\\[[0-9;?]*[A-Za-z]//g; s/\r//g' |
    grep -vE -- "$CI_DIGEST_NOISE" | cut -c1-300
}

# ci_log_digest <max lines>: the failure lines of a cleaned log (stdin): its summary lines, then
# each line CI_DIGEST_PATTERN matches with its next 8 lines, in the log's order, no line twice and
# no blank one; the lines after a match end where a step's command starts ("##[group]": the next
# step is teardown, not the failure). Empty when nothing matches or CI_DIGEST_PATTERN is empty (the
# caller falls back to the tail).
ci_log_digest() {
  local max=$1 log hits sums
  log=$(cat)
  [ -n "${CI_DIGEST_PATTERN:-}" ] || return 0
  hits=$(grep -nE -- "$CI_DIGEST_PATTERN" <<<"$log" | cut -d: -f1)
  sums=$(grep -nE -- "$CI_DIGEST_SUMMARY" <<<"$log" | cut -d: -f1)
  [ -n "$hits$sums" ] || return 0
  awk -v hits="$hits" -v sums="$sums" -v max="$max" '
    BEGIN { n = split(hits, h, "\n"); for (i = 1; i <= n; i++) hit[h[i]] = 1
            m = split(sums, s, "\n"); for (i = 1; i <= m; i++) sum[s[i]] = 1 }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^##\[group\]/) left = 0
        else if (i in hit) { keep[i] = 1; left = 8 }
        else if (left > 0) { keep[i] = 1; left-- }
      }
      for (i = 1; i <= NR && out < max; i++) if (i in sum && !(line[i] in seen)) { seen[line[i]] = 1; print line[i]; out++ }
      for (i = 1; i <= NR && out < max; i++) {
        if (!(i in keep) || line[i] ~ /^[ \t]*$/ || (line[i] in seen)) continue
        seen[line[i]] = 1; print line[i]; out++
      }
    }' <<<"$log"
}

# ci_digest_jobs: the digest of the failing jobs named on stdin ("<name>\t<job id>\t<url>" per
# line), each job's log read once, into DIGEST (not run in $(…)): one block per job under
# "== <name> (<url>) ==", the job's failure lines or, where none matched, the tail of its log
# (CI_LOG_LINES, the tail a fix run was given before the digest). At most CI_DIGEST_LINES lines in
# all, shared out among the jobs, so a second job's failures are not cut by the first's. DIGEST is
# empty when no log could be read; DIGEST_MATCHED=1 when a job's lines matched.
ci_digest_jobs() {
  local jobs name jid url log d n cap per out=""
  jobs=$(awk -F'\t' '$2 != ""')
  DIGEST="" DIGEST_MATCHED=0
  [ -n "$jobs" ] || return 0
  cap=${CI_DIGEST_LINES:-120}; [[ $cap =~ ^[0-9]+$ ]] && (( cap >= 4 )) || cap=120
  n=$(wc -l <<<"$jobs"); per=$(( cap / n )); (( per >= 2 )) || per=2
  while IFS=$'\t' read -r name jid url; do
    log=$(ghj run view --job "$jid" -R "$REPO" --log-failed 2>/dev/null | ci_log_clean)
    [ -n "$log" ] || continue
    d=$(ci_log_digest $(( per - 1 )) <<<"$log")
    if [ -n "$d" ]; then DIGEST_MATCHED=1
    else d=$(grep -vx '##\[group\]' <<<"$log" | tail -n "${CI_LOG_LINES:-60}" | tail -n $(( per - 1 ))); fi
    out+="== $name${url:+ ($url)} =="$'\n'"$d"$'\n'
  done <<<"$jobs"
  [ -n "$out" ] && DIGEST=$(head -n "$cap" <<<"${out%$'\n'}")
  return 0
}

# ci_digest <pr>: what a CI fix run is given of the PR's red CI: the digest of every failing GitHub
# Actions job, under its name (ci_digest_jobs); with no log read, how to read them
ci_digest() {
  local pr=$1 what
  ci_digest_jobs < <(ci_failed "$pr" | awk -F'\t' -v r="$REPO" '$4 != "" { print $2 "\t" $4 "\thttps://github.com/" r "/actions/runs/" $1 "/job/" $4 }')
  if [ -z "$DIGEST" ]; then
    printf 'Read the failing checks with gh pr checks %s -R %s and their logs with gh run view --log-failed.' "$pr" "$REPO"; return
  fi
  if (( DIGEST_MATCHED )); then what="CI gave this failure digest of the failing jobs (built by script: the lines matching CI_DIGEST_PATTERN with the lines after them, a log's tail where none matched)"
  else what="No line of the failing jobs' logs matched CI_DIGEST_PATTERN; the tail of each"; fi
  # the lines stay apart: the task is one line, and a failure block read as one run-on line is lost
  printf '%s, lines separated by ⏎: %s' "$what" "$(oneline 12000 "${DIGEST//$'\n'/ ⏎ }")"
}
