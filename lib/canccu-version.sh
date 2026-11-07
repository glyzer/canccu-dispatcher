# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# The tool's version, from the VERSION file of the tree the caller runs from. Sourced, never run.
# canccu_version <root>: the version; "unknown" when the tree has no VERSION (a broken copy)
canccu_version() {
  local v; v=$(tr -d '[:space:]' < "$1/VERSION" 2>/dev/null)
  printf '%s\n' "${v:-unknown}"
}
# canccu_commit <root>: "<short commit>" or "<short commit>, dirty" when the tree is a git
# checkout of its own; nothing for a release (it has no .git). A checkout nested in another repo
# is not mistaken for it: the toplevel must be the root itself.
canccu_commit() {
  local top c
  [ -e "$1/.git" ] || return 0
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ "$(realpath -m "$top")" = "$(realpath -m "$1")" ] || return 0
  c=$(git -C "$1" rev-parse --short HEAD 2>/dev/null) || return 0
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null | head -n1)" ] && c+=", dirty"
  printf '%s\n' "$c"
}
