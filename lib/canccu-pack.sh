# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with libexec/canccu-worker
# Part of libexec/canccu-worker (sourced by it, never run): the context pack (#333). Before a
# package's first build a short run on a cheaper model writes .canccu/context.md in the worktree,
# so the build reads it instead of exploring the repo. It runs inside the build's own window and
# slot: the dispatcher's state machine sees one run, and the build starts the moment it ends.

# pack_run <repo> <key> <dir> <log>: the pack, when the dispatcher asked for one (WORKER_PACK_MODEL,
# WORKER_PACK_PROMPT, WORKER_PACK_BUDGET "turns usd min": only a package's first build gets them).
# Its own session, never the build's; its own spend.log line, type pack. However it ends, the
# build starts: a failed or over-budget pack is logged and the build goes without the file.
pack_run() {
  local repo=$1 key=$2 dir=$3 log=$4 turns cost mins sum prc rc st ex
  [ -n "${WORKER_PACK_MODEL:-}" ] && [ -n "${WORKER_PACK_PROMPT:-}" ] || return 0
  read -r turns cost mins <<<"${WORKER_PACK_BUDGET:-30 1 15}"
  [[ $turns =~ ^[0-9]+$ && $mins =~ ^[0-9]+$ && $cost =~ ^[0-9]+(\.[0-9]+)?$ ]] || { turns=30 cost=1 mins=15; }
  # the build must never commit it: excluded in the clone's info/exclude, which every worktree reads
  ex=$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null) && [[ $ex == /* ]] || ex=${ex:+$dir/$ex}
  [ -z "$ex" ] || grep -qxF '.canccu/' "$ex" 2>/dev/null || { mkdir -p "${ex%/*}" && echo '.canccu/' >> "$ex"; }
  rm -f "$dir/.canccu/context.md"
  sum="$WORKERS_DIR/.$repo-$key.pack.sum"; rm -f "$sum"
  local WORKER_RUN_TYPE=pack WORKER_EFFORT="" WORKER_EFFORT_NOTE="" run_model=$WORKER_PACK_MODEL run_session=fresh run_t0
  run_t0=$(date +%s)
  printf '\n=== %s %s#%s context pack · budget %st/$%s/%sm · %s\n' "$(date -u '+%FT%TZ')" "$repo" "$key" "$turns" "$cost" "$mins" "$run_model" >> "$log"
  exec 5< <(cd "$dir" && timed_exec "${mins}m" claude -p --output-format stream-json --verbose --permission-mode auto \
    --permission-prompts none --max-budget-usd "$cost" -n "$repo#$key-pack" --session-id "$(new_uuid)" \
    --append-system-prompt "$WORKER_RULES" --model "$run_model" -- "$WORKER_PACK_PROMPT" 2>>"$log")
  cpid=$!   # the TERM trap stops it with the run
  guard "$((mins + 2))m" python3 -I "$LIB/canccu-stream.py" "$log" "$sum" "$turns" "$WORKERS_DIR/usage.json" "" <&5; prc=$?
  exec 5<&-
  (( prc == 3 )) && kill "$cpid" 2>/dev/null
  wait "$cpid"; rc=$?; cpid=""
  st=$(pack_status "$sum" "$prc" "$rc" "$turns" "$mins")
  [ "$st" = done ] && [ ! -s "$dir/.canccu/context.md" ] && st="error: no .canccu/context.md written"
  printf '=== context pack: %s\n' "$st" >> "$log"
  spend_line "$repo" "$key" "$(pack_get "$sum" cost)" \
    "$(pack_get "$sum" tokens_in) $(pack_get "$sum" tokens_out) $(pack_get "$sum" cache_read) $(pack_get "$sum" cache_write)" \
    "pack=$([ "$st" = done ] && echo ok || echo failed)"
  rm -f "$sum"
  [ "$st" = done ] || printf '%s #%s: the context pack failed (%s); the build starts without it\n' \
    "$(date -u '+%FT%TZ')" "$key" "$st" >> "$CANCCU_HOME/dispatch.log"
}

# pack_get <summary> <field>: a field of the stream's summary, "-" (or "?" for the cost) when unknown
pack_get() {
  local v; v=$(guard 10 jq -r ".$2 // empty" "$1" 2>/dev/null)
  if [ "$2" = cost ]; then [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]] || v="?"; else [[ $v =~ ^[0-9]+$ ]] || v=-; fi
  echo "$v"
}

# pack_status <summary> <stream exit> <claude exit> <turns> <mins>: done, or why not
pack_status() {
  if [ "$(guard 10 jq -r '.have_result // false' "$1" 2>/dev/null)" = true ]; then
    case $(guard 10 jq -r '"\(.subtype // "")|\(.is_error // false)"' "$1" 2>/dev/null) in
      success\|false) echo done ;; *budget*) echo "stopped: cost budget" ;; *max_turns*) echo "stopped: turn limit" ;;
      *) echo "error: $(guard 10 jq -r '.subtype // "unknown"' "$1" 2>/dev/null)" ;;
    esac
  elif (( $2 == 3 )); then echo "stopped: turn budget $4"
  elif (( $3 == 124 || $3 == 137 )); then echo "stopped: time budget ${5}m"
  else echo "crashed (exit $3)"; fi
}
