#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/lib/harness.sh — the setup, fakes and helpers every tests/canccu-*.sh sources first.
# Each test file ends with its own summary line.
# A fake gh, worker, git and tmux go first on PATH: gh answers from canned JSON per test and
# records every call, so nothing reaches GitHub, the real worker engine or the user's tmux.
#   bash tests/canccu-dispatch.sh        prints one line per failure and a summary; exit 1 on failure
#   KEEP=1 bash tests/canccu-dispatch.sh keeps the temp dir (one subdir per test) for debugging
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d); trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
fb=$T/fakebin; mkdir -p "$fb"
npass=0 nfail=0 tname=""
NOW=$(date -u -d 2030-11-05T12:00:00Z +%s)
export FAKE_PID=$$
HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1111 HB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2222
HC=cccccccccccccccccccccccccccccccccccc3333 BOT=review-bot
export FAKE_MERGED=dddddddddddddddddddddddddddddddddddd4444   # the fake git's head after a merge of main
FAKE_TOKEN=fake-reviewer-token-for-tests
export FAKE_BOT=$BOT
# the venv with rich for the monitor tests (CANCCU_VENV, else the usual one); unset afterwards, so
# no command under test sees it
MON_VENV=${CANCCU_VENV:-$HOME/.local/share/canccu/venv}; unset CANCCU_VENV
# the caller's gh login, tokens and git config never reach a test: a canccu tmux session sets
# GH_CONFIG_DIR= and GIT_CONFIG_COUNT= (empty), and a test sets what it needs itself
unset GH_CONFIG_DIR CANCCU_GH_OWNER GH_TOKEN GITHUB_TOKEN "${!GIT_CONFIG_@}"

# ---------------------------------------------------------------- fakes

cat > "$fb/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: reads "<glob><TAB><file>" routes (test routes first, then defaults); first match on
# "$*" wins. A file named FAIL makes the call fail. Writes always succeed unless a route
# "fail:<cmd sub>" exists. Every call is appended to gh.log on one line, and the identity it ran
# as (user: no GH_TOKEN; reviewer: the fake reviewer token; other) to gh.env, never the token.
a="$*"; printf '%s\n' "${a//$'\n'/ }" >> "$FAKE/gh.log"
{ tok=$(< "$FAKE/../reviewer-token"); } 2>/dev/null
if [ -z "${GH_TOKEN:-}" ]; then id=user; elif [ "$GH_TOKEN" = "$tok" ]; then id=reviewer; else id=other; fi
printf '%s %s\t%s\n' "$1" "$2" "$id" >> "$FAKE/gh.env"
# the config dir it ran with (a project's own login), and its git credential config count
printf '%s %s\t%s\n' "$1" "$2" "${GH_CONFIG_DIR:-<default>}" >> "$FAKE/gh.cfg"
# `gh auth token`: like gh, the token of the config dir's hosts.yml, else fail. `gh api
# repos/<o>/<r>` (the reach check): fails when the config dir holds a file noreach.
if [ "$1 $2" = "auth token" ]; then
  [ -n "${GH_CONFIG_DIR:-}" ] && [ -s "$GH_CONFIG_DIR/hosts.yml" ] || { echo "no oauth token found for github.com" >&2; exit 1; }
  sed -n 's/^ *oauth_token: //p' "$GH_CONFIG_DIR/hosts.yml"; exit 0
