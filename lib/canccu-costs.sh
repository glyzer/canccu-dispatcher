# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): the cost report per issue and per kind
# (canccu-status --costs) and the digest's cost section. It reads workers/spend.log and merged.log
# and keeps no state of its own. docs/reference/state.md ("The spend log").

# costs_runs <since epoch>: one line per run of this repo that ended since then, tab-separated:
# unit, run type, cost ("?" for a lost run), title. A review or fix-check (key review-<pr>) belongs
# to the unit whose PR merged (merged.log); an answerer (answer-<K>) to K. A unit not merged yet has
# no title here (the log keeps none), so it falls under no kind but "other".
costs_runs() {
  local m="$CANCCU_HOME/merged.log" s="$WORKERS_DIR/spend.log"
  [ -e "$m" ] || m=/dev/null
  [ -e "$s" ] || return 0
  awk -F '\t' -v OFS='\t' -v r="$REPO_NAME" -v since="${1:-0}" '
    FNR == NR { if ($2 != "" && $3 != "") { unit[$3] = $2; title[$2] = $5 } next }
    $2 != r || $1 < since { next }
    {
      k = $3
      if (k ~ /^review-/) { p = substr(k, 8); k = (p in unit) ? unit[p] : "PR " p }
      else if (k ~ /^answer-/) k = substr(k, 8)
      ty = ($5 == "" ? "-" : $5)
      print (k ~ /^[0-9]+$/ ? "#" k : k), ty, $4, (k in title ? title[k] : "")
    }' "$m" "$s"
}

