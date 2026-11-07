# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by lib/canccu-snapshot.sh; never run: the schema-2 parts of the status snapshot: the
# steps with their package plans, the step packages in the queue, the usage throttle.
# The schema is in docs/canccu-dispatch.md, "Status snapshot".

# snap_packages <m>: the current plan's packages with their state (JSON array)
snap_packages() {
  local m=$1 f nm is rk dep k s pr out
  f=$(step_get "$m" plan); [ -f "$f" ] || { echo null; return 0; }
  while IFS=$'\t' read -r nm is rk dep; do
    [ -n "$nm" ] || continue
    k=$(package_key "$m" "$nm" "$is"); s=$(package_status "$m" "$nm"); pr=""
    case $s in
      running) s=$(pkg_stage "$k"); pr=$(st_get "$k" pr) ;;
      needs-you) pr=$(st_get "$k" pr) ;;
      merged) pr=$(awk -F '\t' -v k="$k" '$1 == k { p = $6 } END { print p }' "$CANCCU_HOME/steps/$m.packages" 2>/dev/null) ;;
    esac
    jq -nc --argjson f "$(jq -c --arg n "$nm" '.packages[] | select(.name == $n)' "$f")" --arg k "$k" --arg s "$s" --arg pr "$pr" \
      --arg br "$(is_managed "$k" && unit_branch "$k")" --arg re "$(is_managed "$k" && risk_max "$(st_get "$k" risk)" "$(st_get "$k" review_risk)")" \
      '$f + {key: $k, state: $s, pr: ($pr | tonumber? // null), branch: (if $br == "" then (if ($k | startswith("pkg-")) then $k else null end) else $br end),
             risk_effective: (if $re == "" then $f.risk else $re end)}'
  done < <(plan_packages "$m") | jq -sc --argjson w "$(step_get "$m" wave)" --arg at "$(step_get "$m" plan_at)" --arg lo "$(step_get "$m" left_out)" \
    '{wave: $w, at: ($at | tonumber? // null), left_out: ($lo | split(" ") | map(select(. != "") | tonumber)), packages: .}'
}

# snap_steps: {"steps": [...], "current_step": <m>|null}: each step that is current, or not done
# with a state file, in milestone order
snap_steps() {
  local m cur_ids sp nc hs hp
  cur_ids=" $(current_step_ids | tr '\n' ' ') "
  step_list | jqr '.[] | "\(.milestone)\t\(.title)\t\(.track)\t\(.checkpoint.issue // "")\t\(.checkpoint.state // "")\t\(.epic // "")"' |
    while IFS=$'\t' read -r m t tr ci cs ep; do
      [[ $cur_ids == *" $m "* ]] || { [ -f "$CANCCU_HOME/steps/$m" ] && [ "$(step_get "$m" phase)" != "done" ]; } || continue
      read -r sp nc <<<"$(step_spend "$m")"
      hs=$(step_get "$m" health); hp=$(step_get "$m" health_pr)
      case $hs in "") hs=$( [ "$(cur "$m" .work_open)" = 0 ] && echo pending || echo n/a ) ;; esac
      is_managed "pkg-$m-health" && hp=$(st_get "pkg-$m-health" pr)
      jq -nc --argjson m "$m" --arg t "$t" --arg tr "$tr" --argjson cur "$([[ $cur_ids == *" $m "* ]] && echo true || echo false)" \
        --arg ph "$(step_get "$m" phase)" --arg w "$(step_get "$m" wave)" --arg ep "${ep:-$(step_get "$m" epic)}" \
        --arg err "$(step_get "$m" ny_reason)" --arg ci "${ci:-$(step_get "$m" checkpoint)}" --arg cs "$cs" \
        --arg sp "$sp" --arg nc "$nc" --arg lim "$STEP_BUDGET" --argjson over "$(step_over_budget "$m" && echo true || echo false)" \
        --argjson plan "$(snap_packages "$m")" --arg hs "$hs" --arg hp "$hp" \
        --argjson notes "$(nf=$CANCCU_HOME/steps/$m.notes; [ -f "$nf" ] || nf=/dev/null   # no notes file yet: no notes
                           jq -Rn '[inputs | split("\t") | {at: (.[0] | tonumber? // null), kind: .[1], pr: (.[2] | tonumber? // null), text: .[3]}]' \
                             < "$nf" 2>/dev/null || echo '[]')" \
        '{milestone: $m, title: $t, track: $tr, current: $cur, phase: (if $ph == "" then "idle" else $ph end),
          wave: ($w | tonumber? // 0), epic: ($ep | tonumber? // null), error: (if $err == "" then null else $err end),
          checkpoint: (if $ci == "" then null else {issue: ($ci | tonumber), state: (if $cs == "" then "open" else $cs end),
                       waiting: ($ph == "checkpoint")} end),
          budget: {usd: ($sp | tonumber * 100 | round / 100), limit: ($lim | tonumber), runs_without_cost: ($nc | tonumber), over: $over},
          plan: $plan, health: {state: $hs, key: "pkg-\($m)-health", pr: ($hp | tonumber? // null)}, notes: $notes}'
    done | jq -sc --arg c "$(jqr '[.[] | select(.track == "main")][0].milestone // empty' <<<"$CURRENT_STEPS")" \
      '{steps: ., current_step: ($c | tonumber? // null)}'
}

# snap_step_queue: the current steps' packages not started yet, in plan order (queue lane "step")
snap_step_queue() {
  local m nm is rk dep s why
  for m in $(current_step_ids); do
    [ "$(step_get "$m" phase)" = running ] || continue
    while IFS=$'\t' read -r nm is rk dep; do
      s=$(package_status "$m" "$nm"); why=""
      case $s in pending) step_over_budget "$m" && why="step budget reached" ;; blocked) why="depends on ${dep// /, }" ;; *) continue ;; esac
      jq -nc --arg n "${is%% *}" --arg k "$(package_key "$m" "$nm" "$is")" --arg t "package $nm (${is// /, })" --arg why "$why" \
        '{issue: ($n | tonumber), title: $t, blocked: ($why != ""), waits_on: (if $why == "" then null else $why end), lane: "step", package: $k}'
    done < <(plan_packages "$m")
  done
}

