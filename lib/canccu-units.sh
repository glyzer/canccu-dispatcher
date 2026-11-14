# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run): units. The pipeline runs on a unit key K:
# <n> for a fast-lane issue, a package of one or an old per-issue state; pkg-<m>-<name> for a
# package of several issues; pkg-<m>-health for a step's health pass (m: the milestone number).
# Everything that touches GitHub as an issue goes through lead_of / members_of, which are the
# identity for <n>. docs/canccu-dispatch.md, "Work packages per step".

is_pkg() { [[ $1 == pkg-* ]]; }
is_health() { is_pkg "$1" && [ "$(st_get "$1" health)" = 1 ]; }
# _issue_open <n>: the issue is in this pass's open list
_issue_open() { jqr --argjson n "$1" 'any(.[]; .number == $n)' <<<"$ISSUES" | grep -qx true; }

# members_of <K>: the unit's issues in plan order (none for the health pass)
members_of() {
  if is_pkg "$1"; then st_get "$1" members | tr ' ' '\n' | grep .; else echo "$1"; fi
  return 0
}
# lead_of <K>: the issue that stands for the unit on GitHub (labels, comments, the user's
# answers): the issue itself; a package's first open member, else its first; the health pass's
# epic, else its checkpoint
lead_of() {
  local k=$1 m
  is_pkg "$k" || { echo "$k"; return 0; }
  if is_health "$k"; then step_issue "$(st_get "$k" step)"; return 0; fi
  for m in $(members_of "$k"); do _issue_open "$m" && { echo "$m"; return 0; }; done
  members_of "$k" | head -1
}
# unit_of_issue <n>: the package that holds the issue, else the issue
unit_of_issue() {
  local f k
  for f in "$CANCCU_HOME"/state/pkg-*; do
    [ -f "$f" ] || continue; k=${f##*/}
    [[ " $(st_get "$k" members) " == *" $1 "* ]] && { echo "$k"; return 0; }
  done
  echo "$1"
}
# unit_open <K>: an issue is open; a package while any member is open; the health pass until its
# PR merged (or it found nothing to do: skipped=1)
unit_open() {
  local k=$1 m pr
  is_pkg "$k" || { _issue_open "$k"; return; }
  if is_health "$k"; then
    [ "$(st_get "$k" skipped)" = 1 ] && return 1
    pr=$(st_get "$k" pr); [ -n "$pr" ] || return 0
    pr_is_open "$pr" && return 0
    [ "$(ghj pr view "$pr" -R "$REPO" --json state -q .state 2>/dev/null)" != MERGED ]; return
  fi
  for m in $(members_of "$k"); do _issue_open "$m" && return 0; done
  return 1
}
unit_branch() { st_get "$1" branch; }
# unit_window <K>: its worker's tmux window
unit_window() {
  if ! is_pkg "$1"; then echo "#$1"
  elif is_health "$1"; then echo "health#$(st_get "$1" step)"
  else echo "pkg#$(st_get "$1" pkg)"; fi
}
# unit_wt <K>: its worktree (the engine makes issue-<n>; the dispatcher makes a package's)
unit_wt() {
  if is_pkg "$1"; then echo "$WORKERS_DIR/worktrees/$REPO_NAME/$1"; else echo "$WORKERS_DIR/worktrees/$REPO_NAME/issue-$1"; fi
}
# plan_wt <m>: the worktree of the step's planner (made afresh each run, removed when the step is done)
plan_wt() { echo "$WORKERS_DIR/worktrees/$REPO_NAME/plan-$1"; }
# ensure_unit_wt <K>: a package's worktree, detached at origin/main, made once
ensure_unit_wt() {
  local wt; wt=$(unit_wt "$1")
  is_pkg "$1" && [ ! -e "$wt/.git" ] || return 0
  mut git -C "$CLONE" fetch -q origin || { log "#$1: git fetch failed"; return 1; }
  mut git -C "$CLONE" worktree add -q --detach "$wt" origin/main || { log "#$1: worktree $wt failed"; return 1; }
}
# unit_title <K>: the issue's title; "package <name>: <lead's title> (+k)"; "health pass: <step>"
unit_title() {
  local k=$1 l c
  is_pkg "$k" || { jqr --argjson n "$k" '.[] | select(.number == $n) | .title' <<<"$ISSUES"; return; }
  if is_health "$k"; then echo "health pass: $(step_get "$(st_get "$k" step)" title)"; return; fi
  l=$(lead_of "$k"); c=$(members_of "$k" | grep -c .)
  echo "package $(st_get "$k" pkg): $(jqr --argjson n "${l:-0}" '.[] | select(.number == $n) | .title' <<<"$ISSUES")$( (( c > 1 )) && echo " (+$((c - 1)))")"
}
# pkg_budget <"turns usd min"> <k>: the budget times the package's issue count, each part capped
# by BUDGET_PACKAGE_MAX
pkg_budget() {
  local t u m mt mu mm k=${2:-1}
  read -r t u m <<<"$1"; read -r mt mu mm <<<"$BUDGET_PACKAGE_MAX"
  awk -v t="$t" -v u="$u" -v m="$m" -v k="$k" -v mt="$mt" -v mu="$mu" -v mm="$mm" \
    'function lo(a, b) { return a < b ? a : b }
     BEGIN { printf "%d %s %d\n", lo(t * k, mt), lo(u * k, mu) + 0, lo(m * k, mm) }'
}
# unit_size <K>: how many issues the unit covers (1 for an issue or the health pass)
unit_size() { local c; c=$(members_of "$1" | grep -c .); echo $(( c > 0 ? c : 1 )); }
# unit_of_branch <branch>: the managed package whose branch it is (or its contract branch,
# is_contract_pr), else nothing
unit_of_branch() {
  local f b
  [[ $1 == pkg-* ]] || return 0
  for f in "$CANCCU_HOME"/state/pkg-*; do
    [ -f "$f" ] || continue
    b=$(st_get "${f##*/}" branch)
    [ -n "$b" ] && { [ "$b" = "$1" ] || [ "$b-contract" = "$1" ]; } && { echo "${f##*/}"; return 0; }
  done
  return 0
}

# owner_of <K> <kind>: who a waiting item of the unit (or a step's issue) is for, po or leader, by
# the owner rule of docs/plan/contracts.md §1; kind: a snap_need or ping kind. It reads only the
# dispatcher's own state and settings, never a label the leader sets (manual-accept is the
# product owner's). Rule 7 (the hand-over of an item the leader left unacknowledged) is
# feed_handover's: it rewrites the stored owner, which need_owner reads.
owner_of() {
  local k=$1 kind=$2 r m
  [ "${LEADER:-off}" = on ] || { echo po; return 0; }
  case $kind in checkpoint|budget|plan-invalid|dispatcher) echo po; return 0 ;; esac
  r=$(st_get "$k" reason 2>/dev/null); r=${r#manual: }
  # rule 3: a plan-tier question, or one the answerer escalated (needs_you names its "Needs the
  # product owner:" comment's link, or the answerer finished without one); an answerer that
  # stopped without escalating leaves it to the leader
  if [ "$kind" = question ]; then
    [[ $r == *"always for the product owner"* || $r == *"needs the product owner (http"* ]] && { echo po; return 0; }
    [[ $r == *"needs the product owner"* && $r != *"; the answerer stopped:"* ]] && { echo po; return 0; }
  fi
  if [ "$kind" = accept ]; then
    case $r in
      "users see it:"*|"changes agent config"*|"changes a gated path"*|"changes "*"/ ("*|"maintainer accept:"*|"the issue has manual-accept"*)
        echo po; return 0 ;;
    esac
    [[ $r == "risk high"* ]] && [ "${LEADER_ACCEPTS_HIGH_RISK:-0}" != 1 ] && { echo po; return 0; }
    [ "${LEADER_ACCEPTS:-none}" = technical ] || { echo po; return 0; }
  fi
  # rule 5: a plan (its needs-you, or the accept of its plan PR) of a unit marked manual-accept
  if [ "$kind" = plan ] || [ "$r" = "plan tier" ]; then
    for m in $(members_of "$k"); do
      jqr --argjson n "$m" 'any(.[]; .number == $n and any(.labels[]?; .name == "manual-accept"))' <<<"${ISSUES:-[]}" 2>/dev/null |
        grep -qx true && { echo po; return 0; }
    done
  fi
  echo leader
}
# need_owner <K> <kind>: the owner of a waiting item as shown and pinged: the one stored when the
# unit entered accept or needs-you, else owner_of. LEADER=off wins over a stored leader (the
# setting was switched off since).
need_owner() {
  local o=""
  [ "${LEADER:-off}" = on ] || { echo po; return 0; }
  [ -n "$1" ] && is_managed "$1" && o=$(st_get "$1" owner)
  echo "${o:-$(owner_of "$1" "$2")}"
}
# ny_item_kind <K>: the item kind of a unit in phase needs-you: plan, question or needs-you
ny_item_kind() {
  case $(st_get "$1" ny_kind) in plan) echo plan ;; question) echo question ;; *) echo needs-you ;; esac
}
# unit_moved <K> <old phase> <new phase>: st_set's hook on every write of phase: the owner is set
# on entering accept or needs-you (again on a needs-you with a new kind) and goes on leaving them;
# phase_at (the idle alarm's clock) moves only with a new phase; then the feed's lines
unit_moved() {
  local k=$1 new=$3 kv=()
  [ "$2" = "$new" ] || kv+=(phase_at="$(now)")
  case $new in
    accept) kv+=(owner="$(owner_of "$k" accept)") ;;
    needs-you) kv+=(owner="$(owner_of "$k" "$(ny_item_kind "$k")")") ;;
    *) [ -z "$(st_get "$k" owner)" ] || kv+=(owner=) ;;
  esac
  (( ${#kv[@]} == 0 )) || _st_put "$k" "${kv[@]}"
  feed_unit_moved "$k" "$2" "$new"
}