fi
if [ "$1" = api ] && [[ $2 =~ ^repos/[^/]+/[^/]+$ ]]; then
  [ -e "${GH_CONFIG_DIR:-/nonexistent}/noreach" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  [ -e "${GH_CONFIG_DIR:-/nonexistent}/down" ] && { echo "dial tcp: lookup api.github.com: no such host" >&2; exit 1; }
  # $FAKE/repo.json: the repo's settings (allow_auto_merge), for a read with --jq; without it the
  # answer is the reach check's, which names no setting
  [ -e "$FAKE/repo.json" ] && [ "${3:-}" = --jq ] && { jq -r "$4" "$FAKE/repo.json"; exit; }
  echo "${2#repos/}"; exit 0
fi
q="" args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do case ${args[i]} in -q|--jq) q=${args[i+1]} ;; esac; done
{ routes=$(< "$FAKE/routes"); routes+=$'\n'$(< "$FAKE/routes.default"); } 2>/dev/null
case "$1 $2" in
  "issue edit"|"issue comment"|"issue close"|"pr edit"|"pr merge"|"pr comment"|"label create")
    grep -qxF "fail:$1 $2" <<<"$routes" && exit 1
    grep -qxF "fail124:$1 $2" <<<"$routes" && exit 124
    # $FAKE/merge-error: a merge fails with that error, as gh prints it
    [ "$1 $2" = "pr merge" ] && [ -e "$FAKE/merge-error" ] && { cat "$FAKE/merge-error" >&2; exit 1; }
    # $FAKE/no-auto-merge: the repo does not allow auto-merge (a private repo on a free plan)
    if [ -e "$FAKE/no-auto-merge" ] && [ "$1 $2" = "pr merge" ] && [[ " $* " == *" --auto "* ]]; then
      echo "GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)" >&2; exit 1
    fi
    # a posted review (--body-file -) is kept, and shows up in the PR's comments like on GitHub
    # (each one a second later than the one before)
    if [ "$1 $2" = "pr comment" ] && [[ " $* " == *" --body-file - "* ]]; then
      body=$(cat); printf '%s\n' "$body" > "$FAKE/posted-$3"
      u=octo; [ "$id" = reviewer ] && u=$FAKE_BOT
      f="$FAKE/pr$3.json"
      [ -e "$f" ] && jq --arg b "$body" --arg u "$u" \
        '.comments += [{author: {login: $u}, createdAt: "2030-11-05T12:05:\(.comments | length + 10)Z", body: $b}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    # $FAKE/comment-urls: an issue comment prints its link, like the real gh
    [ -e "$FAKE/comment-urls" ] && [ "$1 $2" = "issue comment" ] && echo "https://github.com/example-org/web/issues/$3#issuecomment-$3"
    # $FAKE/noisy: a write prints like the real gh does (URLs on stdout, notes on stderr)
    [ -e "$FAKE/noisy" ] && { echo "https://github.com/example-org/web/issues/$3"; echo "✓ Pull request example-org/web#$3 will be added to the merge queue" >&2; }
    exit 0 ;;
esac
while IFS=$'\t' read -r pat file; do
  [ -n "$file" ] || continue
  # shellcheck disable=SC2053
  [[ $a == $pat ]] || continue
  [ "$file" = FAIL ] && { echo "fake gh: failing $a" >&2; exit 1; }
  if [ -n "$q" ]; then jq -r "$q" "$FAKE/$file"; else cat "$FAKE/$file"; fi
  exit
done <<<"$routes"
echo "fake gh: no route for: $a" >&2; exit 1
EOF
cat > "$fb/worker" <<'EOF'
#!/usr/bin/env bash
# fake run engine: records the call and its whole environment; a start writes a live lock (pid
# of the test run). --kill records the issue's phase at that moment.
a="$*"; printf '%s\n' "${a//$'\n'/ }" >> "$FAKE/worker.log"
echo "GH_TOKEN=${GH_TOKEN:-<unset>} GITHUB_TOKEN=${GITHUB_TOKEN:-<unset>} WORKER_GH_TOKEN_FILE=${WORKER_GH_TOKEN_FILE:-<unset>} REVIEWER_TOKEN_FILE=${REVIEWER_TOKEN_FILE:-<unset>}" >> "$FAKE/worker.env"
{ echo "=== $a"; env; } >> "$FAKE/worker.envdump"
echo "fds: $(ls /proc/$$/fd | tr '\n' ' ')" >> "$FAKE/worker.fds"
case $1 in
  --kill) k=${3#review-}; k=${k#answer-}
          echo "$3 phase=$(sed -n 's/^phase=//p' "$CANCCU_HOME/state/$k" 2>/dev/null | tail -1)" >> "$FAKE/kill.log"
          rm -f "$WORKERS_DIR/$2-$3.lock"; exit 0 ;;
  --unlock) rm -f "$WORKERS_DIR/$2-$3.lock"; exit 0 ;;
