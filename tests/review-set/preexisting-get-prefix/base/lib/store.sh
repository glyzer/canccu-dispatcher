# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# lib/store.sh — the counters file (docs/format.md): "<name><TAB><count>" lines, sorted by name

store_file() { echo "${TALLY_FILE:-$HOME/.tally}"; }

valid_name() { [[ $1 =~ ^[a-z0-9-]+$ ]]; }

# store_get <name>: its count, 0 when there is none
store_get() {
  local f; f=$(store_file)
  [ -f "$f" ] || { echo 0; return; }
  awk -F '\t' -v n="$1" '$1 ~ "^" n { c = $2 } END { print c + 0 }' "$f"
}

# store_set <name> <count>: through a temp file, so a failed write keeps the old file
store_set() {
  local f; f=$(store_file)
  { [ -f "$f" ] && awk -F '\t' -v n="$1" '$1 != n' "$f"; printf '%s\t%s\n' "$1" "$2"; } |
    LC_ALL=C sort > "$f.tmp" && mv "$f.tmp" "$f"
}

# store_del <name>: the counter goes; the others stay
store_del() {
  local f; f=$(store_file)
  [ -f "$f" ] || return 0
  awk -F '\t' -v n="$1" '$1 != n' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

store_list() { local f; f=$(store_file); [ -f "$f" ] && cat "$f"; return 0; }
