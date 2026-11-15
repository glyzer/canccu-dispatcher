# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# lib/canccu-kv.sh — the key=value files (a unit's state/<K>, a step's steps/<m>, feed.open).
# Sourced by lib/canccu-common.sh, and alone by `canccu-dispatcher wait`, which records the
# leader's acknowledgement without loading a project.

# Under --dry-run, writes go to DRY_ST in memory, so the rest of the pass sees them.
declare -A DRY_ST=()
# kv_get <file> <dry key> <key>, kv_set <file> <dry key> key=value...: one key=value file (a unit's
# state/<K>, a step's steps/<m>); under --dry-run in DRY_ST under "<dry key>.<key>"
# The last value wins (kv_set may append). Pure bash: a pass reads state files many times.
kv_get() {
  if [ -n "${DRY_ST[$2.$3]+x}" ]; then printf '%s\n' "${DRY_ST[$2.$3]}"; return; fi
  local l="" v="" f=0
  [ -f "$1" ] && [ -r "$1" ] || return 0   # an empty key names the directory state/: -r passes it
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l == "$3="* ]] && { v=${l#"$3="}; f=1; }
  done < "$1"
  (( f )) && printf '%s\n' "$v"
  return 0
}
# kv_lock <file>: the lock of a key=value file, hidden beside it (the state dirs list units by
# their visible files)
kv_lock() { echo "${1%/*}/.${1##*/}.lock"; }
# kv_set writes every key in one go, under the file's lock, through a temp file of its own: the
# dispatcher's pass and canccu-ship, -stop, -run or -review writing the same file at once never
# lose a key
kv_set() {
  local f=$1 d=$2 kv; shift 2
  if (( ${CANCCU_DRY:-0} )); then
    DRY_ST[$d.]=1
    for kv; do DRY_ST[$d.${kv%%=*}]=${kv#*=}; done
    return 0
  fi
  mkdir -p "${f%/*}" || return 1
  ( flock -w 30 9 || { echo "kv_set: $f stayed locked" >&2; exit 1; }
    tmp=$(mktemp "${f%/*}/.${f##*/}.XXXXXX") || exit 1
    { [ -f "$f" ] && awk -v keys="${*%%=*}" 'BEGIN { n = split(keys, a, " "); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
        { k = $0; sub(/=.*/, "", k) } !(k in drop)' "$f"
      awk '{ k = $0; sub(/=.*/, "", k); v[k] = $0; if (!(k in seen)) { seen[k] = 1; o[++n] = k } }
        END { for (i = 1; i <= n; i++) print v[o[i]] }' < <(printf '%s\n' "$@")
    } > "$tmp" && mv -f -- "$tmp" "$f" || { rm -f "$tmp"; exit 1; }
  ) 9>>"$(kv_lock "$f")"
}
