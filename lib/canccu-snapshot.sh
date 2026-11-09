# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The status snapshot: $CANCCU_HOME/status.json, what canccu-monitor shows. canccu-dispatch writes
# it after every pass (also a failed one), atomically: a temp file renamed over the old one. Never
# under --dry-run. Sourced by canccu-dispatch after canccu-common.sh; never run. The schema is in
# docs/canccu-dispatch.md, "Status snapshot"; a change to a field's meaning bumps STATUS_SCHEMA.
# A new field is additive and keeps the number: version (the release that wrote the snapshot) is.
STATUS_SCHEMA=2
# shellcheck source=canccu-snapshot-steps.sh
. "$(dirname "${BASH_SOURCE[0]}")/canccu-snapshot-steps.sh"

# issue_of_pr <pr>: the managed issue whose PR it is, else the first issue the PR closes
issue_of_pr() {
  local m
  for m in $(managed); do [ "$(st_get "$m" pr)" = "$1" ] && { echo "$m"; return 0; }; done
  pr_get "$1" '.closingIssuesReferences[0].number // empty' 2>/dev/null
  return 0
}

# snap_unit <K>: adds a running item's unit fields (schema 2): package (its key, or null), issues,
# risk; the issue is the lead issue (null for the planner and the health pass)
snap_unit() {
  local k=${1:-} p="" r="" is="" l=""
  if [ -n "$k" ]; then
    l=$(lead_of "$k"); is_health "$k" && l=""
    [ -n "$(st_get "$k" pkg)" ] && p=$k r=$(risk_max "$(st_get "$k" risk)" "$(st_get "$k" review_risk)")
    is=$(members_of "$k" | tr '\n' ' ')
  fi
  jq -c --arg p "$p" --arg r "$r" --arg is "$is" --arg l "$l" --arg k "$k" \
    '. + {package: (if $p == "" then null else $p end), issues: ($is | split(" ") | map(select(. != "") | tonumber)),
          risk: (if $r == "" then null else $r end)}
     | if $k != "" then .issue = ($l | tonumber? // null) else . end'
}
# snap_item <json args for jq -n...>: one running item, every field of the schema. ci (the
# PR's CI state: green, red, pending, none; null without a PR or a read), review_verdict (changes:
# the full review asked for changes, so the unit is in or past its fix round; else null)
snap_item() {
  jq -nc "$@" '{key: $key, issue: ($n | tonumber? // null), pr: ($pr | tonumber? // null), kind: $kind,
    phase: $phase, stage: $stage, pipeline: $pipe, title: $title,
    started: ($started | tonumber? // null), minutes: ($min | tonumber? // null),
    min_cap: ($mc | tonumber? // null), turns: ($t | tonumber? // null), turn_cap: ($tc | tonumber? // null),
    last_line: $last, color: ($color | tonumber? // null),
    ci: (if $ci == "" then null else $ci end), review_verdict: (if $rv == "" then null else $rv end)}'
}
# snap_ci <pr>: the PR's CI state for the snapshot (empty without a PR, or when it was not read)
snap_ci() { [ -n "$1" ] && ci_state "$1" 2>/dev/null; return 0; }
# snap_verdict <n>: changes when the unit's full review asked for changes (stage fixing or fixcheck)
snap_verdict() { case $(st_get "$1" stage) in fixing|fixcheck) echo changes ;; esac; }

# snap_running: one JSON line per live run, then one per managed issue in check (CI or a review
# slot) or merging that has no live run
snap_running() {
  local k s n pr kind pipe stage phase t tc mc last m at cap ci
  while read -r k s; do
    [ -n "$k" ] || continue
    pr="" n=""
    case $k in
      review-*) pr=${k#review-}; kind=$(review_mode_of "$pr"); n=$(issue_of_pr "$pr") ;;
      answer-*) n=${k#answer-}; kind=answer ;;
      plan-*) n="" kind=planner ;;
      *) n=$k; kind=work; is_health "$k" && kind=health ;;
    esac
    phase="" stage=""
    if [ -n "$n" ] && is_managed "$n"; then phase=$(st_get "$n" phase); stage=$(stage_of "$n"); [ -n "$pr" ] || pr=$(st_get "$n" pr); fi
    case $kind in
      review) pipe=review ;; fix-check) pipe=fix-check ;; answer) pipe=work ;; planner) pipe=plan ;;
      *) [ "$stage" = fixing ] && pipe=fix || pipe=work ;;
    esac
    read -r t tc mc <<<"$(run_progress "$k")"
    last=$(grep -E '^\[t[0-9]+\]' "$WORKERS_DIR/$REPO_NAME-$k.log" 2>/dev/null | tail -1)
    snap_item --arg key "$k" --arg n "$n" --arg pr "$pr" --arg kind "$kind" --arg phase "$phase" --arg stage "$stage" \
      --arg pipe "$pipe" --arg title "$(if [ -n "$n" ]; then title_of "$n"; elif [ "$kind" = planner ]; then echo "planner: step $(step_title "${k#plan-}")"; fi)" --arg started "${s:-}" \
      --arg min "$(( ($(now) - ${s:-$(now)}) / 60 ))" --arg mc "$mc" --arg t "$t" --arg tc "$tc" \
      --arg last "$(oneline 300 "$last")" --arg color "$( [ -n "$n" ] && color_code "$n")" \
      --arg ci "$(snap_ci "$pr")" --arg rv "$( [ -n "$n" ] && is_managed "$n" && snap_verdict "$n")" | snap_unit "$n"
  done < <(live_runs)
  for m in $(managed); do
    phase=$(st_get "$m" phase); pr=$(st_get "$m" pr)
    case $phase in
      check) issue_live "$m" && continue
             # CI pending is the CI step (no-checks: no check reported), also in a fix round (
             # its CI wait is not fix-check time); then the review, or after the findings the fix-check
             ci=$(snap_ci "$pr"); pipe=$(ci_pipe "$pr" "${ci:-?}")
             case $(st_get "$m" stage) in fixing|fixcheck) [ "$pipe" = review ] && pipe=fix-check ;; esac
             at=$(st_get "$m" check_at)
             # the CI wait's cap: past it the issue goes needs-you
             case $pipe in ci) cap=$CI_WAIT_MIN ;; no-checks) cap=${NO_CHECKS_MIN:-10} ;; *) cap="" ;; esac ;;
      merging) pipe=merge; at=$(st_get "$m" merge_at); cap=""; ci=$(snap_ci "$pr") ;;
      *) continue ;;
    esac
    snap_item --arg key "" --arg n "$m" --arg pr "$pr" --arg kind waiting --arg phase "$phase" --arg stage "$(stage_of "$m")" \
      --arg pipe "$pipe" --arg title "$(title_of "$m")" --arg started "$at" \
      --arg min "$( [ -n "$at" ] && echo $(( ($(now) - at) / 60 )))" --arg mc "$cap" --arg t "" --arg tc "" \
      --arg last "" --arg color "$(color_code "$m")" --arg ci "$ci" --arg rv "$(snap_verdict "$m")" | snap_unit "$m"
  done
}

