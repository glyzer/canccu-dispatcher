#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-pack.sh — the context pack (#333): before a package's first build a cheap-model run
# writes .canccu/context.md in the worktree, once; off by default (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- the engine: the pack before the build

env_new pack-engine
wd=$E/wt; mkdir -p "$wd"
"$FAKE_REAL_GIT" -C "$wd" -c init.defaultBranch=main init -q
# the pack run (its model in the arguments) writes the file, as the real one would
printf 'cd "%s"; if tail -1 "$FAKE/claude.args" | grep -q -- "--model cheap-model"; then mkdir -p .canccu; echo "# context" > .canccu/context.md; fi\n' "$wd" > "$FAKE/claude.do"
# prun [env...]: the first build of package pkg-3-pages in its worktree, with the fake claude
prun() {
  : > "$FAKE/claude.args"
  printf 'repo=web\nkey=pkg-3-pages\nkind=worker\npid=\nwindow=\n' > "$WORKERS_DIR/web-pkg-3-pages.lock"
  (cd "$wd" && env WORKER_RUN_TYPE=build "$@" PATH="$fb:$PATH" CODE_ROOT="$E/code" \
    "$root/libexec/canccu-worker" __run web pkg-3-pages 5 1 2 "" "build it" "$wd" "" 1 > /dev/null 2>&1)
}
types() { awk -F'\t' '$3 == "pkg-3-pages" { printf "%s%s", s, $5; s = " " }' "$WORKERS_DIR/spend.log"; }
prun WORKER_PACK_MODEL=cheap-model "WORKER_PACK_PROMPT=pack it" "WORKER_PACK_BUDGET=30 1 15"
ok "on: two claude runs, the pack first, on its model, with its prompt and budget" \
  eq "$(grep -c . "$FAKE/claude.args") $(head -1 "$FAKE/claude.args" | grep -c -- '--model cheap-model.*-- pack it$') $(head -1 "$FAKE/claude.args" | grep -c -- '--max-budget-usd 1 ')" "2 1 1"
ok "… then the build, not on the pack's model" eq "$(tail -1 "$FAKE/claude.args" | grep -c -- 'cheap-model') $(tail -1 "$FAKE/claude.args" | grep -c -- '-- build it$')" "0 1"
ok "… spend.log: a pack line, then the build's" eq "$(types)" "pack build"
ok "… the pack line names its model" eq "$(awk -F'\t' '$5 == "pack" { print $6 }' "$WORKERS_DIR/spend.log")" cheap-model
ok "… the build keeps a session of its own, never the pack's" \
  eq "$(grep -c -- "$(cat "$WORKERS_DIR/web-pkg-3-pages.id")" "$FAKE/claude.args")" 1
ok "… the file is there, and git ignores it in the worktree" \
  eq "$(cat "$wd/.canccu/context.md") $("$FAKE_REAL_GIT" -C "$wd" status --porcelain | grep -c canccu)" "# context 0"
ok "… the run's log says how the pack ended" grep -q '^=== context pack: done' "$WORKERS_DIR/web-pkg-3-pages.log"

# a failed pack: logged, and the build starts without it
mkdir -p "$E/failbin"
printf '#!/bin/bash\nif [[ " $* " == *" --model cheap-model "* ]]; then echo "$*" >> "$FAKE/claude.args"; echo %s; exit 1; fi\nexec "%s/claude" "$@"\n' \
  "'{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"num_turns\":2,\"total_cost_usd\":0.1}'" "$fb" > "$E/failbin/claude"
chmod +x "$E/failbin/claude"; rm -rf "$wd/.canccu"; : > "$WORKERS_DIR/spend.log"
prun PATH="$E/failbin:$fb:$PATH" WORKER_PACK_MODEL=cheap-model "WORKER_PACK_PROMPT=pack it" "WORKER_PACK_BUDGET=30 1 15"
ok "a failed pack: the build still runs" eq "$(grep -c . "$FAKE/claude.args") $(tail -1 "$FAKE/claude.args" | grep -c -- '-- build it$')" "2 1"
ok "… its spend line says so" eq "$(types) $(awk -F'\t' '$5 == "pack" { print $15 }' "$WORKERS_DIR/spend.log")" "pack build pack=failed"
ok "… and the dispatcher's log" grep -q 'pkg-3-pages: the context pack failed (error: error_during_execution); the build starts without it' "$CANCCU_HOME/dispatch.log"
ok "… no file" not test -e "$wd/.canccu/context.md"

: > "$WORKERS_DIR/spend.log"; prun
ok "off: one run, the build, no pack line" eq "$(grep -c . "$FAKE/claude.args") $(types)" "1 build"

# ---------------------------------------------------------------- the dispatcher: the first build only

# pstep <name> [config...]: step "3 Events" (milestone 12), ready 101 103, planned as one package
pstep() {
  env_new "$@"
  jq -nc '{number: 12, title: "3 Events", open_issues: 0, closed_issues: 0, due_on: null}' | jq -s . > "$FAKE/ms.json"
  jq -nc '{number: 95, title: "Checkpoint 95", state: "OPEN", milestone: {title: "3 Events"}, labels: [{name: "checkpoint"}]}' | jq -s . > "$FAKE/cps.json"
  { issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; issue 103 ready "" "3 Events"; } | issues
  json c90.json '{"comments": [], "labels": [{"name": "epic"}]}'; route 'issue view 90 *' c90.json
  route 'api -X PATCH *' empty.json
  dispatch --once; rm -f "$WORKERS_DIR/web-plan-12.lock"
  last plan-12 done '{"schema":1,"step":12,"wave":1,"packages":[{"name":"pages","issues":[101,103],"risk":"low","risk_reason":"pages","areas":["src/"],"depends_on":[]}]}'
  dispatch --once
}
build() { sed -n '/^=== .*--key pkg-12-pages /,/^=== /p' "$FAKE/worker.envdump"; }

pstep pack-on 'CONTEXT_PACK_MODEL=cheap-model' 'BUDGET_PACK="30 1 15"'
ok "on: the package's first build carries the pack's model and budget" \
  eq "$(build | grep -E '^WORKER_PACK_(MODEL|BUDGET)=' | sort | tr '\n' ' ')" "WORKER_PACK_BUDGET=30 1 15 WORKER_PACK_MODEL=cheap-model "
ok "… and its prompt, which names the package's issues and the file" \
  eq "$(build | grep -c '^WORKER_PACK_PROMPT=.*#101, #103.*\.canccu/context\.md')" 1
ok "… the build prompt points to the file first" grep -qF 'Read `.canccu/context.md` before exploring' "$FAKE/worker.log"
: > "$FAKE/worker.envdump"
lib run_worker pkg-12-pages "fix it" "1 1 1" fix
ok "… a later run of the package (a fix, a resume) gets no pack" eq "$(grep -c '^WORKER_PACK_MODEL=.' "$FAKE/worker.envdump")" 0

pstep pack-off
ok "off: no pack" eq "$(build | grep -c '^WORKER_PACK_MODEL=.')" 0
ok "… the build prompt as before" not grep -qF '.canccu/context.md' "$FAKE/worker.log"

echo "canccu-pack tests: $npass passed, $nfail failed"
(( nfail == 0 ))
