# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the review brake's trigger and the
# review numbers it is judged on (docs/plan/contracts.md §8, issue #195). Q1 relaxed the reviews;
# when escaped defects (issues and PRs with a `Regression of: #<pr>` line) rise above the
# baseline of the PRs merged before Q1, the brake takes the relaxations back by itself. Its state
# file and the release are in lib/canccu-brakestate.sh.

# below this many PRs merged before Q1 a rate says nothing: no baseline, the trigger stays off
BRAKE_MIN_BASELINE=5

# _merged_prs [before epoch] [from epoch]: the PRs of merged.log, oldest first, each once
_merged_prs() {
  awk -F '\t' -v b="${1:-}" -v a="${2:-}" '$3 ~ /^[0-9]+$/ && (b == "" || $1 < b + 0) && (a == "" || $1 >= a + 0) && !s[$3]++ { print $3 }' \
    "$CANCCU_HOME/merged.log" 2>/dev/null
}
# reviews_start: the epoch of the first reviews.log line, where Q1 began; nothing before it
reviews_start() { iso_epoch "$(head -n 1 "$CANCCU_HOME/reviews.log" 2>/dev/null | cut -f1)"; }
# _count <lines>: the non-empty lines
_count() { grep -c . <<<"$1"; }
# _rate <a> <b>: a per b, two decimals; - when b is 0
_rate() { awk -v a="$1" -v b="$2" 'BEGIN { if (b + 0 == 0) print "-"; else printf "%.2f\n", a / b }'; }

# regressions: "at <epoch>", then "<issue or PR> <the PR it names>" per `Regression of:` line
regressions_file() { echo "$CANCCU_HOME/regressions"; }