# snap_need <kind> <n> <pr> <reason> <since> [title] [step] [url]: one item that needs the product
# owner; its url is the issue's, an accept's the PR's, else the one given (a checkpoint's summary).
# stage (where the unit parked: an accept at merge, a needs-you where it was, ny_stage; null
# for a step's items and an unmanaged issue) and issues (the unit's, or the issue)
snap_need() {
  local i url stg="" is; i=$(lead_of "$2"); url="https://github.com/$REPO/issues/$i" is=$i
  [ "$1" = accept ] && [ -n "$3" ] && url="https://github.com/$REPO/pull/$3"
  [ -n "${8:-}" ] && url=$8
  local p="" s=${7:-}
  is_managed "$2" && [ -n "$(st_get "$2" pkg)" ] && p=$2
  is_managed "$2" && [ -z "$s" ] && s=$(st_get "$2" step)
  if is_managed "$2"; then
    is=$(members_of "$2" | tr '\n' ' ')
    case $1/$(st_get "$2" phase) in
      plan-invalid/*|budget/*|checkpoint/*) ;;
      */accept) stg=merge ;;
      */needs-you) stg=$(st_get "$2" ny_stage) ;;
      */review) stg=$(pkg_stage "$2") ;;
    esac
  fi
  jq -nc --arg kind "$1" --arg n "$i" --arg pr "$3" --arg reason "$4" --arg since "$5" --arg title "${6:-}" \
    --arg url "$url" --arg color "$(color_code "$2")" --arg p "$p" --arg s "$s" --arg stg "$stg" --arg is "$is" \
    '{kind: $kind, issue: ($n | tonumber? // null), pr: ($pr | tonumber? // null), reason: $reason,
      since: ($since | tonumber? // null), title: $title, url: $url, color: ($color | tonumber? // null),
      package: (if $p == "" then null else $p end), step: ($s | tonumber? // null),
      stage: (if $stg == "" then null else $stg end), issues: ($is | split(" ") | map(select(. != "") | tonumber))}'
}

