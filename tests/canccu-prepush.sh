#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-prepush.sh — the pre-push check of worker worktrees (#328): PRE_PUSH_CMD runs on the
# changed files before every push of a worker, under PRE_PUSH_MAX_SEC; --no-verify is refused; off
# by default (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

env_new prepush
# the real git ahead of the fake one; the fake claude stays
mkdir -p "$E/rg"; ln -s "$FAKE_REAL_GIT" "$E/rg/git"
G() { "$FAKE_REAL_GIT" -c user.name=octo -c user.email=octo@example.com -c init.defaultBranch=main "$@"; }
cl=$E/code/web
G init -q --bare "$E/origin.git"; rm -rf "$cl"; G clone -q "$E/origin.git" "$cl" 2>/dev/null
echo base > "$cl/README.md"; G -C "$cl" add .; G -C "$cl" commit -qm root; G -C "$cl" push -q origin HEAD:main
G -C "$cl" fetch -q origin
# the lint: records its arguments and CANCCU_CHANGED_FILES, fails on a file with LINTERROR
mkdir -p "$E/bin"
cat > "$E/bin/lint-it" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$FAKE/lint.args"; printf '%s' "$CANCCU_CHANGED_FILES" > "$FAKE/lint.env"
for i in $(seq 1 100); do echo "lint: checked line $i"; done
for f; do [[ $f == -* ]] || set -- "$@" "$f"; shift; done
if grep -l LINTERROR "$@" 2>/dev/null; then echo "lint: error: LINTERROR found"; exit 1; fi
echo "lint: clean"
EOF
printf '#!/bin/sh\nsleep 5\n' > "$E/bin/slow-it"; chmod +x "$E/bin/"*
# wrun <key> <dir> [env...]: one worker run (the fake claude) in that worktree
wrun() {
  : > "$FAKE/claude.args"
  printf 'repo=web\nkey=%s\nkind=worker\npid=\nwindow=\n' "$1" > "$WORKERS_DIR/web-$1.lock"
  (cd "$2" && env PATH="$E/rg:$fb:$E/bin:$PATH" CODE_ROOT="$E/code" WORKER_BASE_BRANCH=main "${@:3}" \
    "$root/libexec/canccu-worker" __run web "$1" 5 1 2 "" "build it" "$2" "" 1 > /dev/null 2>&1)
}
wt=$E/wt/pkg-3-pages
G -C "$cl" worktree add -q --detach "$wt" origin/main
wrun pkg-3-pages "$wt" "WORKER_PRE_PUSH_CMD=lint-it --strict" WORKER_PRE_PUSH_MAX_SEC=60
ok "set: the worktree gets a pre-push hook" test -x "$(G -C "$wt" rev-parse --absolute-git-dir)/canccu-hooks/pre-push"
ok "… the clone does not: no hooks path of its own" eq "$(G -C "$cl" config --get core.hooksPath; test -e "$cl/.git/hooks/pre-push" && echo hook)" ""

# push <dir>: a push of the branch; its output in $E/push.out
push() { (cd "$1" && PATH="$E/rg:$E/bin:$PATH" G push origin HEAD:refs/heads/pkg-3-pages > "$E/push.out" 2>&1); }
G -C "$wt" switch -q -c pkg-3-pages
printf 'ok\n' > "$wt/a.txt"; printf 'LINTERROR\n' > "$wt/b c.txt"; G -C "$wt" add .; G -C "$wt" commit -qm two
push "$wt"
ok "a lint error: the push is refused" eq "$?/$(G -C "$cl" ls-remote origin pkg-3-pages | grep -c .)" "1/0"
ok "… with the command's output" grep -q 'lint: error: LINTERROR found' "$E/push.out"
ok "… cut to its end" eq "$(grep -c 'lint: checked line 1$' "$E/push.out") $(grep -c 'lint: checked line 100$' "$E/push.out")" "0 1"
ok "… and what to do" grep -q 'pre-push: PRE_PUSH_CMD failed (exit 1): the push is refused' "$E/push.out"
ok "the command gets the changed paths as arguments" eq "$(cat "$FAKE/lint.args")" "--strict a.txt b c.txt"
ok "… and in CANCCU_CHANGED_FILES, one per line" eq "$(cat "$FAKE/lint.env")" $'a.txt\nb c.txt'
printf 'fixed\n' > "$wt/b c.txt"; G -C "$wt" commit -qam fix
push "$wt"
ok "after the fix the push passes" eq "$?/$(G -C "$cl" ls-remote origin pkg-3-pages | grep -c .)" "0/1"

# the project's own hooks keep running: a pre-commit and a pre-push in the clone's hooks dir
printf '#!/bin/sh\necho ran >> "%s/own-pre-commit"\n' "$E" > "$cl/.git/hooks/pre-commit"
printf '#!/bin/sh\ncat > "%s/own-pre-push.in"; echo "$1" > "%s/own-pre-push.args"\n' "$E" "$E" > "$cl/.git/hooks/pre-push"
chmod +x "$cl/.git/hooks/pre-commit" "$cl/.git/hooks/pre-push"
wrun pkg-3-pages "$wt" "WORKER_PRE_PUSH_CMD=lint-it --strict"
echo own >> "$wt/a.txt"; G -C "$wt" commit -qam own
ok "the project's pre-commit still runs" eq "$(cat "$E/own-pre-commit" 2>/dev/null)" ran
push "$wt"
ok "… and its pre-push, after the check, with git's refs and arguments" \
  eq "$?/$(cut -d' ' -f3 "$E/own-pre-push.in" 2>/dev/null)/$(cat "$E/own-pre-push.args" 2>/dev/null)" "0/refs/heads/pkg-3-pages/origin"
