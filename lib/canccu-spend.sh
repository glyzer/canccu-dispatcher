# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the spend log's outcome column and the
# cost-per-merged-PR report. The engine writes each run's line when the run ends
# (libexec/canccu-worker, spend_line); what came of the run (its PR, CI, the verdict) is known only
# when the dispatcher reaps it, so spend_note fills that in afterwards. docs/reference/engine.md.

# spend_note <key> <since epoch> <k=v>...: set fields of the outcome column (15) of the key's newest
# spend.log line that ended since then; a field already there is replaced. No such line (a run
# that never wrote one, or one from before this format): nothing changes. The file is rewritten
# whole under .spend.lock, which the engine's append holds too, so no line is lost in between.
spend_note() {
  local key=$1 since=${2:-0} f="$WORKERS_DIR/spend.log" tmp; shift 2
  (( CANCCU_DRY )) && return 0
  [ -s "$f" ] && (( $# )) || return 0
  tmp="$f.tmp.$$"
  ( flock -w 10 6 || exit 1
    awk -F '\t' -v OFS='\t' -v r="$REPO_NAME" -v k="$key" -v a="$since" -v kv="$*" '
      { line[NR] = $0 } $2 == r && $3 == k && $1 >= a { last = NR }
      END {
        if (!last) exit 3
        for (i = 1; i <= NR; i++) {
          if (i == last) {
            n = split(line[i], c, "\t")
            for (j = n + 1; j <= 15; j++) c[j] = "-"
            if (n < 15) n = 15
            o = (c[15] == "-" || c[15] == "") ? "" : c[15]
            m = split(kv, add, " ")
            for (p = 1; p <= m; p++) {
              f = add[p]; sub(/=.*/, "", f)
              no = ""; q = split(o, have, ",")
              for (h = 1; h <= q; h++) if (have[h] != "" && index(have[h], f "=") != 1) no = no (no == "" ? "" : ",") have[h]
              o = no (no == "" ? "" : ",") add[p]
            }
            c[15] = o; s = c[1]
            for (j = 2; j <= n; j++) s = s OFS c[j]
            line[i] = s
          }
          print line[i]
        }
      }' "$f" > "$tmp" && mv "$tmp" "$f"
    rc=$?; rm -f "$tmp"; exit $(( rc == 3 ? 0 : rc ))
  ) 6>>"$WORKERS_DIR/.spend.lock"
}

# fix_rounds <K>: the fix runs of the unit in spend.log so far (the review's findings, a needs-work)
fix_rounds() {
  awk -F '\t' -v r="$REPO_NAME" -v k="$1" '$2 == r && $3 == k && $5 == "fix" { n++ } END { print n + 0 }' \
    "$WORKERS_DIR/spend.log" 2>/dev/null || echo 0
}

# findings_count <review file> → "<blocking> <non-blocking>": the top-level list items (1. / 1) /
# - / *) before a "Non-blocking" line, and after it. An estimate: it counts what the reviewer
# listed, the way the prompt asks it to list findings; no file → "0 0".
findings_count() {
  awk 'BEGIN { b = 0; n = 0; nb = 0 }
       /^[[:space:]*_#]*Non-blocking/ { nb = 1; next }
       /^[[:space:]*_]*(Review verdict|Maintainer accept|Risk):/ { next }
       /^([0-9]+[.)]|[-*])[[:space:]]/ { if (nb) n++; else b++ }
       END { print b, n }' "$1" 2>/dev/null || echo "0 0"
}

# spend_review_note <K> <pr> <review file> <sha> <since>: a review's or fix-check's outcome: its
# verdict (none without a valid one), its findings and the unit's fix rounds so far
spend_review_note() {
  local v b nb; v=$(file_verdict "$3" "$4"); read -r b nb <<<"$(findings_count "$3")"
  [ -e "$3" ] && (( $(stat -c %Y "$3") >= $5 )) || { v="" b=0 nb=0; }
  spend_note "review-$2" "$5" "verdict=${v:-none}" "blocking=$b" "nonblocking=$nb" "rounds=$(fix_rounds "$1")"
}

# spend_report: the cost of every merged PR (merged.log): every run of its unit (the worker's
# build, fix and merge runs, lost ones too), its reviews and fix-checks (review-<pr>) and its
# answerers (answer-<unit>), grouped by model and run type; then the same over all merged PRs. A
# lost run (cost "?": stopped, stalled, crashed, killed) is counted apart, so a sum is a lower
# bound while one is listed. Lines from before the extra columns count as model and type "-".
spend_report() {
  local m="$CANCCU_HOME/merged.log" s="$WORKERS_DIR/spend.log"
  [ -s "$m" ] || { echo "no merged PR yet (${m/#$HOME/\~})"; return 0; }
  [ -e "$s" ] || s=/dev/null
  awk -F '\t' -v r="$REPO_NAME" '
    function add(g, key, cost) {
      runs[g, key]++; if (!((g, key) in usd)) usd[g, key] = 0
      if (cost ~ /^[0-9]+(\.[0-9]+)?$/) usd[g, key] += cost; else lost[g, key]++
      if (!((g, key) in seen)) { seen[g, key] = 1; keys[g] = keys[g] SUBSEP key }
    }
    function show(g, title,   list, nk, i, k, t, tl, tr, part) {
      nk = split(substr(keys[g], 2), list, SUBSEP)
      t = 0; tl = 0; tr = 0
      for (i = 1; i <= nk; i++) { k = list[i]; t += usd[g, k]; tl += lost[g, k]; tr += runs[g, k] }
      printf "%s · $%.2f · %d run%s%s\n", title, t, tr, (tr == 1 ? "" : "s"), (tl ? sprintf(" (%d lost, so at least)", tl) : "")
      for (i = 1; i <= nk; i++) {
        k = list[i]; split(k, part, "|")
        printf "  %-24s %-10s %3d run%s  $%8.2f%s\n", (part[1] == "-" ? "(default)" : part[1]), part[2],
          runs[g, k], (runs[g, k] == 1 ? " " : "s"), usd[g, k], (lost[g, k] ? sprintf("  %d lost", lost[g, k]) : "")
      }
    }
    FNR == NR { if ($2 == "" || $3 == "") next; np++; unit[np] = $2; pr[np] = $3; at[np] = $1; title[np] = $5; next }
    $2 == r { L[++nl] = $0 }
    END {
      for (p = 1; p <= np; p++) {
        fixes = 0
        for (i = 1; i <= nl; i++) {
          split(L[i], c, "\t")
          if (c[1] > at[p]) continue
          if (c[3] != unit[p] && c[3] != "review-" pr[p] && c[3] != "answer-" unit[p]) continue
          ty = (c[5] == "" ? "-" : c[5]); mo = (c[6] == "" ? "-" : c[6])
          if (ty == "fix") fixes++
          add(p, mo "|" ty, c[4]); add("all", mo "|" ty, c[4])
        }
        if (keys[p] == "") { printf "PR #%s (#%s %s) · no runs in the spend log\n", pr[p], unit[p], title[p]; continue }
        show(p, sprintf("PR #%s (#%s %s) · %d fix round%s", pr[p], unit[p], title[p], fixes, (fixes == 1 ? "" : "s")))
      }
      if (keys["all"] != "") { print ""; show("all", sprintf("all %d merged PR%s", np, (np == 1 ? "" : "s"))) }
    }' "$m" "$s" 2>/dev/null
}
