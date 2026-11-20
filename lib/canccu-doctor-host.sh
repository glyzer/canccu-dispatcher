# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# canccu-doctor-host.sh — the host report canccu-dispatcher doctor prints after the problems, every
# line starting "host: ": what this host's config decides, and what the last day's runs cost per
# issue, so a repeat run stands out. Sourced after lib/canccu-configcmd.sh (cfg_values).

# _doc_runs <spend.log> <since epoch>: "<issue><TAB><runs><TAB><USD><TAB><runs without a cost>"
# per issue, the most runs first. A review, plan or fix key (review-12) counts for its issue.
_doc_runs() {
  awk -F '\t' -v a="$2" '$1 >= a {
      n = $3; if (match(n, /[0-9]+$/)) n = "#" substr(n, RSTART)
      c[n]++; if ($4 ~ /^[0-9]+(\.[0-9]+)?$/) s[n] += $4; else u[n]++ }
    END { for (n in c) printf "%s\t%d\t%.2f\t%d\n", n, c[n], s[n], u[n] }' "$1" 2>/dev/null |
    sort -t $'\t' -k2,2nr -k1,1
}

# canccu_doctor_host <project or empty>: the report; never fails
canccu_doctor_host() {
  local hp k v base p f since n c s u
  local -A was=()
  hp=$(canccu_host_profile)
  echo "host: profile ${hp:-none (the defaults apply)}"
  # what each key would be without ~/.canccu/config: the defaults and the profile alone
  # (cut: a tab is IFS whitespace, so read would skip an empty value)
  while IFS=$'\t' read -r k v; do was[$k]=$v; done < <(CANCCU_ROOT=/nonexistent CANCCU_HOST_PROFILE=$hp cfg_values "" 2>/dev/null | cut -f1,2)
  while IFS=$'\t' read -r k v; do
    base=${was[$k]-}
    echo "host: $(canccu_tilde "$CANCCU_ROOT")/config sets $k=${v:-(empty)}; ${hp:-the defaults}: ${base:-(empty)}"
  done < <(cfg_values "" 2>/dev/null | awk -F '\t' '$4 == "global" && $1 != "HOST_PROFILE"' | cut -f1,2)
  since=$(( ${CANCCU_NOW:-$(date +%s)} - 86400 ))
  for p in $(canccu_profiles); do
    [ -z "$1" ] || [ "$p" = "$1" ] || continue
    f=$CANCCU_ROOT/projects/$p/workers/spend.log
    [ -n "$(_doc_runs "$f" "$since")" ] || { echo "host: project $p: no runs in the last 24 h"; continue; }
    while IFS=$'\t' read -r n c s u; do
      printf 'host: project %s: %s: %d run%s, $%s%s%s\n' "$p" "$n" "$c" "$([ "$c" = 1 ] || echo s)" "$s" \
        "$([ "$u" = 0 ] || echo " ($u without a cost)")" "$([ "$c" -le 3 ] || echo '; more than 3 runs: look at why it repeats')"
    done < <(_doc_runs "$f" "$since")
  done
  return 0
}