# costs_kinds: COST_KINDS (rules: "<name>=<regex>;<name>=<regex>", grep -iE on the issue title) as
# "<name>\t<regex>" lines; a part with no name, or a regex grep rejects, is said once and skipped,
# so one typo never blanks the whole report
costs_kinds() {
  local part name re rc
  [ -n "${COST_KINDS:-}" ] || return 0
  while IFS= read -r part; do
    name=${part%%=*} re=${part#*=}
    if [ -z "$name" ] || [ "$name" = "$part" ] || [ -z "$re" ]; then warn_once cost-kinds "COST_KINDS: '$part' is not <name>=<regex>; skipped" >&2; continue; fi
    rc=0; grep -iE "$re" </dev/null >/dev/null 2>&1 || rc=$?
    (( rc == 2 )) && { warn_once cost-kinds "COST_KINDS: '$name' is not a valid regex; skipped" >&2; continue; }
    printf '%s\t%s\n' "$name" "$re"
  done < <(tr ';' '\n' <<<"$COST_KINDS")
}

# costs_report [--since DATE] [--top N]: totals by run type, per issue (its fix rounds and cost),
# the N most expensive issues (default 5) and the cost by kind, over the runs since DATE (UTC;
# default all). A lost run (cost "?") is counted apart, so every sum is a lower bound while one is listed.
costs_report() {
  local since=0 top=5 label=all e
  while (( $# )); do
    case $1 in
      --since) e=$(date -u -d "${2:-}" +%s 2>/dev/null) || { echo "canccu-status --costs: --since needs a date (2030-11-01)" >&2; return 2; }
               since=$e label="since $2"; shift 2 ;;
      --top) [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || { echo "canccu-status --costs: --top needs a number" >&2; return 2; }
             top=$2; shift 2 ;;
      *) echo "usage: canccu-status --costs [--since DATE] [--top N]" >&2; return 2 ;;
    esac
  done
  local runs; runs=$(costs_runs "$since")
  [ -n "$runs" ] || { echo "costs ($label): no runs in the spend log"; return 0; }
  KINDS=$(costs_kinds) awk -F '\t' -v label="$label" -v top="$top" '
    function money(v) { return sprintf("$%.2f", v) }
    BEGIN { nk = split(ENVIRON["KINDS"], kl, "\n"); for (i = 1; i <= nk; i++) { split(kl[i], kp, "\t"); kname[i] = kp[1]; kre[i] = tolower(kp[2]) } }
    {
      u = $1; ty = $2; c = $3; n++
      if (!(u in ucost)) { order[++nu] = u; ucost[u] = 0 }
      if (!(ty in tcost)) { tord[++nt] = ty; tcost[ty] = 0 }
      if (c ~ /^[0-9]+(\.[0-9]+)?$/) { ucost[u] += c; tcost[ty] += c; total += c } else { lost++; ulost[u]++ }
      truns[ty]++
      if (ty == "fix") rounds[u]++
      if ($4 != "") utitle[u] = $4
    }
    END {
      printf "costs (%s) · %s · %d run%s%s\n", label, money(total), n, (n == 1 ? "" : "s"), (lost ? sprintf(" (%d lost, so at least)", lost) : "")
      print "by run type:"
      for (i = 1; i <= nt; i++) printf "  %-10s %4d run%s  %9s\n", tord[i], truns[tord[i]], (truns[tord[i]] == 1 ? " " : "s"), money(tcost[tord[i]])
      # one pass of selection per output line: the lists are short
      for (i = 1; i <= nu; i++) done[order[i]] = 0
      printf "most expensive (top %d):\n", top
      for (j = 1; j <= top && j <= nu; j++) {
        best = ""
        for (i = 1; i <= nu; i++) if (!done[order[i]] && (best == "" || ucost[order[i]] > ucost[best])) best = order[i]
        done[best] = 1
        printf "  %-8s %9s  %d fix round%s  %s\n", best, money(ucost[best]), rounds[best] + 0, (rounds[best] == 1 ? "" : "s"), utitle[best]
      }
      for (i = 1; i <= nu; i++) {
        u = order[i]; k = "other"; t = tolower(utitle[u])
        for (q = 1; q <= nk; q++) if (kname[q] != "" && t ~ kre[q]) { k = kname[q]; break }
        if (!(k in kcost)) { kord[++nkk] = k; kcost[k] = 0 }
        kcost[k] += ucost[u]; kn[k]++
      }
      print "by kind:"
      for (i = 1; i <= nkk; i++) printf "  %-16s %4d issue%s  %9s\n", kord[i], kn[kord[i]], (kn[kord[i]] == 1 ? " " : "s"), money(kcost[kord[i]])
    }' <<<"$runs"
}

# costs_digest: the digest's section: today's (24 h) cost by kind, and a line per issue with more
# fix rounds than COST_ROUNDS_ALERT in that time ("PR #N: 7 rounds, $X"; 0: no such line). Nothing
# when no run ended today.
costs_digest() {
  local runs alert=${COST_ROUNDS_ALERT:-5}
  [[ $alert =~ ^[0-9]+$ ]] || alert=5
  runs=$(costs_runs $(( $(now) - 86400 )))
  [ -n "$runs" ] || return 0
  KINDS=$(costs_kinds) awk -F '\t' -v alert="$alert" '
    BEGIN { nk = split(ENVIRON["KINDS"], kl, "\n"); for (i = 1; i <= nk; i++) { split(kl[i], kp, "\t"); kname[i] = kp[1]; kre[i] = tolower(kp[2]) } }
    $4 != "" { title[$1] = $4 }
    { if (!($1 in uc)) { ord[++nu] = $1; uc[$1] = 0 }
      if ($3 ~ /^[0-9]+(\.[0-9]+)?$/) { uc[$1] += $3; total += $3 }
      if ($2 == "fix") rounds[$1]++ }
    END {
      for (i = 1; i <= nu; i++) {
        u = ord[i]; k = "other"; t = tolower(title[u])
        for (q = 1; q <= nk; q++) if (kname[q] != "" && t ~ kre[q]) { k = kname[q]; break }
        if (!(k in kc)) { kord[++nkk] = k; kc[k] = 0 }
        kc[k] += uc[u]
      }
      s = ""
      for (i = 1; i <= nkk; i++) s = s (s == "" ? "" : ", ") kord[i] " " sprintf("$%.2f", kc[kord[i]])
      printf "**Cost today:** %s total (%s)\n", sprintf("$%.2f", total), s
      if (alert > 0) for (i = 1; i <= nu; i++) if (rounds[ord[i]] > alert) printf "- %s: %d rounds, $%.2f\n", ord[i], rounds[ord[i]], uc[ord[i]]
    }' <<<"$runs"
}
