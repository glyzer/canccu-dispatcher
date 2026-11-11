# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by canccu-dispatch after canccu-common.sh; never run: the steps (milestones, in order).
# One step runs at a time on the main track (plus Parallel tracks beside it): a planner bundles
# its ready issues into packages, wave by wave; at its end a health pass, then a checkpoint pause.
# State: steps/<m> (m: the milestone number). docs/canccu-dispatch.md, "Work packages per step".

MILESTONES='[]' CHECKPOINTS='[]' CURRENT_STEPS='[]' STEPS_OK=0

# fetch_steps: the pass's two reads for steps (open milestones; issues labelled checkpoint, open
# or closed), then the current steps. A failed read: STEPS_OK=0 and no step acts this pass.
fetch_steps() {
  STEPS_OK=0 CURRENT_STEPS='[]'
  MILESTONES=$(ghj api "repos/$REPO/milestones?state=open&per_page=100") &&
    CHECKPOINTS=$(ghj issue list -R "$REPO" -s all -l checkpoint -L 200 --json number,title,state,milestone,labels) ||
    { MILESTONES='[]' CHECKPOINTS='[]'; return 1; }
  CURRENT_STEPS=$(current_steps_pure "$MILESTONES" "$CHECKPOINTS" "$ISSUES" "$(step_phases)") || { CURRENT_STEPS='[]'; return 1; }
  STEPS_OK=1
}

# step_phases: {"<m>": "<phase>"} of every step with a state file
step_phases() {
  local f m
  { for f in "$CANCCU_HOME"/steps/*; do
      m=${f##*/}; [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] && printf '%s\t%s\n' "$m" "$(step_get "$m" phase)"
    done; } | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries'
}