rm -f "$E/own-pre-push.in"; printf 'LINTERROR\n' >> "$wt/a.txt"; G -C "$wt" commit -qam bad
push "$wt"
ok "… but not when the check refuses the push" eq "$?/$(test -e "$E/own-pre-push.in" && echo ran)" "1/"
G -C "$wt" reset -q --hard HEAD~1; rm -f "$cl/.git/hooks/pre-commit" "$cl/.git/hooks/pre-push"

wrun pkg-3-pages "$wt" WORKER_PRE_PUSH_CMD=slow-it WORKER_PRE_PUSH_MAX_SEC=1
echo more >> "$wt/a.txt"; G -C "$wt" commit -qam more
push "$wt"
ok "a command over PRE_PUSH_MAX_SEC: refused, with a timeout line" \
  eq "$?/$(grep -c 'pre-push: PRE_PUSH_CMD timed out after 1 s: the push is refused' "$E/push.out")" "1/1"

wrun pkg-3-pages "$wt"
ok "unset again: the hook is gone" eq "$(G -C "$wt" config --get core.hooksPath; test -e "$(G -C "$wt" rev-parse --absolute-git-dir)/canccu-hooks" && echo left)" ""
wt2=$E/wt/issue-9; G -C "$cl" worktree add -q --detach "$wt2" origin/main
wrun 9 "$wt2"
ok "unset: no hook installed" eq "$(G -C "$wt2" config --get core.hooksPath; test -e "$(G -C "$wt2" rev-parse --absolute-git-dir)/canccu-hooks" && echo hook)" ""
ok "… and no tool guard" not grep -q 'PreToolUse' "$FAKE/claude.args"

# ---------------------------------------------------------------- --no-verify

wrun 9 "$wt2" WORKER_PRE_PUSH_CMD=lint-it
ok "set: the run's tool guard (PreToolUse on Bash)" grep -q '"PreToolUse":\[{"matcher":"Bash"' "$FAKE/claude.args"
guardin() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }
gh_() { guardin "$1" | CANCCU_HOME=$CANCCU_HOME CANCCU_RUN_KEY=9 WORKER_PRE_PUSH_CMD=lint-it "$root/libexec/canccu-guard-hook"; }
ok "git push --no-verify is refused" eq "$(gh_ 'git push --no-verify origin HEAD' | jq -r .hookSpecificOutput.permissionDecision)" deny
ok "… and so is git commit --no-verify, and commit -n" \
  eq "$(gh_ 'cd x && git commit --no-verify -m wip' | jq -r .hookSpecificOutput.permissionDecision) $(gh_ 'git commit -nm wip' | jq -r .hookSpecificOutput.permissionDecision)" "deny deny"
ok "… with the reason" eq "$(gh_ 'git push --no-verify' | jq -r .hookSpecificOutput.permissionDecisionReason)" \
  'Refused: --no-verify skips the pre-push check. A refused push means: fix what it shows first, then push again. Never use `--no-verify`.'
ok "… logged as a warning with the issue" grep -q ' #9: warning: the worker tried git --no-verify; refused' "$CANCCU_HOME/dispatch.log"
ok "a plain push passes the guard" eq "$(gh_ 'git push origin HEAD')" ""
ok "… and a commit whose message says --no-verify" eq "$(gh_ "git commit -m 'drop the --no-verify hint'")" ""

# ---------------------------------------------------------------- the dispatcher

env_new prepush-on 'PRE_PUSH_CMD="npm run lint --"' 'PRE_PUSH_MAX_SEC=90'
lib run_worker 7 "do it" "1 1 1"
ok "on: a worker run gets the command, its limit and the base branch" \
  eq "$(grep -E '^WORKER_(PRE_PUSH_CMD|PRE_PUSH_MAX_SEC|BASE_BRANCH)=' "$FAKE/worker.envdump" | sort | tr '\n' ' ')" "WORKER_BASE_BRANCH=main WORKER_PRE_PUSH_CMD=npm run lint -- WORKER_PRE_PUSH_MAX_SEC=90 "
ok "… the worker prompt says what a refused push means" \
  grep -qF 'A refused push means: fix what it shows first, then push again. Never use `--no-verify`.' <<<"$(lib test_rule)"
env_new prepush-off
lib run_worker 7 "do it" "1 1 1"
ok "off: no command" eq "$(grep -c '^WORKER_PRE_PUSH_CMD=.' "$FAKE/worker.envdump")" 0
ok "… the prompt as before" not grep -qF -- '--no-verify' <<<"$(lib test_rule)"

echo "canccu-prepush tests: $npass passed, $nfail failed"
(( nfail == 0 ))