esac
key=""
while [[ $1 == --* ]]; do
  case $1 in --key) key=$2; shift 2 ;; --dir|--name|--model|--effort) shift 2 ;; *) shift ;; esac
done
repo=$1; shift
[ -n "$key" ] || key=${1%% *}
[ -e "$FAKE/refuse" ] && { echo "refused: cap reached" >&2; exit 2; }
[ -e "$FAKE/refuse-$key" ] && { echo "refused: $key" >&2; exit 2; }   # this run only
printf 'repo=%s\nkey=%s\nkind=worker\npid=%s\nwindow=\nstarted=%s\n' "$repo" "$key" "$FAKE_PID" "$(date +%s)" \
  > "$WORKERS_DIR/$repo-$key.lock"
EOF
cat > "$fb/git" <<'EOF'
#!/usr/bin/env bash
# fake git: records the call; `diff --numstat` prints $FAKE/numstat (fails without it)
a="$*"; printf '%s\n' "$a" >> "$FAKE/git.log"
printf '%s\t%s\t%s\n' "${GH_CONFIG_DIR:-<default>}" "${GIT_CONFIG_COUNT:-<unset>}" "$a" >> "$FAKE/git.cfg"
case " $a " in *" diff --numstat "*) cat "$FAKE/numstat" 2>/dev/null || exit 128 ;; esac
# a worktree's branch (branch --show-current: $FAKE/branch), how far main is ahead (rev-list
# --count: $FAKE/behind), its commits (log --oneline: $FAKE/gitlog); $FAKE/merge-conflict: a merge
# of main fails, and diff --diff-filter=U lists that file's lines as the conflicting paths;
# $FAKE/dirty: status --porcelain prints it; $FAKE/push-fail: a push is rejected
case " $a " in
  *" status --porcelain "*) [ -e "$FAKE/dirty" ] && cat "$FAKE/dirty" ;;
  *" push origin HEAD:"*) [ -e "$FAKE/push-fail" ] && { echo "remote: rejected by a pre-receive hook" >&2; exit 1; } ;;
  *" branch --show-current "*) [ -e "$FAKE/branch" ] && cat "$FAKE/branch" ;;
  *" rev-list --count "*) [ -e "$FAKE/behind" ] && cat "$FAKE/behind" ;;
  *" log --oneline "*) [ -e "$FAKE/gitlog" ] && cat "$FAKE/gitlog" ;;
  *" rev-parse HEAD "*) [ -e "$FAKE/branch" ] && echo "$FAKE_MERGED" ;;
  *" merge --no-edit "*) [ -e "$FAKE/merge-conflict" ] && exit 1 ;;
  *" --diff-filter=U "*) [ -e "$FAKE/merge-conflict" ] && cat "$FAKE/merge-conflict" ;;
esac
# $FAKE/noisy: the branch is named, and writes print like the real git does
if [ -e "$FAKE/noisy" ]; then
  case " $a " in
    *" branch --show-current "*) echo "warning: noisy git" >&2; case $a in *worktrees*) echo issue-5-thing ;; *) echo main ;; esac ;;
    *" branch -D "*) echo "Deleted branch issue-5-thing (was 1234567)." ;;
    *" pull "*) echo "Updating 1234567..89abcde" ; echo "From github.com:example-org/web" >&2 ;;
  esac
