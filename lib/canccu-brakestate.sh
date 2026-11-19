# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# lib/canccu-brakestate.sh — the review brake's state (docs/plan/contracts.md §8): the file
# `brake` in the project's home, `<time> <trigger>`. Sourced by lib/canccu-common.sh and by
# bin/canccu-dispatcher (which reads no common), never run; it needs nothing but CANCCU_HOME, and
# lib/canccu-actionslog.sh for the release.

brake_file() { echo "$CANCCU_HOME/brake"; }
# brake_on: engaged. Read on every review decision: a test of the file, nothing more.
brake_on() { [ -e "$CANCCU_HOME/brake" ]; }
# brake_text: "on since <time> (<trigger>)" while engaged, nothing otherwise
brake_text() {
  local l
  brake_on || return 0
  l=$(head -n 1 "$CANCCU_HOME/brake" 2>/dev/null)
  echo "on since ${l%% *} (${l#* })"
}

# brake_cmd [release]: `canccu-dispatcher brake`. Only the product owner releases: the leader and
# a run are refused like a locked setting (exit 3), and the refusal is in the actions log too,
# so the product owner sees who tried. Nothing else removes the file (rule 7 of the plan). A
# release writes brake-released, the newest merged PR: the same window never engages it again.
brake_cmd() {
  case ${1:-} in
    "") if brake_on; then echo "brake: $(brake_text)"; else echo "brake: off"; fi ;;
    release)
      if [ "$(cfg_actor)" != po ]; then
        actions_log "brake release" - refused
        echo "canccu-dispatcher: refused: only the product owner releases the review brake" >&2; return 3
      fi
      brake_on || { echo "the review brake is not on"; return 0; }
      rm -f "$CANCCU_HOME/brake" || { echo "canccu-dispatcher: cannot remove $(brake_file)" >&2; return 1; }
      # the hold: the trigger (brake_tick) waits for a PR merged after this one, the newest now
      awk -F '\t' '$3 ~ /^[0-9]+$/ { p = $3 } END { print p }' "$CANCCU_HOME/merged.log" 2>/dev/null > "$CANCCU_HOME/brake-released"
      actions_log "brake release" - released
      echo "review brake released" ;;
    *) return 2 ;;
  esac
}