# escaped_refresh: reads the open and closed issues and PRs with a `Regression of:` line into the
# regressions file, at most once an hour (GitHub's search API has its own, tighter rate limit). A
# gh error keeps the file as it was and returns 1.
escaped_refresh() {
  local f at i p
  f=$(regressions_file)
  at=$(sed -n '1s/^at //p' "$f" 2>/dev/null)
  [[ $at =~ ^[0-9]+$ ]] && (( $(now) - at < 3600 )) && return 0
  (( CANCCU_DRY )) && return 1
  i=$(ghj issue list -R "$REPO" -s all -L 1000 --search '"Regression of" in:body' --json number,body) &&
    p=$(ghj pr list -R "$REPO" -s all -L 1000 --search '"Regression of" in:body' --json number,body) || {
      log "gh error reading the regressions; the review brake uses the last list"; return 1; }
  # only the #<pr>s right after the label: "Regression of: #12 (see #13)" names #12 alone
  { echo "at $(now)"
    jq -r '.[] | .number as $n | (.body // "") | split("\n")[] | "\($n)\t\(.)"' <<<"$i"$'\n'"$p" 2>/dev/null |
      awk -F '\t' '{ n = $1; t = tolower(substr($0, length($1) + 2)); gsub(/[*_`]/, "", t)
        if (t !~ /^[[:space:]>-]*regression of:/) next
        sub(/^[^:]*:/, "", t)
        while (match(t, /^[[:space:],]*#[0-9]+/)) { s = substr(t, 1, RLENGTH); sub(/^[^#]*#/, "", s); print n "\t" s; t = substr(t, RLENGTH + 1) } }' |
      sort -u -k1,1n -k2,2n; } > "$f.tmp" && mv -f "$f.tmp" "$f" || { log "cannot write $f"; return 1; }
}

# _escaped_of <prs>: the regressions that name one of these PRs
_escaped_of() {
  # shellcheck disable=SC2086  # the list on one line
  awk -F '\t' -v l=" $(echo $1) " 'NR > 1 && index(l, " " $2 " ") { c++ } END { print c + 0 }' "$(regressions_file)" 2>/dev/null || echo 0
}
# _spend_rounds <prs>: the review runs (full reviews and fix-checks: key review-<pr>) of these PRs
# up to their merge, from the spend log: before Q1 there is no reviews.log to count them in. A run
# whose outcome says verdict=none or void (lost, retried) posted nothing: no round, as in reviews.log
_spend_rounds() {
  # shellcheck disable=SC2086
  awk -F '\t' -v l=" $(echo $1) " -v r="$REPO_NAME" '
    FNR == NR { if (index(l, " " $3 " ") && !($3 in at)) at[$3] = $1; next }
    $2 == r && $3 ~ /^review-[0-9]+$/ && $15 !~ /(^|,)verdict=(none|void)(,|$)/ { p = substr($3, 8); if ((p in at) && $1 + 0 <= at[p] + 0) c++ }
    END { print c + 0 }' "$CANCCU_HOME/merged.log" "$WORKERS_DIR/spend.log" 2>/dev/null || echo 0
}

# _baseline_prs: the last BRAKE_WINDOW PRs merged before the first reviews.log line; fails before it
_baseline_prs() {
  local start; start=$(reviews_start); [ -n "$start" ] || return 1
  _merged_prs "$start" | tail -n "${BRAKE_WINDOW:-20}"
}

# brake_baseline: "<time> <escaped/PR> <rounds/PR> <PRs counted>", written once to brake-baseline;
# fails while there is none (no reviews.log yet, fewer than BRAKE_MIN_BASELINE PRs, a gh error)
brake_baseline() {
  local f="$CANCCU_HOME/brake-baseline" prs n l
  [ -s "$f" ] && { head -n 1 "$f"; return 0; }
  prs=$(_baseline_prs) || return 1
  n=$(_count "$prs"); (( n >= BRAKE_MIN_BASELINE )) || return 1
  escaped_refresh || return 1
  l="$(iso "$(now)") $(_rate "$(_escaped_of "$prs")" "$n") $(_rate "$(_spend_rounds "$prs")" "$n") $n"
  (( CANCCU_DRY )) || echo "$l" > "$f" || { log "cannot write $f"; return 1; }
  echo "$l"
}

# brake_tick: once per pass. With REVIEW_BRAKE=auto and no brake on, it engages the brake when the
# escaped defects per merged PR of the last BRAKE_WINDOW merged PRs are above the baseline.
# Nothing here ever releases it: only canccu-dispatcher brake release (rule 7 of the plan). After
# a release it waits until a PR merged after it moves the window (brake-released: the newest then).
brake_tick() {
  local base prs n rate hold=$CANCCU_HOME/brake-released
  [ "${REVIEW_BRAKE:-auto}" = auto ] && ! brake_on && (( ! CANCCU_DRY )) || return 0
  read -r _ base _ _ <<<"$(brake_baseline)"; [ -n "$base" ] || return 0
  prs=$(_merged_prs | tail -n "${BRAKE_WINDOW:-20}"); n=$(_count "$prs"); (( n )) || return 0
  if [ -e "$hold" ]; then [ "$(cat "$hold")" = "${prs##*$'\n'}" ] && return 0; rm -f "$hold"; fi
  escaped_refresh || [ -s "$(regressions_file)" ] || return 0
  rate=$(_rate "$(_escaped_of "$prs")" "$n")
  awk -v a="$rate" -v b="$base" 'BEGIN { exit !(a + 0 > b + 0) }' || return 0
  brake_engage "escaped defects $rate/PR over the last $n merged PRs, baseline $base/PR"
  return 0
}

# brake_engage <trigger>: the brake on, with one feed line for the product owner. Its triggers:
# brake_tick, and a red run of the reviewer's test set (tests/review-set/run, #196).
brake_engage() {
  local text="Review brake on: $1. Reviews block as before Q1 until you run canccu-dispatcher brake release"
  echo "$(iso "$(now)") $1" > "$(brake_file)" || { log "cannot write $(brake_file)"; return 1; }
  feed po ask needs-you - - - "$text" >/dev/null
  log "$text"
}

# review_set_red <cases>: a red run of the review set engages the brake with REVIEW_BRAKE=auto; a
# brake already on keeps its own trigger
review_set_red() {
  [ "${REVIEW_BRAKE:-auto}" = auto ] && ! brake_on && (( ! CANCCU_DRY )) || return 0
  brake_engage "review set missed $1"
}

# brake_effort <effort>: a full review's effort, one step higher while the brake is on; through
# effort_cap either way, so REVIEW_EFFORT_MAX still caps it
brake_effort() {
  local e=$1
  if brake_on; then case $e in low) e=medium ;; medium) e=high ;; high) e=xhigh ;; xhigh) e=max ;; esac; fi
  effort_cap "$e"
}

