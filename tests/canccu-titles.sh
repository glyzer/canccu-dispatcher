#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-titles.sh — offline tests for safe_title: a GitHub title reaches no terminal, tmux
# title or log line with a control character in it (the harness: tests/lib/harness.sh). The
# monitor's side is in bin/canccu-monitor --self-test.
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# an OSC title change, a clear screen, a tab and a C1 CSI (U+009B, as UTF-8), around text that stays
BAD=$'Evil \e]0;x\a title \e[2J with\ttab and \xc2\x9b C1 \xc3\xa9'
CLEAN=$'Evil ]0;x title [2J with tab and  C1 \xc3\xa9'
# evil <issue json>: the issue with the bad title
evil() { jq -c --arg t "$BAD" '.title = $t'; }
# clean_lines <file>: its lines that hold the title, none with a control character (tab included)
clean_lines() {
  local l; l=$(grep -a 'Evil' "$1") || { echo "    no title line in $1"; return 1; }
  ! LC_ALL=C grep -aqP '[\x00-\x1f\x7f]|\xc2[\x80-\x9f]' <<<"$l" || { echo "    a control character in: $l"; return 1; }
}

env_new titles
ok "safe_title strips C0 and C1, a tab becomes a space" eq "$(lib safe_title "$BAD")" "$CLEAN"
ok "… and keeps every other character" eq "$(lib safe_title $'caf\xc3\xa9 \xc2\xa0 \xe6\x97\xa5 #12: a/b')" $'caf\xc3\xa9 \xc2\xa0 \xe6\x97\xa5 #12: a/b'

ms() { jq -nc --argjson n "$1" --arg t "$2" '{number: $n, title: $t, open_issues: 0, closed_issues: 0, due_on: null}'; }
ms 12 "3 Events $BAD" | jq -s . > "$FAKE/ms.json"
{ issue 3 ready | evil; issue 4 | evil; issue 5 needs-you | evil; issue 90 epic "" "3 Events $BAD"; issue 91 "" "" "3 Events $BAD" | evil; } | issues
dispatch --once
ok "titles: the issue starts" started 3
ok "… the log line has the clean title" grep -qxF "#3 started: $CLEAN" <(cut -d' ' -f2- "$CANCCU_HOME/dispatch.log")
ok "… no log line has a control character" clean_lines "$CANCCU_HOME/dispatch.log"
ok "… the milestone's title in the log is clean too" grep -qF "step 3 Events $CLEAN" "$CANCCU_HOME/dispatch.log"
ok "… the snapshot's titles are clean (the monitor reads them)" \
  eq "$(jq -r '[.running[].title, .needs_you[].title] | map(select(test("Evil"))) | unique | .[]' "$CANCCU_HOME/status.json")" "$CLEAN"
PATH="$fb:$PATH" "$root/bin/canccu-status" > "$E/status" 2>&1
ok "… canccu-status prints the clean title" eq "$(grep -cF "#4 · $CLEAN" "$E/status") $(grep -cF "#5 · $CLEAN (labelled needs-you)" "$E/status")" "1 1"
ok "… and no control character in a title line" clean_lines "$E/status"

echo "canccu-titles tests: $npass passed, $nfail failed"
(( nfail == 0 ))