fi
exit 0
EOF
printf '#!/bin/sh\nexit 1\n' > "$fb/tmux"
# a fake claude for the real engine: records the identity it sees, its arguments and its whole
# environment, and prints a successful result. Like Claude Code, it runs the checkout's project
# hook (.claude/hook.sh, standing in for a hook in .claude/settings.json) unless project settings
# are off (--setting-sources user).
cat > "$fb/claude" <<'EOF'
#!/bin/bash
echo "GH_TOKEN=${GH_TOKEN:-<unset>} GITHUB_TOKEN=${GITHUB_TOKEN:-<unset>}" >> "$FAKE/claude.env"
echo "$*" >> "$FAKE/claude.args"
{ echo "=== claude"; env; } >> "$FAKE/claude.envdump"
if [ -f .claude/settings.json ] && [ -f .claude/hook.sh ] && [[ " $* " != *" --setting-sources user "* ]]; then
  sh .claude/hook.sh
fi
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0,"result":"ok"}'
EOF
chmod +x "$fb"/*
# a recording tmux for the real engine's spawn: has-session succeeds, new-window prints an id
mkdir -p "$T/tmuxrec"
cat > "$T/tmuxrec/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE/tmux.log"
# $FAKE/no-server: no tmux server yet; new-session records the environment it would start with
case $1 in
  has-session) [ -e "$FAKE/no-server" ] && exit 1 ;;
  new-session) env > "$FAKE/tmux.start-env" ;;
esac
case $1 in new-window|new-session) echo @9 ;; esac
exit 0
EOF
chmod +x "$T/tmuxrec/tmux"

# ---------------------------------------------------------------- helpers

# env_new <name> [config lines...]: a fresh CANCCU_HOME and fixture dir for one test
env_new() {
  tname=$1; shift
  E=$T/$tname; export CANCCU_ROOT=$E/root CANCCU_PROJECT=web FAKE=$E/fake CANCCU_NOW=$NOW
  # the suite runs on the invented project web, whose rules set every key
  export CANCCU_HOME=$CANCCU_ROOT/projects/web WORKERS_DIR=$CANCCU_ROOT/projects/web/workers
  mkdir -p "$CANCCU_HOME/state" "$FAKE" "$WORKERS_DIR" "$E/code/web"
  cp "$root/tests/fixtures/rules/web" "$CANCCU_HOME/rules"
  {
    echo "REPO=example-org/web"; echo "CLONE=$E/code/web"; echo "CAP=3"; echo "USER_LOGIN=octo"; echo 'ADD_DIRS=""'; echo "REVIEWER_LOGIN=review-bot"
    echo "DIGEST_HOUR_UTC=24"; echo "DIGEST_ISSUE=42"; echo "AUTO_MERGE_UNTIL=2031-03-01"
    echo "REVIEWER_TOKEN_FILE=$E/reviewer-token"
    printf '%s\n' "$@"
  } > "$CANCCU_HOME/config"
  printf '%s\n' "$FAKE_TOKEN" > "$E/reviewer-token"; chmod 600 "$E/reviewer-token"
  jq -n --arg l "$BOT" '{login: $l}' > "$FAKE/user.json"
  printf '%s\t%s\n' \
    'api repos/example-org/web/milestones*' ms.json  'issue list -R example-org/web -s all -l checkpoint*' cps.json \
    'issue list*' issues.json  'pr list -R example-org/web -s open*' prs.json  'label list*' labels.json \
    'api repos/example-org/web/issues/*/dependencies/blocked_by' empty.json \
    'api repos/example-org/web/issues/*/dependencies/blocking' empty.json \
    'run list*' runs.json  'api user*' user.json > "$FAKE/routes.default"
  echo '[]' > "$FAKE/ms.json"; echo '[]' > "$FAKE/cps.json"; echo '[]' > "$FAKE/empty.json"; echo '[]' > "$FAKE/issues.json"; echo '[]' > "$FAKE/prs.json"; echo '[]' > "$FAKE/runs.json"
  jq -n '["ready","blocked","in-progress","epic","needs-you","plan-ok","awaiting-accept","needs-work","accepted","manual-accept","checkpoint","checkpoint-ok","fast"] | map({name: .})' \
    > "$FAKE/labels.json"
  : > "$FAKE/routes"; : > "$FAKE/gh.log"; : > "$FAKE/worker.log"
}
route() { printf '%s\t%s\n' "$1" "$2" >> "$FAKE/routes"; }
json() { printf '%s\n' "$2" > "$FAKE/$1"; }

# issue <n> <labels,comma> [body] [milestone title]
issue() {
  jq -n --argjson n "$1" --arg l "${2:-}" --arg b "${3:-}" --arg m "${4:-}" \
    '{number: $n, title: "Issue \($n)", labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
      body: $b, milestone: (if $m == "" then null else {title: $m} end)}'
}
issues() { jq -s . > "$FAKE/issues.json"; }
# pr <n> <closes> <head> [ci green|red|pending|none] [labels] [draft] [body]: by USER_LOGIN (octo), from
# branch <closes>-thing in the repo; PR_AUTHOR, PR_FORK=true and PR_BRANCH override that
pr() {
  jq -n --argjson n "$1" --argjson c "$2" --arg h "$3" --arg ci "${4:-green}" --arg l "${5:-}" \
        --argjson d "${6:-false}" --arg b "${7:-}" --arg au "${PR_AUTHOR:-octo}" --argjson fk "${PR_FORK:-false}" \
        --arg br "${PR_BRANCH:-$2-thing}" \
    '{number: $n, title: "PR \($n)", url: "https://github.com/example-org/web/pull/\($n)", isDraft: $d, headRefOid: $h,
      labels: ($l | split(",") | map(select(. != "")) | map({name: .})), closingIssuesReferences: [{number: $c}],
      author: {login: $au}, isCrossRepository: $fk, headRefName: $br, autoMergeRequest: null,
      body: $b, state: "OPEN",
      statusCheckRollup: (if $ci == "none" then []
        elif $ci == "pending" then [{name: "test", status: "IN_PROGRESS", conclusion: "", startedAt: "2030-11-05T10:00:00Z"}]
        else [{name: "test", status: "COMPLETED", conclusion: (if $ci == "green" then "SUCCESS" else "FAILURE" end),
          completedAt: "2030-11-05T10:00:00Z"}] end)}'
}
prs() { jq -s . > "$FAKE/prs.json"; }
# detail <pr json> <commit date> [comment json...]: the `gh pr view` answer
detail() {
  local p=$1 d=$2; shift 2
  jq --arg d "$d" --argjson cs "$(printf '%s\n' "$@" | jq -s .)" \
    '. + {commits: [{oid: .headRefOid, committedDate: $d}], comments: $cs}' <<<"$p"
}
comment() { jq -n --arg t "$1" --arg b "$2" --arg u "${3:-octo}" '{author: {login: $u}, createdAt: $t, body: $b}'; }
vcomment() { comment "$1" "$2" "$BOT"; }   # a comment by the reviewer bot
state() { local n=$1; shift; printf '%s\n' "$@" > "$CANCCU_HOME/state/$n"; }
st() { sed -n "s/^$2=//p" "$CANCCU_HOME/state/$1" 2>/dev/null | tail -1; }
live_lock() { printf 'repo=web\nkey=%s\nkind=worker\npid=%s\nwindow=\nstarted=%s\n' "$1" "$$" "$NOW" > "$WORKERS_DIR/web-$1.lock"; }
# last <key> <status> [message]: an engine exit report written after the run started
last() {
  printf 'r#%s · "prompt · with dots" · %s · 12 turns · $1.00 · 3m00s\n\n%s\n' "$1" "$2" "${3:-report}" > "$WORKERS_DIR/web-$1.last"
  touch -d "@$((NOW + 60))" "$WORKERS_DIR/web-$1.last"
}

dispatch() { PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" "$@" > "$E/out" 2>&1; }
lib() { ( PATH="$fb:$PATH"; CANCCU_WORKER="$fb/worker"; . "$root/lib/canccu-common.sh"; "$@" ) 2>/dev/null; }
not() { ! "$@"; }
# dead <pid>: gone or a zombie (a killed child of this shell stays a zombie until waited for)
dead() { local st; st=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1); [ -z "$st" ] || [ "$st" = Z ]; }

ok() {   # ok <description> <command...>
  if "${@:2}"; then npass=$((npass + 1)); else nfail=$((nfail + 1)); echo "FAIL [$tname] $1"; fi
}
eq() { [ "$1" = "$2" ] || { echo "    expected: $2"; echo "    got:      $1"; return 1; }; }
has() { grep -qF -- "$2" "$FAKE/$1" || { echo "    $1 lacks: $2"; return 1; }; }
hasnt() { ! grep -qF -- "$2" "$FAKE/$1" || { echo "    $1 has: $2"; return 1; }; }
# pissues [n]: the issues the n-th (default: the last) planner run of step 12 was given in its prompt
pissues() { grep -- '--key plan-12' "$FAKE/worker.log" | sed -n "${1:-\$}p" | grep -o 'The issues to plan are exactly: [^.]*' | sed 's/^The issues to plan are exactly: //'; }
started() { grep -E "^--quiet --name #$1 web $1 " "$FAKE/worker.log" >/dev/null; }

# ---------------------------------------------------------------- shared by several test files

# the projects fixtures (tests/canccu-projects.sh, tests/canccu-share.sh)
# prepo <project>: its invented repo (tools is a user's, the others an organisation's)
prepo() { if [ "$1" = tools ]; then echo example-user/tools; else echo "example-org/$1"; fi; }
# penv <name> <project...>: a CANCCU_ROOT with those projects, each on the generic template's
# rules: REPO $(prepo <p>), CLONE code/<p>, its own fixtures issues-<p>.json and prs-<p>.json
penv() {
  tname=$1; shift; E=$T/$tname
  unset CANCCU_PROJECT CANCCU_HOME WORKERS_DIR
  export CANCCU_ROOT=$E/root FAKE=$E/fake CANCCU_NOW=$NOW
  mkdir -p "$FAKE" "$CANCCU_ROOT/projects"
  printf '%s\n' "$FAKE_TOKEN" > "$E/reviewer-token"; chmod 600 "$E/reviewer-token"
  jq -n --arg l "$BOT" '{login: $l}' > "$FAKE/user.json"
  echo '[]' > "$FAKE/empty.json"; echo '[]' > "$FAKE/runs.json"
  jq -n '["ready","blocked","in-progress","epic","needs-you","plan-ok","awaiting-accept","needs-work","accepted","manual-accept","checkpoint","checkpoint-ok","fast"] | map({name: .})' \
    > "$FAKE/labels.json"
  : > "$FAKE/routes"; : > "$FAKE/gh.log"; : > "$FAKE/worker.log"; : > "$FAKE/routes.default"
  for p; do
    mkdir -p "$CANCCU_ROOT/projects/$p/state" "$CANCCU_ROOT/projects/$p/workers" "$E/code/$p"
    { echo "REPO=$(prepo "$p")"; echo "CLONE=$E/code/$p"; echo "USER_LOGIN=octo"; echo "REVIEWER_LOGIN=review-bot"; echo "DIGEST_HOUR_UTC=24"
      echo "REVIEWER_TOKEN_FILE=$E/reviewer-token"; } > "$CANCCU_ROOT/projects/$p/config"
    sed "s/@NAME@/$p/g" "$root/profiles/default/rules" > "$CANCCU_ROOT/projects/$p/rules"
    echo '[]' > "$FAKE/issues-$p.json"; echo '[]' > "$FAKE/prs-$p.json"
    printf '%s\t%s\n' "issue list -R $(prepo "$p") *" "issues-$p.json" "pr list -R $(prepo "$p") -s open*" "prs-$p.json" \
      'label list*' labels.json 'api repos/*/dependencies/*' empty.json 'run list*' runs.json 'api user*' user.json \
      >> "$FAKE/routes.default"
  done
}
pconf() { local p=$1; shift; printf '%s\n' "$@" >> "$CANCCU_ROOT/projects/$p/config"; }
projissues() { local p=$1; shift; for n; do issue "$n" ready; done | jq -s . > "$FAKE/issues-$p.json"; }
pstarted() { grep -qE "^--quiet --name #$2 $1 $2 " "$FAKE/worker.log"; }
plib() { local p=$1; shift; ( PATH="$fb:$PATH"; . "$root/lib/canccu-common.sh" --project "$p"; "$@" ) 2>&1; }

# src_copy <dir> [version]: the repo's tree (tracked and new files, no .git) copied to dir, as a
# release tarball unpacks; with a version, that is its VERSION
src_copy() {
  mkdir -p "$1" && (cd "$root" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$1" 2>/dev/null)
  [ -z "${2:-}" ] || echo "$2" > "$1/VERSION"
}

# notoken <files...>: neither the fake token nor the token file's path appears in them
notoken() { ! grep -rqF -e "$FAKE_TOKEN" -e "$E/reviewer-token" "$@" 2>/dev/null; }
c() { lib classify_pure "$@"; }

review_env() {   # review_env <name> <verdict line> <stage> [config...]: a posted verdict on HA
  env_new "$1" "${@:4}"
  { issue 5 in-progress; } | issues
  p=$(pr 50 5 $HA); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z "$(vcomment 2030-11-05T11:00:00Z $'1. src/a.ts:3 off by one; fix: use <=\n\n'"$2 $HA")")"
  route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
  state 5 phase=review pr=50 review_sha=$HA "stage=$3"
}

effenv() {   # effenv <name> <files json> <pr body>: PR 50 of managed issue 5 waits for its review
  env_new "$1"
  { issue 5 in-progress; } | issues
  p=$(pr 50 5 $HA green "" false "$3"); printf '%s\n' "$p" | prs
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  json files50.json "$2"; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  state 5 phase=check "check_at=$NOW" pr=50
}

# ---------------------------------------------------------------- the fix-check fixtures

# used by tests/canccu-review.sh and tests/canccu-review2.sh; FINDING: the full review's finding on HA
FINDING='1. src/a.ts:3 off by one; fix: use <='
# sethead <sha>: the PR moves to a new head (the posted comments stay)
sethead() {
  pr 50 5 "$1" | prs
  jq --arg h "$1" '.headRefOid = $h | .commits = [{oid: $h, committedDate: "2030-11-05T12:30:00Z"}]' "$FAKE/pr50.json" > "$FAKE/x" &&
    mv "$FAKE/x" "$FAKE/pr50.json"
}
# fxenv <name> <fix-check comment | -> [config...]: a fix-check of HA..HB ran on PR 50 (head HB)
fxenv() {
  env_new "$1" "${@:3}"
  { issue 5 in-progress; } | issues
  p=$(pr 50 5 $HB); printf '%s\n' "$p" | prs
  local cs=("$(vcomment 2030-11-05T11:00:00Z "$FINDING"$'\n\nReview verdict: changes '"$HA")")
  [ "$2" != - ] && cs+=("$(vcomment 2030-11-05T11:30:00Z "$2")")
  json pr50.json "$(detail "$p" 2030-11-05T11:20:00Z "${cs[@]}")"; route 'pr view 50 *' pr50.json
  json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
  json issue5.json '{"labels": [{"name": "in-progress"}], "comments": []}'; route 'issue view 5 *' issue5.json
  mkdir -p "$CANCCU_HOME/reviews/50"; echo "$FINDING" > "$CANCCU_HOME/reviews/50/$HA.findings.md"
  state 5 phase=review pr=50 review_sha=$HB stage=fixcheck review_mode=fixcheck reviewed_sha=$HA \
    verdict_at=2030-11-05T11:00:00Z "started=$NOW"
}