# snap_needs_you: accepts, needs-you (managed: its kind; or only labelled), plans, questions,
# unposted reviews, then each step's: a stop (needs-you), an invalid or missing plan, the step
# budget, a blocker in a later step, the checkpoint that waits for checkpoint-ok
snap_needs_you() {
  local m pr n f i ph stepiss=" "
  for m in $(managed); do
    pr=$(st_get "$m" pr)
    case $(st_get "$m" phase) in
      accept) snap_need accept "$m" "$pr" "$(st_get "$m" reason)" "$(st_get "$m" accept_at)" "$(title_of "$m")" ;;
      needs-you) n=$(st_get "$m" ny_kind)
                 snap_need "${n:-needs-you}" "$m" "$pr" "$(st_get "$m" reason)" "$(st_get "$m" ny_at)" "$(title_of "$m")" ;;
      review) [ "$(st_get "$m" post_ny)" = 1 ] &&
                snap_need needs-you "$m" "$pr" "the $(stage_of "$m") of PR #$pr could not be posted; retried each pass" "" "$(title_of "$m")" ;;
    esac
  done
  for f in "$CANCCU_HOME"/steps/*; do
    m=${f##*/}; [[ $m =~ ^[0-9]+$ ]] && [ -f "$f" ] || continue
    ph=$(step_get "$m" phase); i=$(step_issue "$m"); t=$(step_get "$m" title)
    [ -n "$i" ] && stepiss+="$i "
    if [ "$ph" = needs-you ] && [ "$(step_get "$m" ny_kind)" = stop ]; then
      n=$(step_get "$m" ny_next)   # the plan failed before or during the stop: shown after it
      snap_need needs-you "$i" "" "step $t stopped: $(step_get "$m" ny_reason)${n:+; then: $n}" "$(step_get "$m" ny_at)" "$t" "$m"
    elif [ "$ph" = needs-you ]; then
      snap_need plan-invalid "$i" "" "step $t: $(step_get "$m" ny_reason)" "$(step_get "$m" ny_at)" "$t" "$m"
    fi
    [ -n "$(step_get "$m" budget_ny)" ] &&
      snap_need budget "$i" "" "step $t reached STEP_BUDGET (\$$(step_spend "$m" | cut -d' ' -f1) of \$$STEP_BUDGET)" "" "$t" "$m"
    [ -n "$(step_get "$m" xblock_ny)" ] && snap_need needs-you "$i" "" "step $t waits on an issue of a later step (see the epic)" "" "$t" "$m"
    if [ "$ph" = checkpoint ]; then
      i=$(step_get "$m" checkpoint); stepiss+="$i "
      snap_need checkpoint "$i" "" "step $t is done: check it, then label checkpoint-ok or close it" "$(step_get "$m" checkpoint_at)" "$t" "$m" \
        "$(step_get "$m" checkpoint_url)"
    fi
  done
  jqr '.[] | select(any(.labels[]; .name == "needs-you") and (any(.labels[]; .name == "checkpoint") | not))
       | "\(.number)\t\(.title)"' <<<"$ISSUES" |
    while IFS=$'\t' read -r n t; do
      is_managed "$n" || [[ $stepiss == *" $n "* ]] || [ "$(unit_of_issue "$n")" != "$n" ] || snap_need needs-you "$n" "" "labelled needs-you" "" "$t"
    done
}

# snap_queue: the queue in the order it is taken, at most 15 lines, with what the others wait on
snap_queue() {
  local n w why
  while IFS=$'\t' read -r n w why; do
    jq -nc --arg n "$n" --arg w "$w" --arg why "$why" --arg title "$(title_of "$n")" \
      '{issue: ($n | tonumber), title: $title, blocked: ($w == "1"), waits_on: (if $why == "" then null else $why end),
        lane: "fast", package: null}'
  done < <(queue_list 999 15)
  (( ${STEPS_OK:-0} )) && snap_step_queue
}

