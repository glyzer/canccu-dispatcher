# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # the globals of tests/scenarios/run, both ways
# tests/scenarios/lib.sh — sourced by tests/scenarios/run: the sandbox's reset, a scenario's own
# dispatcher home, its issues, and the end-state checks, all through gh against $REPO
# (docs/reference/scenarios.md). Every helper works on the issues the scenario made itself, so
# what is left of an earlier scenario (closed, but still listed) never counts.

# must <cmd...>: run cmd; when it fails, $SCENARIO_DIR/why names it, its exit and the last line it
# printed on stderr (a file, since a setup step may run in $(...)), and the setup's FAIL prints that
must() {
  local rc
  "$@" 2> "$SCENARIO_DIR/must.err" && return 0
  rc=$?
  echo "$* failed (exit $rc)$(tail -1 "$SCENARIO_DIR/must.err" | sed 's/^./: &/')" > "$SCENARIO_DIR/why"
  return "$rc"
}

# home <scenario>: a project home of its own (CANCCU_ROOT, the project sandbox, its clone), so a
# scenario never sees the state of another, nor the host's real projects
home() {
  export CANCCU_ROOT=$W/$1/root CANCCU_PROJECT=sandbox SCENARIO_DIR=$W/$1/scenario
  export CANCCU_HOME=$CANCCU_ROOT/projects/sandbox
  CLONE=$W/$1/code/sandbox
  mkdir -p "$CANCCU_HOME/state" "$SCENARIO_DIR" "${CLONE%/*}"
  : > "$SCENARIO_DIR/engine.log"; : > "$SCENARIO_DIR/issues"; : > "$SCENARIO_DIR/script"
  must git clone -q "$CLONE_URL" "$CLONE" || return 1
  # the reviewer's verdicts are posted as the same login that runs the suite: the token file is
  # the login's own token, mode 600, inside the temp dir the run removes
  ( umask 077; gh auth token > "$W/$1/token" 2>/dev/null ) || : > "$W/$1/token"
  # the scenarios were written against the defaults before #242: they pin them (as the harness's
  # OLD_DEFAULTS do)
  { sed "s/@NAME@/sandbox/g" "$root/profiles/default/rules"; echo "REVIEW_LIGHT=0"; } > "$CANCCU_HOME/rules"
  # the temp project runs as the login that runs the suite, as a host on the default login does
  # (#173): ALLOW_DEFAULT_GH_LOGIN, since that login may sit in a keyring, with no config dir to name
  printf '%s\n' "REPO=$REPO" "CLONE=$CLONE" "CAP=3" ALLOW_DEFAULT_GH_LOGIN=1 "USER_LOGIN=$LOGIN" "REVIEWER_LOGIN=$LOGIN" \
    "REVIEWER_TOKEN_FILE=$W/$1/token" "DIGEST_HOUR_UTC=24" 'ADD_DIRS=""' \
    STEP_DEEP_REVIEW=0 DEEP_REVIEW_EFFORT=high "STEP_TAG=''" BUDGET_LINES=0 PACE=off CADENCE_DAYS=0 FIXCHECK_COUNT_RESOLVED=0 \
    > "$CANCCU_HOME/config"
}

# reset: close every open PR (its branch deleted), every open issue labelled scenario and every
# open dispatcher claim, delete every branch but main (an earlier run's package branch, pkg-1-*,
# would reject this run's first push), then move main back to the tag scenario-base: the one
# force-push of the suite, to the sandbox only
reset() {
  local n
  for n in $(gh pr list -R "$REPO" -s open -L 100 --json number -q '.[].number'); do
    gh pr close "$n" -R "$REPO" --delete-branch >/dev/null 2>&1
  done
  # the dispatcher claims too: each scenario's home is a host of its own, and an earlier one's
  # fresh claim would leave this one doing nothing for CLAIM_EXPIRY_MIN
  for n in $(gh issue list -R "$REPO" -s open -l scenario -L 100 --json number -q '.[].number') \
           $(gh issue list -R "$REPO" -s open -l dispatcher-claim -L 100 --json number -q '.[].number'); do
    gh issue close "$n" -R "$REPO" >/dev/null 2>&1
  done
  must git -C "$CLONE" fetch -q origin tag scenario-base &&
    must git -C "$CLONE" push -q --force origin 'scenario-base^{commit}:refs/heads/main' &&
    must git -C "$CLONE" fetch -q --prune origin || return 1
  local b
  for b in $(git -C "$CLONE" for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin); do
    case $b in main|HEAD) ;; *) must git -C "$CLONE" push -q origin --delete "$b" || return 1 ;; esac
  done
}

# new_issue <title> [gh issue create flags...]: a ready issue of this scenario; echoes its number
new_issue() {
  local t=$1 url; shift
  url=$(must gh issue create -R "$REPO" --title "scenario $SCENARIO: $t" --label scenario --label ready \
          --body "A scenario of tests/scenarios: $t." "$@") || return 1
  echo "${url##*/}" >> "$SCENARIO_DIR/issues"; echo "${url##*/}"
}

# world: the scenario's issues and every PR, read once per check into $SCENARIO_DIR/world.json
world() {
  local is ps
  is=$(gh issue list -R "$REPO" -s all -l scenario -L 100 --json number,state,labels,comments) || return 1
  # 40 PRs at most: each one's commits and their authors count against GitHub's limit of 500,000
  # GraphQL nodes (100 x 100 x 100 at -L 100); a scenario's own PRs are the newest
  ps=$(gh pr list -R "$REPO" -s all -L 40 --json number,state,mergedAt,headRefName,isDraft,body,commits) || return 1
  jq -n --argjson is "$is" --argjson ps "$ps" --argjson mine "$(jq -s . "$SCENARIO_DIR/issues")" '
    ($is | map(select(.number as $n | $mine | index($n)))) as $own
    | {issues: $own, mine: $mine,
       prs: [$ps[] | select(.body // "" | [scan("#([0-9]+)")[0] | tonumber] | any(. as $n | $mine | index($n)))]}' \
    > "$SCENARIO_DIR/world.json"
}

# q <jq>: the jq filter holds on world.json (with the helpers below); expect <why> <jq>: else say why
q() {
  jq -e '
    def issue($n): .issues[] | select(.number == $n);
    def labelled($l): [.labels[].name] | index($l) != null;
    def closed: .state == "CLOSED";
    def merged: .state == "MERGED";
    def said($t): [.comments[].body] | any(contains($t));
    '"$1" "$SCENARIO_DIR/world.json" >/dev/null 2>&1
}
expect() { q "$2" || { WHY=$1; return 1; }; }

# ran <pattern>: how many fake-engine runs match (lines "<role> <round> <key> <action>")
ran() { grep -cE "$1" "$SCENARIO_DIR/engine.log" 2>/dev/null; }
# once <mark> <cmd...>: run cmd the first time only (a scenario's tick acts once)
once() { local m=$SCENARIO_DIR/once-$1; shift; [ -e "$m" ] && return 0; "$@" && : > "$m"; }

# push_main <path> <text>: a commit on the sandbox's main, from the scenario's clone
push_main() {
  git -C "$CLONE" fetch -q origin && git -C "$CLONE" checkout -q --detach origin/main &&
    mkdir -p "$CLONE/${1%/*}" && echo "$2" > "$CLONE/$1" && git -C "$CLONE" add "$1" &&
    git -C "$CLONE" -c user.name=scenario -c user.email=scenario@users.noreply.github.com commit -qm "scenario: main moves ($1)" &&
    git -C "$CLONE" push -q origin HEAD:refs/heads/main
}
