#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-openpr.sh — offline tests for the PR the dispatcher opens when a worker pushed its
# branch but opened none (#237): the body from the worker's body file or from the issue, the log
# and the PR saying so, and needs-you without a pushed branch or commits ahead. Harness:
# tests/lib/harness.sh.
#   bash tests/canccu-openpr.sh   one line per failure and a summary; exit 1 on failure
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# wrappers before the fake gh and git: a PR create makes the PR show up in the next list and
# keeps its body; $FAKE/fetch-fail: the branch is not on origin
sb=$T/openpr-bin; mkdir -p "$sb"
cat > "$sb/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr create" ]; then
  cp "\$FAKE/prs-next.json" "\$FAKE/prs.json"
  for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = --body ] && { j=\$((i + 1)); printf '%s\n' "\${!j}" > "\$FAKE/pr-body"; }; done
fi
exec "$fb/gh" "\$@"
EOF
cat > "$sb/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" fetch "*) [ -e "\$FAKE/fetch-fail" ] && { printf '%s\n' "\$*" >> "\$FAKE/git.log"; exit 1; } ;; esac
exec "$fb/git" "\$@"
EOF
chmod +x "$sb/gh" "$sb/git"
opass() { PATH="$sb:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1; }
dlog() { grep -cF -- "$1" "$CANCCU_HOME/dispatch.log"; }

# oenv <name> <run message>: issue 5's worker ended with no PR; its worktree is on 5-thing, pushed
# with 2 commits ahead of main; once created, the PR is #50 at the worktree's head
oenv() {
  env_new "$1"
  issue 5 in-progress | issues; echo '[]' > "$FAKE/prs.json"
  p=$(pr 50 5 "$FAKE_MERGED"); printf '%s\n' "$p" | jq -s . > "$FAKE/prs-next.json"
  json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
  echo https://github.com/example-org/web/pull/50 > "$FAKE/prurl"; route 'pr create*' prurl
  wt=$WORKERS_DIR/worktrees/web/issue-5; mkdir -p "$wt"; : > "$wt/.git"
  echo 5-thing > "$FAKE/branch"; echo 2 > "$FAKE/behind"
  state 5 phase=work "started=$NOW"; last 5 done "$2"
}
DEN=$'Could not open the PR.\n\nPermission denials (information):\nBash gh pr create --title "Fix it" --body-file pr-body.md'
MARK='<!-- canccu-dispatch -->'

# ---------------------------------------------------------------- gh pr create denied: the dispatcher opens it

oenv openpr-file "$DEN"
printf '%s\n' 'Closes #5' '' 'Tier: fix' 'Testing: from the body file' > "$wt/pr-body.md"; echo '?? pr-body.md' > "$FAKE/dirty"
opass
ok "denied gh pr create, branch pushed with commits → the dispatcher opens the PR from it" \
  eq "$(grep -cE '^pr create -R example-org/web --base main --head 5-thing --title Issue 5 --body Closes #5  Tier: fix ' "$FAKE/gh.log")" 1
ok "… its body is the worker's body file, then the dispatcher's line" \
  eq "$(cat "$FAKE/pr-body")" "$(printf '%s\n' 'Closes #5' '' 'Tier: fix' 'Testing: from the body file' '' \
    "The dispatcher opened this PR: the worker pushed \`5-thing\` but did not open it (its \`gh pr create\` was denied). $MARK")"
ok "… the log says the dispatcher opened it" eq "$(dlog '#5 the worker pushed 5-thing (2 commit(s)) but opened no PR; the dispatcher opened PR #50')" 1
ok "… the body file is not work the PR lacks: the review follows, no needs-you" \
  eq "$(dlog '#5 worker done') $(grep -c 'needs-you' "$FAKE/gh.log")" "1 0"
ok "… and the review of PR #50 follows" eq "$(st 5 phase) $(st 5 pr)" "review 50"

# a body file outside the worktree is never read: the body is built from the issue
oenv openpr-outside "$(printf '%s\n' 'Status: done' '- Testing: tests/web.sh failed before, passes now' 'Revert: plain revert' '' "${DEN/pr-body.md/../../secret.md}")"
printf 'secret\n' > "$WORKERS_DIR/worktrees/secret.md"
opass
ok "a body file outside the worktree → the body from the issue: Closes, the run's Testing: and Revert:" \
  eq "$(cat "$FAKE/pr-body")" "$(printf '%s\n' 'Closes #5' '' 'Testing: tests/web.sh failed before, passes now' 'Revert: plain revert' '' \
    "The dispatcher opened this PR: the worker pushed \`5-thing\` but did not open it (its \`gh pr create\` was denied). $MARK")"

oenv openpr-draft "${DEN/--title/--draft --title}"
opass
ok "a denied draft PR is opened as a draft" grep -q ' was denied)\. <!-- canccu-dispatch --> --draft$' "$FAKE/gh.log"

# ---------------------------------------------------------------- needs-you stays: nothing to open

oenv openpr-ahead0 "$DEN"; echo 0 > "$FAKE/behind"
opass
ok "no commits ahead of main → needs-you, no PR opened" \
  eq "$(dlog "#5 needs-you: the worker's run was denied commands and opened no PR") $(grep -c '^pr create' "$FAKE/gh.log")" "1 0"
oenv openpr-unpushed "$DEN"; : > "$FAKE/fetch-fail"
opass
ok "the branch not on origin → needs-you, no PR opened" \
  eq "$(dlog "#5 needs-you: the worker's run was denied commands and opened no PR") $(grep -c '^pr create' "$FAKE/gh.log")" "1 0"
oenv openpr-otherbranch "$DEN"; echo main > "$FAKE/branch"
opass
ok "a worktree on a branch that is not the issue's → needs-you, no PR opened" \
  eq "$(dlog "#5 needs-you: the worker's run was denied commands and opened no PR") $(grep -c '^pr create' "$FAKE/gh.log")" "1 0"

# ---------------------------------------------------------------- a done run without a PR, its finish run spent

oenv openpr-finished "Status: done"; state 5 phase=check "check_at=$NOW" finish_tried=1 no_pr=1
opass
ok "finished without a PR, the finish run spent, branch pushed → the dispatcher opens it" \
  eq "$(grep -c '^pr create -R example-org/web --base main --head 5-thing ' "$FAKE/gh.log") $(dlog '#5 the worker pushed 5-thing (2 commit(s)) but opened no PR; the dispatcher opened PR #50')" "1 1"
ok "… its body names no denial" grep -qxF "The dispatcher opened this PR: the worker pushed \`5-thing\` but did not open it. $MARK" "$FAKE/pr-body"
ok "… no needs-you" eq "$(dlog 'needs-you: the worker finished without an open PR')" 0

echo "canccu-openpr tests: $npass passed, $nfail failed"
(( nfail == 0 ))