# snap_milestones: {milestones, checkpoints} from two reads (the open milestones; the issues
# labelled checkpoint, open or closed); fails on a gh error. A checkpoint is ready when it is open
# and none of its blockers is.
snap_milestones() {
  local ms cps n ready=" " b
  # the pass's own read (fetch_steps); none: this pass could not read them
  (( ${STEPS_OK:-0} )) || return 1
  ms=$MILESTONES cps=$CHECKPOINTS
  # a checkpoint is ready when its step waits for checkpoint-ok
  for b in "$CANCCU_HOME"/steps/*; do
    n=${b##*/}; [[ $n =~ ^[0-9]+$ ]] && [ -f "$b" ] && [ "$(step_get "$n" phase)" = checkpoint ] && ready+="$(step_get "$n" checkpoint) "
  done
  jq -nc --slurpfile ms <(printf '%s' "$ms") --slurpfile cps <(printf '%s' "$cps") --arg ready "$ready" --arg repo "$REPO" "$MILESTONE_KEY_JQ"'
    ($ready | split(" ") | map(select(. != "") | tonumber)) as $r
    | ([ $cps[0][] | select(any(.labels[]; .name == "checkpoint"))
         | {issue: .number, title, state: (.state | ascii_downcase), milestone: (.milestone.title // null),
            ready: (.number | IN($r[])), url: "https://github.com/\($repo)/issues/\(.number)"} ]) as $c
    | { checkpoints: $c,
        milestones: ([ $ms[0][] | {title, open: .open_issues, closed: .closed_issues, due: .due_on,
                                 checkpoints: [ .title as $t | $c[] | select(.milestone == $t) | {issue, state, ready} ],
                                 k: (.title | milestone_key)} ]
                     | sort_by(.k, .title) | map(del(.k))) }'
}