# brake_status: canccu-status's line: the brake while on; without a baseline, why the trigger is off
brake_status() {
  local prs n
  if brake_on; then echo "brake: $(brake_text)"; return 0; fi
  [ "${REVIEW_BRAKE:-auto}" = auto ] && [ ! -s "$CANCCU_HOME/brake-baseline" ] || return 0
  prs=$(_baseline_prs) || return 0
  n=$(_count "$prs")
  (( n < BRAKE_MIN_BASELINE )) &&
    echo "brake: no baseline ($n PRs merged before the first review-log line, $BRAKE_MIN_BASELINE needed): the escaped-defect trigger is off"
  return 0
}

# _kpi_nums <prs> <escaped known 0|1>: the four review numbers of these PRs from reviews.log: rounds
# (its lines, full and fixcheck) per PR, the blocking classes (in how many verdicts each was left,
# first seen first), the findings demoted (pre-existing but those the brake kept, field 11, and
# moved out of Blocking: for no class, no Evidence:, a never-blocking class or a repeat) and the
# escaped defects per PR
_kpi_nums() {
  local n esc="?" r
  n=$(_count "$1")
  (( $2 )) && esc=$(_rate "$(_escaped_of "$1")" "$n")
  # shellcheck disable=SC2086
  r=$(awk -F '\t' -v l=" $(echo $1) " 'index(l, " " $2 " ") {
      r++; p += $8 - $11; d += $9
      if ($10 != "-" && $10 != "") { m = split($10, c, ","); for (i = 1; i <= m; i++) { if (!(c[i] in k)) o[++no] = c[i]; k[c[i]]++ } }
    }
    END { for (i = 1; i <= no; i++) cls = cls (i > 1 ? ", " : "") o[i] " " k[o[i]]
          printf "%d\t%s\t%d\t%d\n", r, (cls == "" ? "-" : cls), p + d, p; printf "%d\n", d }' "$CANCCU_HOME/reviews.log" 2>/dev/null)
  local rounds cls dem pre out
  IFS=$'\t' read -r rounds cls dem pre <<<"${r%%$'\n'*}"; out=${r##*$'\n'}
  echo "rounds $(_rate "${rounds:-0}" "$n")/PR · blocking by class: ${cls:--} · demoted ${dem:-0} (pre-existing ${pre:-0}, out of Blocking: ${out:-0}) · escaped $esc/PR"
}

# kpi_review_report: canccu-status --kpi-review: one line for the last BRAKE_WINDOW merged PRs, one
# since the baseline (the PRs merged from the first reviews.log line on), one at the baseline
kpi_review_report() {
  local known=1 prs start bt be br bn
  escaped_refresh || [ -s "$(regressions_file)" ] || known=0
  prs=$(_merged_prs | tail -n "${BRAKE_WINDOW:-20}")
  echo "last $(_count "$prs") merged PRs: $(_kpi_nums "$prs" "$known")"
  start=$(reviews_start)
  if [ -n "$start" ]; then prs=$(_merged_prs "" "$start"); echo "since the baseline ($(_count "$prs") merged PRs): $(_kpi_nums "$prs" "$known")"
  else echo "since the baseline: no review-log line yet"; fi
  if read -r bt be br bn < "$CANCCU_HOME/brake-baseline" 2>/dev/null && [ -n "$bn" ]; then
    echo "at the baseline ($bn merged PRs, $bt): rounds $br/PR · blocking by class: - · demoted - · escaped $be/PR"
  else echo "at the baseline: none yet ($BRAKE_MIN_BASELINE PRs merged before the first review-log line are needed)"; fi
}
