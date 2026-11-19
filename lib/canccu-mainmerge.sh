# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): what a new head adds to an older one
# when it is merges of main (main_merge_only, resolved_merge_files). canccu-ship reads them too.

# pr_fetch <pr>: the PR head and main into the main clone, for the reads below
pr_fetch() { mut git -C "$CLONE" fetch -q origin main "pull/$1/head" || log "PR #$1: git fetch failed"; }

# main_merge_only <base> <head>: what head adds to base is nothing but merges of main: from head,
# at most 5 steps, each commit has two parents, the second on origin/main, and its tree is the
# one git makes of merging the two (merge-tree, no worktree); its first parent is the next step,
# and the walk reaches base. Such a tree holds nothing a person or a run wrote by hand. Any git
# error (a git older than 2.38 has no merge-tree --write-tree) is false: that only costs a review.
main_merge_only() {
  local base=$1 c=$2 i p1 p2 more t
  for ((i = 0; i < 5; i++)); do
    read -r _ p1 p2 more <<<"$(guard 20 git -C "$CLONE" rev-list --parents -n 1 "$c" 2>/dev/null)"
    [ -n "$p2" ] && [ -z "$more" ] || return 1
    guard 20 git -C "$CLONE" merge-base --is-ancestor "$p2" origin/main 2>/dev/null || return 1
    t=$(guard 60 git -C "$CLONE" merge-tree --write-tree "$p1" "$p2" 2>/dev/null) && [ -n "$t" ] || return 1
    [ "${t%%$'\n'*}" = "$(guard 20 git -C "$CLONE" rev-parse "$c^{tree}" 2>/dev/null)" ] || return 1
    c=$p1
    [ "$c" = "$base" ] && return 0
  done
  return 1
}

# resolved_merge_files <base> <head>: head adds to base nothing but merges of main (the walk of
# main_merge_only), each either clean or with its conflicts resolved: prints the files where a
# merge's tree differs from git's own merge of its parents (merge-tree, conflict markers and all),
# the lines resolved by hand, as FIXCHECK_COUNT_RESOLVED counts them. Nothing printed: clean merges
# only. 1: a commit of the PR's own, a walk that never reaches base, or any git error.
resolved_merge_files() {
  local base=$1 c=$2 i p1 p2 more t rc d files=()
  for ((i = 0; i < 5; i++)); do
    read -r _ p1 p2 more <<<"$(guard 20 git -C "$CLONE" rev-list --parents -n 1 "$c" 2>/dev/null)"
    [ -n "$p2" ] && [ -z "$more" ] || return 1
    guard 20 git -C "$CLONE" merge-base --is-ancestor "$p2" origin/main 2>/dev/null || return 1
    t=$(guard 60 git -C "$CLONE" merge-tree --write-tree "$p1" "$p2" 2>/dev/null); rc=$? t=${t%%$'\n'*}
    # exit 1 is a conflict, its first line still the tree with the markers
    [[ $t =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && (( rc <= 1 )) || return 1
    d=$(guard 30 git -C "$CLONE" -c core.quotePath=off diff --name-only --no-renames "$t" "$c" 2>/dev/null) || return 1
    [ -z "$d" ] || mapfile -t -O "${#files[@]}" files <<<"$d"
    c=$p1
    if [ "$c" = "$base" ]; then
      (( ${#files[@]} )) && printf '%s\n' "${files[@]}" | sort -u
      return 0
    fi
  done
  return 1
}

# resolved_outside <base> <head>: the files a resolution of head (resolved_merge_files) touched that
# are not in the PR's own diff at base (from its merge-base with main); nothing printed: every
# resolved line is the PR's own. 1: not such a head, or the PR's diff cannot be read.
resolved_outside() {
  local r mb own
  r=$(resolved_merge_files "$1" "$2") || return 1
  mb=$(guard 20 git -C "$CLONE" merge-base origin/main "$1" 2>/dev/null) && [ -n "$mb" ] || return 1
  own=$(guard 20 git -C "$CLONE" -c core.quotePath=off diff --name-only --no-renames "$mb" "$1" 2>/dev/null) || return 1
  [ -z "$r" ] || grep -vxF -f <(printf '%s\n' "$own") <<<"$r"
  return 0
}