# snap_events: the last 20 rows of dispatch.log's own lines (they start with the time; the raw
# output of commands, "  │ …", does not). Consecutive lines that differ only in a counter (a
# try number "try N", "after N min", "×N", or a number that ends the line) fold into one row: the
# newest line's time and text, count (the lines folded), first_at (the oldest one's time).
# canccu-monitor folds with the same rule (lib/canccu_monitor/parts.py, fold_key). The times are
# the log's local time: one date call reads them all.
snap_events() {
  local rows epochs
  rows=$(tail -n 2000 "$CANCCU_HOME/dispatch.log" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' | tail -500 |
    jq -Rsc 'split("\n") | map(select(. != "") | {ts: .[0:19], text: .[20:]}
               | .k = (.text | gsub("try [0-9]+"; "try N") | gsub("after [0-9]+ min"; "after N min")
                       | gsub("×[0-9]+"; "×N") | gsub("(?<![#\\w-])[0-9]+$"; "N")))
             | reduce .[] as $l ([]; if length > 0 and .[length - 1].k == $l.k
                 then .[length - 1] += {ts: $l.ts, text: $l.text, count: (.[length - 1].count + 1)}
                 else . + [$l + {first: $l.ts, count: 1}] end)
             | .[-20:]') || return 0
  [ "$(jq length <<<"$rows")" -gt 0 ] || return 0
  epochs=$(jq -r '.[] | .ts, .first' <<<"$rows" | date -f - +%s 2>/dev/null | jq -sc .) || epochs='[]'
  jq -c --argjson e "${epochs:-[]}" '. as $r | range(length) as $i | $r[$i] | .text as $text
    | {at: ($e[2 * $i] // null), issue: ((($text | capture("^#(?<n>[0-9]+)\\b") | .n | tonumber)?) // null),
       package: ((($text | capture("^#(?<k>pkg-[0-9]+-[a-z0-9-]+)") | .k)?) // null), text: $text,
       count: .count, first_at: ($e[2 * $i + 1] // null)}' <<<"$rows"
}

# write_status [error]: write status.json. With an error (the pass could not read GitHub) the
# sections that need GitHub (needs_you, queue, milestones) are the previous snapshot's, listed
# in "stale"; a failed milestone read keeps the previous milestones the same way.
write_status() {
  (( CANCCU_DRY )) && return 0
  local f="$CANCCU_HOME/status.json" err=${1:-} prev stale=() running needs queue ms events bu ok=true tmp steps usage overview others
  local spend nocost started durs
  tmp="$f.tmp.$$"
  prev=$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null) || prev='{}'
  [ -n "$prev" ] || prev='{}'
  running=$(snap_running | jq -sc .) || running='[]'
  if [ -n "$err" ]; then
    # no issues or PRs were read: the titles come from the last snapshot; the CI step is unknown
    running=$(jq -c --slurpfile prev <(printf '%s' "$prev") 'map(. as $i | if .title == "" and .issue != null
               then .title = ([$prev[0].running[]? | select(.issue == $i.issue) | .title] | first // "") else . end)' <<<"$running") ||
      running='[]'
    ok=false stale=(running needs_you queue milestones steps step_overview)
    steps=$(jq -c '{steps: (.steps // []), current_step: (.current_step // null)}' <<<"$prev")
    overview=$(jq -c '.step_overview // []' <<<"$prev")
    needs=$(jq -c '.needs_you // []' <<<"$prev"); queue=$(jq -c '.queue // []' <<<"$prev")
    ms=$(jq -c '{milestones: (.milestones // []), checkpoints: []}' <<<"$prev")
  else
    if ! ms=$(snap_milestones 2>/dev/null) || [ -z "$ms" ]; then
      stale+=(milestones steps step_overview); ms=$(jq -c '{milestones: (.milestones // []), checkpoints: []}' <<<"$prev")
      steps=$(jq -c '{steps: (.steps // []), current_step: (.current_step // null)}' <<<"$prev")
      overview=$(jq -c '.step_overview // []' <<<"$prev")
    else steps=$(snap_steps) || steps='{"steps": [], "current_step": null}'
      [ -n "$steps" ] || steps='{"steps": [], "current_step": null}'
      overview=$(snap_step_overview) && [ -n "$overview" ] || overview='[]'
    fi
    needs=$(snap_needs_you | jq -sc .) || needs='[]'
    queue=$(snap_queue | jq -sc .) || queue='[]'
  fi
  usage=$(snap_usage) || usage='{}'
  others=$(other_runs | jq -Rsc 'split("\n") | map(select(. != "") | split("\t")
             | {repo: .[0], key: .[1], kind: .[2], started: (.[3] | tonumber? // null)})') || others='[]'
  events=$(snap_events | jq -sc .) || events='[]'
  bu=$(backoff_until); (( bu > $(now) )) || bu=""
  read -r spend nocost <<<"$(spend_today)"
  started=${PASS_STARTED:-$(now)}
  durs=$(jq -c --arg d "$(( $(now) - started ))" '[(.pass.durations // [])[]? | numbers] + [$d | tonumber] | .[-5:]' <<<"$prev") ||
    durs="[$(( $(now) - started ))]"
  # the sections go in as files: one of them (the queue, the step overview) can pass the 128 KiB
  # Linux allows one command-line argument, and jq would not start
  jq -n --argjson schema "$STATUS_SCHEMA" --arg version "$CANCCU_VERSION" --arg project "$CANCCU_PROJECT" --arg repo "$REPO" --arg repo_name "$REPO_NAME" --arg pid "$$" \
    --arg interval "$INTERVAL" --arg now "$(now)" --argjson ok "$ok" --arg err "$err" \
    --argjson paused "$(paused && echo true || echo false)" --arg bu "$bu" \
    --arg running_n "$(running_count)" --arg cap "$CAP" --arg total "$(total_running)" --arg tcap "$TOTAL_CAP" \
    --arg spend "$spend" --arg nocost "$nocost" --arg started "$started" --argjson durs "$durs" --arg day "$(date -u -d "@$(now)" +%F)" --arg freeze "${AUTO_MERGE_UNTIL:-}" \
    --slurpfile running <(printf '%s' "$running") --slurpfile needs <(printf '%s' "$needs") --slurpfile queue <(printf '%s' "$queue") \
    --slurpfile ms <(printf '%s' "$ms") --slurpfile events <(printf '%s' "$events") --arg stale "${stale[*]}" \
    --slurpfile steps <(printf '%s' "$steps") --slurpfile usage <(printf '%s' "$usage") \
    --slurpfile overview <(printf '%s' "${overview:-[]}") --slurpfile others <(printf '%s' "$others") '
    { schema: $schema, version: $version, project: $project, repo: $repo, repo_name: $repo_name, pid: ($pid | tonumber), interval: ($interval | tonumber),
      pass: { at: ($now | tonumber), started: ($started | tonumber), duration: $durs[-1], durations: $durs, ok: $ok, error: (if $err == "" then null else $err end), paused: $paused,
              backoff_until: ($bu | tonumber? // null) },
      caps: { running: ($running_n | tonumber), cap: ($cap | tonumber), total_running: ($total | tonumber),
              total_cap: ($tcap | tonumber) },
      spend: { today_usd: (($spend | tonumber) * 100 | round / 100), runs_without_cost: ($nocost | tonumber), day: $day, freeze: (if $freeze == "" then null else $freeze end) },
      running: $running[0], needs_you: $needs[0], queue: $queue[0], milestones: $ms[0].milestones, events: $events[0],
      steps: $steps[0].steps, current_step: $steps[0].current_step, step_overview: $overview[0], other_runs: $others[0], usage: $usage[0],
      stale: ($stale | split(" ") | map(select(. != ""))) }' > "$tmp" && mv -f "$tmp" "$f" || {
    rm -f "$tmp"; log "could not write ${f/#$HOME/\~}"; }
  # for run_pass: this pass got to its snapshot
  touch "$CANCCU_HOME/.pass-written" 2>/dev/null
  return 0
}