# snap_usage: the usage shares and the throttle
snap_usage() {
  local f w r wr at; read -r f w r wr at <<<"$(usage_read)"
  jq -nc --arg f "$f" --arg w "$w" --arg r "$r" --arg wr "$wr" --arg at "$at" --arg st "$(usage_state)" --arg tx "$(usage_text)" \
    '{five_hour: ($f | tonumber? // null), seven_day: ($w | tonumber? // null), resets_at: ($r | tonumber? // null),
      weekly_resets_at: ($wr | tonumber? // null), at: ($at | tonumber? // null), state: $st, text: $tx}'
}

# ---------------------------------------------------------------- the step overview

# blockers_known <n>: issue n's open blockers without a new GitHub read: this pass's read when it
# made one, else its "Blocked by #k" lines (the next step's issues: no read per issue per pass)
blockers_known() {
  local c=${BLOCKERS_CACHE:-}
  if [ -n "$c" ] && [ -f "$c/$1" ]; then cat "$c/$1"; else blockers_in_body "$1"; fi
  return 0
}

# issue_own_status <n> <labels "a,b"> [peek]: "<status>[\t<what it waits on>]" of an open issue
# outside the step's plan: running, accept, needs-you, ready, or blocked with the reason. With
# peek, its blockers come from blockers_known (no GitHub read).
issue_own_status() {
  local n=$1 l=",$2," u b
  u=$(unit_of_issue "$n")
  if is_managed "$u"; then
    case $(st_get "$u" phase) in
      accept) echo accept ;; needs-you|question) echo needs-you ;;
      limited) printf 'blocked\tthe usage limit\n' ;; stopped) printf 'blocked\tstopped (canccu-run continues it)\n' ;;
      *) echo running ;;
    esac
    return 0
  fi
  case $l in
    *,needs-you,*) echo needs-you; return 0 ;; *,awaiting-accept,*) echo accept; return 0 ;;
    *,in-progress,*) echo running; return 0 ;;
  esac
  [[ $l == *,blocked,* ]] && { printf 'blocked\tlabelled blocked\n'; return 0; }
  [[ $l == *,ready,* ]] || { printf 'blocked\tno ready label\n'; return 0; }
  if [ "${3:-}" = peek ]; then b=$(blockers_known "$n"); else b=$(blockers_open "$n"); fi
  b=$(sort -u <<<"$b" | tr '\n' ' '); b=${b% }
  [ -n "${b// }" ] && { printf 'blocked\tblocked by %s\n' "$b"; return 0; }
  echo ready
}