# STEP_JQ: per open milestone, in milestone order: its track, work issues open and closed, epic,
# checkpoint (the open one, else the newest closed one) and whether it is pending. Its values come
# by --slurpfile (step_jq), each one as [value]
STEP_JQ="$MILESTONE_KEY_JQ"'
  def work: [.labels[]?.name] | (index("epic") or index("checkpoint")) | not;
  [ $ms[0][] | select(.number != null) | .title as $t
    | ([ $is[0][] | select((.milestone.title // null) == $t) ]) as $mine
    | ([ $cps[0][] | select((.milestone.title // null) == $t) ]) as $cp
    | { milestone: .number, title: $t, k: ($t | milestone_key),
        track: (if ($t | test("^\\s*parallel tracks\\b"; "i")) then "parallel" else "main" end),
        work_open: ([ $mine[] | select(work) ] | length),
        work_closed: ((.closed_issues // 0) - ([ $cp[] | select(.state == "CLOSED") ] | length)),
        epic: ([ $mine[] | select(any(.labels[]?; .name == "epic")) | .number ] | sort | first),
        checkpoint: (([ $cp[] | select(.state == "OPEN") ] | sort_by(.number) | first)
                     // ([ $cp[] ] | sort_by(.number) | last)
                     | if . == null then null else {issue: .number, state: (.state | ascii_downcase)} end),
        phase: ($ph[0][(.number | tostring)] // null) }
    | .pending = (.work_open > 0 or (.checkpoint.state == "open")
                  or (.phase | IN("planning", "running", "health-due", "health", "checkpoint", "needs-you"))) ]
  | sort_by(.k, .title) | map(del(.k))'

# current_steps_pure <milestones> <checkpoints> <open issues> <step phases> → the current steps:
# the first pending main-track milestone, then Parallel tracks when it is pending. Earlier steps
# are not pending, so their checkpoints are closed: a step waiting for its checkpoint-ok stays
# current, which is the pause.
current_steps_pure() {
  step_jq "$1" "$2" "$3" "$4" '
    | ([ .[] | select(.track == "main" and .pending) ] | .[:1]) + [ .[] | select(.track == "parallel" and .pending) ]
    | map(del(.pending))'
}
# step_list: every open milestone with its step data (for the snapshot), in milestone order
step_list() { step_jq "$MILESTONES" "$CHECKPOINTS" "$ISSUES" "$(step_phases)"; }
# step_jq <milestones> <checkpoints> <open issues> <step phases> [filter]: STEP_JQ, then the
# filter. The values go in as files: the open issues alone can pass the 128 KiB Linux allows one
# command-line argument (MAX_ARG_STRLEN), and jq would not start
step_jq() {
  jq -c -n --slurpfile ms <(printf '%s' "$1") --slurpfile cps <(printf '%s' "$2") --slurpfile is <(printf '%s' "$3") \
    --slurpfile ph <(printf '%s' "$4") "$STEP_JQ${5:-}"
}
current_step_ids() { jqr '.[].milestone' <<<"$CURRENT_STEPS"; }
# cur <m> <jq path>: a field of a current step
cur() { jqr --argjson m "$1" ".[] | select(.milestone == \$m) | $2" <<<"$CURRENT_STEPS"; }
# step_of_issue <n>: the milestone number of an open issue, or nothing
step_of_issue() {
  local t; t=$(jqr --argjson n "$1" '.[] | select(.number == $n) | .milestone.title // empty' <<<"$ISSUES")
  [ -n "$t" ] && jqr --arg t "$t" '.[] | select(.title == $t) | .number' <<<"$MILESTONES"
  return 0
}
# step_title <m>
step_title() { local t; t=$(jqr --argjson m "$1" '.[] | select(.number == $m) | .title' <<<"$MILESTONES"); echo "${t:-$(step_get "$1" title)}"; }
step_track() { cur "$1" .track; }
# step_order <m>: the milestone's place in the order (MILESTONE_KEY_JQ)
step_order() { jqr --argjson m "$1" "$MILESTONE_KEY_JQ"'.[] | select(.number == $m) | .title | milestone_key' <<<"$MILESTONES"; }

# step_init <m>: the step's state, made the first time it is current; epic and checkpoint kept fresh
step_init() {
  local m=$1 e c
  [ -n "$(step_get "$m" phase)" ] || { step_set "$m" phase=idle started_at="$(now)" wave=0; log "step $(step_title "$m") is current"; }
  e=$(cur "$m" '.epic // empty'); c=$(cur "$m" '.checkpoint.issue // empty')
  step_set "$m" title="$(step_title "$m")" track="$(step_track "$m")" ${e:+epic="$e"} ${c:+checkpoint="$c"}
}

# ---------------------------------------------------------------- spend and the step budget

# step_spend <m> → "<usd> <runs without a cost>": the exact costs in workers/spend.log of the
# step's runs (steps/<m>.keys) since the step started
step_spend() {
  local s; s=$(step_get "$1" started_at)
  [ -s "$CANCCU_HOME/steps/$1.keys" ] || { echo "0.00 0"; return 0; }
  awk -F '\t' -v a="${s:-0}" -v r="$REPO_NAME" 'FNR == NR { k[$1] = 1; next }
    $1 >= a && $2 == r && ($3 in k) { if ($4 ~ /^[0-9]+(\.[0-9]+)?$/) s += $4; else u++ }
    END { printf "%.2f %d\n", s, u }' "$CANCCU_HOME/steps/$1.keys" "$WORKERS_DIR/spend.log" 2>/dev/null || echo "0.00 0"
}
step_over_budget() { awk -v s="$(step_spend "$1" | cut -d' ' -f1)" -v b="${STEP_BUDGET:-400}" 'BEGIN { exit !(s >= b) }'; }
# step_blocked_to_start <m>: no new run of the step starts (its budget, the weekly drain)
step_blocked_to_start() { step_over_budget "$1" || draining; }
# step_of_unit <K>: the step a unit's runs are charged to (none for a fast-lane or old unit)
step_of_unit() { is_managed "$1" && st_get "$1" step; return 0; }
# unit_held <K>: step_run_held without saying so: the unit's step is at STEP_BUDGET
unit_held() { local m; m=$(step_of_unit "$1"); [ -n "$m" ] && step_over_budget "$m"; }
# step_run_held <K> <what>: the unit's step is at STEP_BUDGET: its run (a review, fix-check,
# answer or resume) does not start (said once); the weekly drain never holds these: started
# work finishes
step_run_held() {
  unit_held "$1" || return 1
  local m; m=$(step_of_unit "$1")
  warn_once "held-$1" "#$1: $2 held: step $(step_title "$m") reached STEP_BUDGET"
}
# step_charge <K> <run key>: the run is the unit's step's (its budget)
step_charge() { local m; m=$(step_of_unit "$1"); [ -n "$m" ] && step_key "$m" "$2"; return 0; }

# step_ny_clear <m>: drop the epic's needs-you once no cause is left (plan, blockers, budget)
step_ny_clear() {
  local m=$1 i; i=$(step_issue "$m")
  [ "$(step_get "$m" phase)" = needs-you ] || [ -n "$(step_get "$m" xblock_ny)" ] || [ -n "$(step_get "$m" budget_ny)" ] && return 0
  [ -n "$i" ] && has_label "$i" needs-you && edit_issue "$i" --remove-label needs-you
  return 0
}
budget_tick() {
  local m=$1 i sp; i=$(step_issue "$m")
  if step_over_budget "$m"; then
    [ -n "$(step_get "$m" budget_ny)" ] && return 0
    sp=$(step_spend "$m" | cut -d' ' -f1)
    step_set "$m" budget_ny=1
    log "step $(step_title "$m") reached STEP_BUDGET (\$$sp of \$$STEP_BUDGET): no new run of it starts$(its_url "$( [ -n "$i" ] && issue_url "$i")")"
    [ -n "$i" ] || return 0
    edit_issue "$i" --add-label needs-you
    comment_issue "$i" "**Needs you** (canccu-dispatch): step $(step_title "$m") reached STEP_BUDGET (\$$sp of \$$STEP_BUDGET). Running work finishes; nothing new of this step starts. Raise STEP_BUDGET in the project config to go on."
  elif [ -n "$(step_get "$m" budget_ny)" ]; then
    step_set "$m" budget_ny=; log "step $(step_title "$m") is under STEP_BUDGET again"; step_ny_clear "$m"
  fi
}

# ---------------------------------------------------------------- cross-step blockers

# cross_step_blocks <m>: "<n> <x> <milestone of x>" for each open work issue of the step blocked
# by an open issue of a later step: the step would wait for it forever
cross_step_blocks() {
  local m=$1 t o n x mx
  t=$(step_title "$m"); o=$(step_order "$m")
  for n in $(jqr --arg t "$t" '.[] | select((.milestone.title // null) == $t)
               | select([.labels[].name] | (index("epic") or index("checkpoint")) | not) | .number' <<<"$ISSUES"); do
    for x in $(blockers_open "$n" | grep -E '^[0-9]+$' | sort -u); do
      mx=$(step_of_issue "$x"); [ -n "$mx" ] && [ "$mx" != "$m" ] || continue
      awk -v a="$(step_order "$mx")" -v b="$o" 'BEGIN { exit !(a > b) }' && echo "$n $x $mx"
    done
  done
}
# xblock_tick <m>: needs-you on the epic, one comment per new pair; the label goes once none is left
xblock_tick() {
  local m=$1 f="$CANCCU_HOME/steps/$1.xblock" pairs n x mx i
  pairs=$(cross_step_blocks "$m"); i=$(step_issue "$m")
  if [ -z "$pairs" ]; then
    [ -n "$(step_get "$m" xblock_ny)" ] && { step_set "$m" xblock_ny=; (( CANCCU_DRY )) || rm -f "$f"; step_ny_clear "$m"; }
    return 0
  fi
  while read -r n x mx; do
    grep -qx "$n $x" "$f" 2>/dev/null && continue
    (( CANCCU_DRY )) || { mkdir -p "${f%/*}" && echo "$n $x" >> "$f"; }
    log "step $(step_title "$m") waits on #$x in step $(step_title "$mx") (it blocks #$n)$(its_url "$( [ -n "$i" ] && issue_url "$i")")"
    [ -n "$i" ] || continue
    has_label "$i" needs-you || edit_issue "$i" --add-label needs-you
    comment_issue "$i" "**Needs you** (canccu-dispatch): step $(step_title "$m") waits on #$x in step $(step_title "$mx"): it blocks #$n. Move one of them so the step can finish."
  done <<<"$pairs"
  step_set "$m" xblock_ny=1
}

# ---------------------------------------------------------------- waves

# package_key <m> <name> <issues "a b">: <n> for a package of one, else pkg-<m>-<name>
package_key() { if [[ $3 =~ ^[0-9]+$ ]]; then echo "$3"; else echo "pkg-$1-$2"; fi; }
# plan_packages <m>: "<name>\t<issues>\t<risk>\t<depends on>" per package of the current plan
plan_packages() {
  local f; f=$(step_get "$1" plan); [ -f "$f" ] || return 0
  jqr '.packages[] | [.name, (.issues | map(tostring) | join(" ")), .risk, ((.depends_on // []) | join(" "))] | @tsv' "$f"
}
# package_status <m> <name>: merged, closed (its issues closed without a merged PR), needs-you,
# running, refused (an issue of it is not eligible now: closed, not ready, managed, blocked, …;
# never started), pending (every dependency merged) or blocked. Final: merged, closed, refused.
package_status() {
  local m=$1 nm=$2 line k d i out
  line=$(plan_packages "$m" | awk -F '\t' -v n="$nm" '$1 == n'); [ -n "$line" ] || { echo unknown; return; }
  k=$(package_key "$m" "$nm" "$(cut -f2 <<<"$line")")
  if is_managed "$k" && [ "$(st_get "$k" step)" = "$m" ]; then
    [ "$(st_get "$k" phase)" = needs-you ] && echo needs-you || echo running; return
  fi
  # the package of this wave (a later wave never reuses a name: plan validation)
  out=$(awk -F '\t' -v k="$k" -v n="$nm" '$1 == k && $2 == n { o = $7 } END { print o }' "$CANCCU_HOME/steps/$m.packages" 2>/dev/null)
  case $out in merged|closed) echo "$out"; return ;; esac
  for i in $(cut -f2 <<<"$line"); do eligible_issue "$m" "$i" || { echo refused; return; }; done
  for d in $(cut -f4 <<<"$line"); do [ "$(package_status "$m" "$d")" = merged ] || { echo blocked; return; }; done
  echo pending
}
# wave_over <m>: no package of the wave runs or could start: all merged, waiting for the user's
# accept or needs-you, or behind one (a waiting package holds only its dependants)
wave_over() {
  local s k
  while IFS=$'\t' read -r _ s _ _ k; do
    case $s in
      pending) return 1 ;;
      running) [ "$(st_get "$k" phase)" = accept ] || return 1 ;;
    esac
  done < <(plan_states "$1")
  return 0
}
# wave_can_start <m>: a package of the current plan could start now (pending)
wave_can_start() { plan_states "$1" | cut -f2 | grep -qx pending; }
# plan_states <m>: "<name>\t<status>\t<live 1|0>\t<issues>\t<unit key>" per package of the current plan, one
# package_status each. Live: unfinished and able to run still: running (an accept or needs-you
# included), pending, or blocked while every dependency not merged is live too. A package behind
# a closed, refused or unknown one is not live: its issues are released to the next planner.
plan_states() {
  local nm is d ch order=()
  local -A st=() deps=() iss=() live=()
  while IFS=$'\t' read -r nm is _ d; do
    [ -n "$nm" ] || continue
    order+=("$nm"); st[$nm]=$(package_status "$1" "$nm"); deps[$nm]=$d iss[$nm]=$is
    case ${st[$nm]} in running|needs-you|pending|blocked) live[$nm]=1 ;; *) live[$nm]=0 ;; esac
  done < <(plan_packages "$1")
  ch=1
  while (( ch )); do
    ch=0
    for nm in "${order[@]}"; do
      [ "${st[$nm]}" = blocked ] && [ "${live[$nm]}" = 1 ] || continue
      for d in ${deps[$nm]}; do
        [ "${st[$d]:-unknown}" = merged ] || [ "${live[$d]:-0}" = 1 ] || { live[$nm]=0; ch=1; break; }
      done
    done
  done
  for nm in "${order[@]}"; do printf '%s\t%s\t%s\t%s\t%s\n' "$nm" "${st[$nm]}" "${live[$nm]}" "${iss[$nm]}" "$(package_key "$1" "$nm" "${iss[$nm]}")"; done
}
# held_issues <m>: the issues of the current plan's live packages not started yet (pending or
# blocked): they run in this plan or the next, so no planner is ever handed them
held_issues() {
  plan_states "$1" | awk -F '\t' '$3 == 1 && ($2 == "pending" || $2 == "blocked") { gsub(" ", "\n", $4); print $4 }'
}
# carried_packages <m>: the current plan's live packages (JSON array), each marked with the wave it
# was planned in (carried_from), its depends_on cut to the other live ones (every dependency of a
# live package is merged or live): the next wave's plan carries them. Fails on an unreadable plan.
carried_packages() {
  local f w live; f=$(step_get "$1" plan); [ -n "$f" ] && [ -f "$f" ] || { echo '[]'; return 0; }
  w=$(step_get "$1" wave)
  live=" $(plan_states "$1" | awk -F '\t' '$3 == 1 { printf "%s ", $1 }')"
  jq -ce --arg live "$live" --argjson w "${w:-0}" '
    def live($n): $live | contains(" \($n) ");
    [.packages[] | select(live(.name)) | .carried_from //= $w | .depends_on = ((.depends_on // []) | map(select(live(.))))]' "$f"
}

# step_unit_finished <K> <PR state> <pr> <PR body>: a package or the health pass ended (from finish_unit)
step_unit_finished() {
  local k=$1 m; m=$(st_get "$k" step); [ -n "$m" ] || return 0
  collect_notes "$m" "$3" "$4"
  if is_health "$k"; then
    [ "$2" = MERGED ] && step_set "$m" health=merged health_pr="$3"
    return 0
  fi
  (( CANCCU_DRY )) || printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$(st_get "$k" pkg)" "$(st_get "$k" wave)" "$(st_get "$k" members)" \
    "$(st_get "$k" risk)" "$3" "$([ "$2" = MERGED ] && echo merged || echo closed)" >> "$CANCCU_HOME/steps/$m.packages"
}

# ---------------------------------------------------------------- notes for the lead

# collect_notes <m> <pr> <PR body>: Follow-up: and Roadmap note: lines, kept once per text
collect_notes() {
  local m=$1 pr=$2 f="$CANCCU_HOME/steps/$1.notes" kind text key
  [ -n "$3" ] && (( ! CANCCU_DRY )) || return 0
  mkdir -p "${f%/*}"
  while IFS=$'\t' read -r kind text; do
    [ -n "$text" ] || continue
    key=$(tr '[:upper:]' '[:lower:]' <<<"$text" | tr -s ' \t' ' ')
    awk -F '\t' -v k="$kind" -v t="$key" '$2 == k && tolower($4) == t { f = 1 } END { exit !f }' "$f" 2>/dev/null && continue
    printf '%s\t%s\t%s\t%s\n' "$(now)" "$kind" "$pr" "$(tr -s ' \t' ' ' <<<"$text")" >> "$f"
  done < <(sed -nE 's/\r//; s/^[[:space:]>*_-]*(Follow-up|Roadmap note)[*_]*:[*_]*[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1\t\2/p' <<<"$3" |
             sed -E 's/^Follow-up/follow-up/; s/^Roadmap note/roadmap/')
}
# notes_tick <m>: the notes of the step's open package PRs
notes_tick() {
  local m=$1 k pr
  for k in $(managed); do
    [ "$(st_get "$k" step)" = "$m" ] || continue
    pr=$(st_get "$k" pr); [ -n "$pr" ] && pr_is_open "$pr" && collect_notes "$m" "$pr" "$(pr_get "$pr" '.body // ""')"
  done
  return 0
}

# digest_steps: one line per current step; digest_notes: the notes of the last 24 h, by step
digest_steps() {
  local m sp
  (( STEPS_OK )) || return 0
  for m in $(current_step_ids); do
    sp=$(step_spend "$m" | cut -d' ' -f1)
    echo "- $(step_title "$m") · $(step_get "$m" phase) · wave $(step_get "$m" wave) · \$$sp of \$$STEP_BUDGET$( [ -n "$(step_get "$m" checkpoint)" ] && echo " · checkpoint #$(step_get "$m" checkpoint)")"
  done
}
digest_notes() {
  local f m
  for f in "$CANCCU_HOME"/steps/*.notes; do
    [ -f "$f" ] || continue; m=${f##*/}; m=${m%.notes}
    awk -F '\t' -v s=$(( $(now) - 86400 )) -v t="$(step_get "$m" title)" '$1 >= s { printf "- %s · %s: %s (PR #%s)\n", t, $2, $4, $3 }' "$f"
  done
}

# ---------------------------------------------------------------- health pass and checkpoint

# health_due <m>: every work issue of the step is closed, some work was done, no health pass yet
health_due() {
  [ "$(cur "$1" .work_open)" = 0 ] && (( $(cur "$1" .work_closed) > 0 )) && [ -z "$(step_get "$1" health)" ]
}
# label_by_user <issue|pr> <label> <since epoch>: its newest such label event is USER_LOGIN's, after then
label_by_user() {
  local e; e=$(ghj api --paginate "repos/$REPO/issues/$1/events" |
    jqr -s --arg l "$2" '[.[][] | select(.event == "labeled" and .label.name == $l)] | last
      | select(. != null) | "\(.actor.login // "") \(.created_at)"') || return 1
  [ -n "$e" ] && [ "${e%% *}" = "$USER_LOGIN" ] && [ "${e%% *}" != "$REVIEWER_LOGIN" ] &&
    [[ ${e#* } > "$(iso "${3:-0}")" ]]
}
# checkpoint_summary <m>: the checkpoint comment
checkpoint_summary() {
  local m=$1 sp nc
  read -r sp nc <<<"$(step_spend "$m")"
  printf '**Checkpoint** for step %s (canccu-dispatch)\n\n**Packages**\n' "$(step_title "$m")"
  local k nm w is rk pr out
  while IFS=$'\t' read -r k nm w is rk pr out; do
    [ -n "$k" ] && printf -- '- %s (%s risk): %s · PR #%s · %s\n' "$nm" "$rk" "$(sed -E 's/([0-9]+)/#\1/g; s/ /, /g' <<<"$is")" "$pr" "$out"
  done < "$CANCCU_HOME/steps/$m.packages" 2>/dev/null
  printf '\n**Health pass:** %s\n\n**Spend:** $%s of STEP_BUDGET $%s%s\n\n' \
    "$(case $(step_get "$m" health) in skipped) echo "nothing to do" ;; closed) echo "PR #$(step_get "$m" health_pr) closed without merging" ;;
         *) echo "PR #$(step_get "$m" health_pr)" ;; esac)" \
    "$sp" "$STEP_BUDGET" "$( (( nc > 0 )) && echo " (+$nc runs without a reported cost)")"
  printf '**Roadmap notes**\n%s\n\n**Follow-ups**\n%s\n\n' \
    "$(awk -F '\t' '$2 == "roadmap" { printf "- %s (PR #%s)\n", $4, $3 }' "$CANCCU_HOME/steps/$m.notes" 2>/dev/null | grep . || echo none)" \
    "$(awk -F '\t' '$2 == "follow-up" { printf "- %s (PR #%s)\n", $4, $3 }' "$CANCCU_HOME/steps/$m.notes" 2>/dev/null | grep . || echo none)"
  echo "Label this issue \`checkpoint-ok\` or close it to start the next step."
}
# health_labels_clear <K>: the health pass is finished. Its labels live on the step's issue
# (lead_of): awaiting-accept is only ever its own; its needs-you goes unless the step has a cause
# of its own (step_ny_clear) or it is the checkpoint waiting for checkpoint-ok.
health_labels_clear() {
  local k=$1 m i; m=$(st_get "$k" step) i=$(lead_of "$k")
  [ -n "$i" ] || return 0
  has_label "$i" awaiting-accept && edit_issue "$k" --remove-label awaiting-accept
  [ "$(st_get "$k" phase)" = needs-you ] || return 0
  [ "$(step_get "$m" phase)" = checkpoint ] && [ "$i" = "$(step_get "$m" checkpoint)" ] && return 0
  step_ny_clear "$m"
}
# health_pr_closed <m>: the health pass's PR was closed without merging: the health pass ends
# (closed), its unit is finished, and the checkpoint follows; the lead decides there
health_pr_closed() {
  local m=$1 k="pkg-$1-health" pr st
  is_managed "$k" && [ "$(step_get "$m" health)" = running ] || return 0
  pr=$(st_get "$k" pr); [ -n "$pr" ] && ! pr_is_open "$pr" || return 0
  st=$(ghj pr view "$pr" -R "$REPO" --json state -q .state) || return 0
  [ "$st" = CLOSED ] || return 0
  step_set "$m" health=closed health_pr="$pr"; st_set "$k" skipped=1
  log "#$k: PR #$pr was closed without merging; the health pass ends and the checkpoint follows"
  step_ny_clear "$m"
}
# waiting_checkpoints: "<issue> <m>" for each step m that waits for checkpoint-ok on its checkpoint
waiting_checkpoints() {
  local f m c
  for f in "$CANCCU_HOME"/steps/*; do
    m=${f##*/}; [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] && [ "$(step_get "$m" phase)" = checkpoint ] || continue
    c=$(step_get "$m" checkpoint); [ -n "$c" ] && echo "$c $m"
  done
  return 0
}
# checkpoint_tick <m>: after the health pass: needs-you and the summary on the checkpoint; then wait
# for checkpoint-ok (the user's label) or its close
checkpoint_tick() {
  local m=$1 c st ph u; c=$(cur "$m" '.checkpoint.issue // empty'); st=$(cur "$m" '.checkpoint.state // empty')
  ph=$(step_get "$m" phase)
  if [ "$ph" = health ]; then
    health_pr_closed "$m"
    case $(step_get "$m" health) in merged|skipped|closed) ;; *) return 0 ;; esac
    if [ -z "$c" ] || [ "$st" = closed ]; then step_done "$m" "it has no open checkpoint, so it skips the checkpoint pause"; return 0; fi
    edit_issue "$c" --add-label needs-you
    # the summary's link: the monitor's needs-you item and this line end with it
    comment_issue_url "$c" "$(checkpoint_summary "$m")"; u=$COMMENT_URL
    step_set "$m" phase=checkpoint checkpoint_at="$(now)" checkpoint_url="$u"
    log "step $(step_title "$m"): checkpoint #$c waits for checkpoint-ok$(its_url "${u:-$(issue_url "$c")}")"; return 0
  fi
  [ "$ph" = checkpoint ] || return 0
  [ -n "$c" ] || { step_done "$m" "its checkpoint is gone, so the pause ends"; return 0; }
  if [ "$st" != closed ]; then
    jqr --argjson c "$c" '.[] | select(.number == $c) | .labels[].name' <<<"$CHECKPOINTS" | grep -qx checkpoint-ok || return 0
    label_by_user "$c" checkpoint-ok "$(step_get "$m" checkpoint_at)" ||
      { warn_once "cpok-$c" "step $(step_title "$m"): checkpoint-ok on #$c was not added by $USER_LOGIN after the summary; ignored"; return 0; }
    # the step is done only once the close went through: else the next pass tries again
    mut gh issue close "$c" -R "$REPO" --comment "Checkpoint OK: step $(step_title "$m") is done. $CANCCU_MARK" ||
      { log "step $(step_title "$m"): closing checkpoint #$c failed; retrying next pass"; return 0; }
  fi
  mut gh issue edit "$c" -R "$REPO" --remove-label needs-you
  step_done "$m" "checkpoint #$c OK"
}
# step_done <m> <why>: the step is done (done_at: from now on, new open work or an open
# checkpoint in it is the lead's, see step_stop_reason); its epic closes when its sub-issues are;
# its planner's worktree goes
step_done() {
  local wt; wt=$(plan_wt "$1")
  step_set "$1" phase=done done_at="$(now)"
  log "step $(step_title "$1") is done: $2"
  [ -e "$wt" ] && { mut git -C "$CLONE" worktree remove --force "$wt" || log "step $1: cannot remove the planner worktree $wt"; }
  close_step_epic "$1"
}
# close_step_epic <m>: close the step's epic once its step is done and every sub-issue is closed
# (close_epics leaves a step's epic open until then: it is where the step talks to the lead)
close_step_epic() {
  local e subs; e=$(step_get "$1" epic)
  [ -n "$e" ] && _issue_open "$e" || return 0
  subs=$(ghj api --paginate "repos/$REPO/issues/$e/sub_issues" | jqr '.[] | .state') || return 0
  [ -n "$subs" ] && ! grep -qx open <<<"$subs" || return 0
  mut gh issue close "$e" -R "$REPO" --comment "Step $(step_title "$1") is done. $CANCCU_MARK" && log "epic #$e closed"
}
# step_holds_epic <n>: the issue is the epic of a step that is not done
step_holds_epic() {
  local f m
  for f in "$CANCCU_HOME"/steps/*; do
    m=${f##*/}; [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] || continue
    [ "$(step_get "$m" epic)" = "$1" ] && [ "$(step_get "$m" phase)" != "done" ] && return 0
  done
  return 1
}
# step_stop_reason <m>: what the dispatcher does not handle on its own, for the lead: an open
# checkpoint or new open work after the step was done, its epic closed while it runs. Nothing when
# there is none. A finished package's issue open again is not one: like any issue of the step, the
# planner takes it with `ready` (merged_left leaves one with needs-you until a person looked).
step_stop_reason() {
  local m=$1 t c e
  t=$(step_title "$m")
  if [ -n "$(step_get "$m" done_at)" ]; then
    c=$(cur "$m" 'select(.checkpoint.state == "open") | .checkpoint.issue')
    [ -n "$c" ] && { echo "checkpoint #$c is open again, but the step was done"; return 0; }
    if (( $(cur "$m" .work_open) > 0 )); then
      echo "the step was done and has new open work: $(jqr --arg t "$t" '[.[] | select((.milestone.title // null) == $t)
        | select([.labels[].name] | (index("epic") or index("checkpoint")) | not) | "#\(.number)"] | join(", ")' <<<"$ISSUES")"
      return 0
    fi
  fi
  e=$(step_get "$m" epic)
  [ -n "$e" ] && [ "$(step_get "$m" phase)" != "done" ] && ! _issue_open "$e" && echo "its epic #$e is closed while the step runs"
  return 0
}

# ---------------------------------------------------------------- one step, once per pass

# step_tick <m> <may start 0|1>: the step's bookkeeping, then its planner or health pass if due
step_tick() {
  local m=$1 go=${2:-1} ph
  local r
  step_init "$m"
  # what the dispatcher does not handle on its own stops the step: nothing starts for it, the
  # lead is asked (needs-you, one line); once it is gone the step goes on where it was
  r=$(step_stop_reason "$m")
  if [ -n "$r" ]; then
    [ "$(step_get "$m" ny_kind)" = stop ] && [ "$(step_get "$m" ny_reason)" = "$(oneline 300 "$r")" ] ||
      step_needs_you "$m" "$r" stop
    return 0
  fi
  if [ "$(step_get "$m" phase)" = needs-you ] && [ "$(step_get "$m" ny_kind)" = stop ]; then
    r=$(step_get "$m" ny_from); step_set "$m" phase="${r:-needs-you}" ny_kind= ny_from=
    # back to the plan's needs-you (it failed during the stop): its reason; else none
    [ -n "$r" ] && step_set "$m" ny_reason="$(step_get "$m" ny_next)" ny_next=
    log "step $(step_title "$m"): the stop is resolved; it goes on"; step_ny_clear "$m"
  fi
  xblock_tick "$m"; budget_tick "$m"; notes_tick "$m"
  ph=$(step_get "$m" phase)
  case $ph in
    needs-you) plan_retry "$m" ;;
    running) wave_over "$m" && { step_set "$m" phase=idle; log "step $(step_title "$m"): wave $(step_get "$m" wave) is over"; } ;;
    # an accept that came after the wave was over lets a dependant start: the wave goes on
    idle) wave_can_start "$m" && { step_set "$m" phase=running; log "step $(step_title "$m"): wave $(step_get "$m" wave) goes on"; } ;;
    health|checkpoint) checkpoint_tick "$m" ;;
  esac
  ph=$(step_get "$m" phase)
  # every work issue closed: the step stays current (health-due) until its health pass starts
  [ "$ph" = idle ] && health_due "$m" && { step_set "$m" phase=health-due; ph=health-due; }
  case $ph in idle|planning|health-due) ;; *) return 0 ;; esac
  [ "$ph" = planning ] && [ -n "$(step_get "$m" planner_started)" ] && return 0
  (( go )) || return 0
  if health_due "$m"; then start_health "$m"
  else start_planner "$m" || { [ "$ph" = planning ] && [ -z "$(planner_issues "$1" | head -1)" ] && step_set "$m" phase=idle; }; fi
  return 0
}