# snap_step_issues <m> [peek]: one JSON line per open work issue of step m (no epic, no checkpoint),
# by number: issue, title, url, status (done, running, accept, needs-you, ready, blocked), waits_on,
# package (its key in the current plan, or null). An issue of the plan has its package's status.
# peek (the next step): no GitHub read for an issue's blockers (issue_own_status).
snap_step_issues() {
  local m=$1 peek=${2:-} nm is rk dep k s why n title labels st
  local -A pst=() pwhy=() pkey=()
  while IFS=$'\t' read -r nm is rk dep; do
    [ -n "$nm" ] || continue
    k=$(package_key "$m" "$nm" "$is"); s=$(package_status "$m" "$nm"); why=""
    case $s in
      merged|closed) s="done" ;;
      running) case $(pkg_stage "$k") in accept) s=accept ;; needs-you) s=needs-you ;; *) s=running ;; esac ;;
      needs-you) ;;
      pending) s=ready ;;
      blocked) why="depends on ${dep// /, }" ;;
      *) s="" ;;   # refused: the issue's own status
    esac
    for n in $is; do pst[$n]=$s pwhy[$n]=$why pkey[$n]=$k; done
  done < <(plan_packages "$m")
  jqr --arg t "$(step_title "$m")" '.[] | select((.milestone.title // null) == $t)
        | select([.labels[].name] | (index("epic") or index("checkpoint")) | not)
        | [.number, (.title | gsub("[\t\n]"; " ")), ([.labels[].name] | join(","))] | @tsv' <<<"$ISSUES" | sort -n |
    while IFS=$'\t' read -r n title labels; do
      st=${pst[$n]:-} why=${pwhy[$n]:-}
      [ -n "$st" ] || IFS=$'\t' read -r st why <<<"$(issue_own_status "$n" "$labels" "$peek")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$title" "$st" "$why" "${pkey[$n]:-}"
    done | jq -Rc --arg r "$REPO" 'split("\t") | {issue: (.[0] | tonumber), title: .[1], url: "https://github.com/\($r)/issues/\(.[0])",
        status: .[2], waits_on: (if .[3] == "" then null else .[3] end), package: (if .[4] == "" then null else .[4] end)}'
}

# snap_step_overview: every open milestone in milestone order (the monitor's step view):
# milestone, title, track, place (done, current, next, later), work_open, work_closed (without
# epics and checkpoints), issues (snap_step_issues; only for the current steps and the next one)
snap_step_overview() {
  local list m out=""
  list=$(jq -c --arg cur " $(current_step_ids | tr '\n' ' ') " '
    ($cur | split(" ") | map(select(. != "") | tonumber)) as $c
    | ([.[] | select(.track == "main") | .milestone]) as $main
    | ([$main | to_entries[] | select(.value | IN($c[])) | .key] | first) as $ci
    | (if $ci == null then null else $main[$ci + 1] end) as $next
    | map(.milestone as $m | ([$main | to_entries[] | select(.value == $m) | .key] | first) as $i
          | {milestone, title, track, work_open, work_closed: ([.work_closed, 0] | max),
             place: (if ($m | IN($c[])) then "current"
                     elif .track == "main" and $ci != null then (if $i < $ci then "done" elif $m == $next then "next" else "later" end)
                     elif .pending or .work_closed <= 0 then "later" else "done" end)})' <<<"$(step_list)") || return 1
  while read -r m place; do
    [ -n "$m" ] || continue
    out+="$(snap_step_issues "$m" "$([ "$place" = next ] && echo peek)" | jq -sc --argjson m "$m" '{key: ($m | tostring), value: .}')"$'\n'
  done < <(jqr '.[] | select(.place == "current" or .place == "next") | "\(.milestone) \(.place)"' <<<"$list")
  jq -c --argjson is "$(jq -sc 'from_entries' <<<"$out")" 'map(.issues = ($is[.milestone | tostring] // []))' <<<"$list"
}
