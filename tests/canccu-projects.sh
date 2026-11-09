#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-projects.sh — projects, canccu-init, canccu-up, a narrow token per project (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- projects

pick() { ( PATH="$fb:$PATH"; . "$root/lib/canccu-common.sh"; echo "$CANCCU_PROJECT $TMUX_SESSION $REPO" ) 2>&1; }

# choosing a project
penv pick-one tools
ok "one project: it is the default, session canccu" eq "$(pick)" "tools canccu example-user/tools"
penv pick-none
ok "no project: refused, says how to add one" grep -q 'no project in .*canccu-init <name> <owner/repo>' <<<"$(pick)"
ok "… and names no installer of another tool" not grep -q 'install' <<<"$(pick)"
penv pick-two tools shop
ok "two projects, no default-project: refused with the list" \
  grep -q 'several projects and no .*default-project: pick one with --project <name> (or CANCCU_PROJECT). Projects: shop tools$' <<<"$(pick)"
echo shop > "$CANCCU_ROOT/default-project"
ok "default-project picks shop, session canccu" eq "$(pick)" "shop canccu example-org/shop"
ok "--project tools: session canccu-tools" eq "$(pick --project tools)" "tools canccu-tools example-user/tools"
ok "--project=tools works too" eq "$(pick --project=tools)" "tools canccu-tools example-user/tools"
ok "CANCCU_PROJECT=tools" eq "$(CANCCU_PROJECT=tools pick)" "tools canccu-tools example-user/tools"
ok "--project wins over CANCCU_PROJECT" eq "$(CANCCU_PROJECT=tools pick --project shop)" "shop canccu example-org/shop"
ok "--project is taken off the command's arguments" \
  eq "$(PATH="$fb:$PATH" bash -c '. "$0/lib/canccu-common.sh"; echo "[$CANCCU_PROJECT] [$*]"' "$root" --project tools 5 --project x 2>&1)" "[tools] [5 --project x]"
ok "an unknown project: refused with the list" grep -q "no project 'nope' .*Projects: shop tools$" <<<"$(pick --project nope)"
ok "a path as the name: refused" grep -q "'../tools' is no project name" <<<"$(pick --project ../tools)"
echo gone > "$CANCCU_ROOT/default-project"
ok "default-project naming no project: refused" grep -q "no project 'gone'" <<<"$(pick)"
rm "$CANCCU_ROOT/projects/shop/rules"
ok "a project without rules: refused" grep -q "project 'shop' has no rules file" <<<"$(pick --project shop)"
ok "… says where this tool's template is" grep -qF "copy $(realpath "$root" | sed "s|^$HOME|~|")/profiles/default/rules there" <<<"$(pick --project shop)"
cp "$root/profiles/default/rules" "$CANCCU_ROOT/projects/shop/rules"
for c in "$root"/bin/canccu-*; do
  # canccu-dispatcher takes --project after doctor only (tests/canccu-doctor.sh)
  case ${c##*/} in canccu-init|canccu-dispatcher) continue ;; esac
  out=$(PATH="$fb:$PATH" "$c" --project nope 1 2>&1); rc=$?
  ok "${c##*/} takes --project (an unknown one is refused)" eq "$rc $(grep -c "no project 'nope'" <<<"$out")" "1 1"
done
PATH="$fb:$PATH" "$root/bin/canccu-pause" --project tools > /dev/null 2>&1
ok "canccu-pause --project tools pauses tools only" eq "$(ls "$CANCCU_ROOT/projects/tools/paused" "$CANCCU_ROOT/projects/shop/paused" 2>/dev/null | wc -l)" 1
ok "… and logs in tools's log" grep -q 'paused (canccu-pause, project tools)' "$CANCCU_ROOT/projects/tools/dispatch.log"

# two projects run independently: own state, locks, log, session and CAP
penv two tools shop
echo tools > "$CANCCU_ROOT/default-project"; echo 'TOTAL_CAP=10' > "$CANCCU_ROOT/config"
pconf tools CAP=1; pconf shop CAP=2
projissues tools 1 2 3; projissues shop 11 12 13
dispatch --project tools --once
dispatch --project shop --once
ok "a starts its CAP 1" eq "$(pstarted tools 1 && echo y)$(pstarted tools 2 && echo y)" y
ok "b starts its CAP 2" eq "$(pstarted shop 11 && echo y)$(pstarted shop 12 && echo y)$(pstarted shop 13 && echo y)" yy
ok "a's state is in tools" eq "$(ls "$CANCCU_ROOT/projects/tools/state" | tr '\n' ' ')" "1 "
ok "b's state is in shop" eq "$(ls "$CANCCU_ROOT/projects/shop/state" | tr '\n' ' ')" "11 12 "
ok "a's run locks are in tools's workers dir" eq "$(cd "$CANCCU_ROOT/projects/tools/workers" && ls ./*.lock | tr '\n' ' ')" "./tools-1.lock "
ok "b's run locks are in shop's workers dir" eq "$(cd "$CANCCU_ROOT/projects/shop/workers" && ls ./*.lock | tr '\n' ' ')" "./shop-11.lock ./shop-12.lock "
ok "each project logs to its own log" \
  eq "$(grep -c started "$CANCCU_ROOT/projects/tools/dispatch.log") $(grep -c '#1 started' "$CANCCU_ROOT/projects/shop/dispatch.log")" "1 0"
ok "each project's runs open in its own tmux session" \
  eq "$(grep -c '^TMUX_SESSION=canccu$' "$FAKE/worker.envdump") $(grep -c '^TMUX_SESSION=canccu-shop$' "$FAKE/worker.envdump")" "1 2"
ok "b's labels go to shop's repo only" eq "$(grep -c 'issue edit 1[123] -R example-org/shop' "$FAKE/gh.log") $(grep -c 'issue edit 1[123] -R example-user/tools' "$FAKE/gh.log")" "2 0"
st_a=$(cat "$CANCCU_ROOT/projects/tools/state/1")
dispatch --project shop --once
ok "a pass of b leaves tools's state alone" eq "$(cat "$CANCCU_ROOT/projects/tools/state/1")" "$st_a"
exec 7>"$CANCCU_ROOT/projects/tools/.dispatch.lock"; flock -n 7   # tools's dispatcher runs
dispatch --project tools --once; rca=$?; cp "$E/out" "$E/out-a2"
dispatch --project shop --once; rcb=$?
exec 7>&-
ok "one dispatcher per project: a second one for a is refused" \
  eq "$rca $(grep -c 'another canccu-dispatch is running for project tools' "$E/out-a2")" "1 1"
ok "… while shop's runs" eq "$rcb" 0

# the global TOTAL_CAP holds over both projects; a project's config cannot raise it
penv total tools shop
echo tools > "$CANCCU_ROOT/default-project"; echo 'TOTAL_CAP=2' > "$CANCCU_ROOT/config"
pconf tools CAP=3 TOTAL_CAP=10; pconf shop CAP=3 TOTAL_CAP=10
projissues tools 1 2 3; projissues shop 11 12 13
dispatch --project tools --once
dispatch --project shop --once
ok "TOTAL_CAP 2: tools starts 2 of its CAP 3" eq "$(grep -c -- '--name #' "$FAKE/worker.log")" 2
ok "… and shop none" not pstarted shop 11
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-run" --project shop 11 2>&1); rc=$?
ok "a start by hand is held to TOTAL_CAP as well" \
  eq "$rc $(grep -c 'could not start worker #11: TOTAL_CAP (2) runs over all projects are running' <<<"$out")" "1 1"
ok "… and never reaches the engine" not pstarted shop 11
ok "canccu-status shows both caps" grep -q '^project: shop (.*, tmux canccu-shop) · runs: 0 of CAP 3 · all projects: 2 of TOTAL_CAP 2$' \
  <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" --project shop 2>&1)"
ok "no run inherits the engine lock (fd 7) or the dispatcher's (fd 8)" not grep -qwE '7|8' "$FAKE/worker.fds"
rm -f "$CANCCU_ROOT"/projects/tools/workers/*.lock
dispatch --project shop --once
ok "slots freed in tools: shop starts" eq "$(pstarted shop 11 && echo y)$(pstarted shop 12 && echo y)" yy

# the usage-limit back-off is shared: one Claude account
penv shared-backoff tools shop
echo tools > "$CANCCU_ROOT/default-project"; projissues shop 11
echo $((NOW + 600)) > "$CANCCU_ROOT/backoff"
dispatch --project shop --once
ok "a back-off (from any project) stops shop's starts too" not pstarted shop 11
penv shared-backoff-set tools shop
echo tools > "$CANCCU_ROOT/default-project"
issue 1 in-progress | jq -s . > "$FAKE/issues-tools.json"
printf 'phase=work\nstarted=%s\n' "$NOW" > "$CANCCU_ROOT/projects/tools/state/1"
printf 'tools#1 · "p" · usage limit · 1 turns · $0.10 · 1m00s\n\nYou hit your usage limit · resets 3pm (UTC)\n' > "$CANCCU_ROOT/projects/tools/workers/tools-1.last"
touch -d "@$((NOW + 60))" "$CANCCU_ROOT/projects/tools/workers/tools-1.last"
dispatch --project tools --once
ok "a's usage limit writes the global back-off" test -s "$CANCCU_ROOT/backoff"
ok "… not one in the project" test ! -e "$CANCCU_ROOT/projects/tools/backoff"
ok "… which shop's status shows" grep -q 'usage limit until' <<<"$(PATH="$fb:$PATH" "$root/bin/canccu-status" --project shop 2>&1)"

# the one-at-a-time lock comes from the rules only (the generic template has none)
penv no-lock tools
projissues tools 10 11
jq '.[0].labels += [{name: "module:contracts"}] | .[1].body = "edits contracts/x.yaml"' "$FAKE/issues-tools.json" > "$FAKE/t" &&
  mv "$FAKE/t" "$FAKE/issues-tools.json"
dispatch --project tools --once
ok "without a lock in the rules, both such issues start" eq "$(pstarted tools 10 && echo y)$(pstarted tools 11 && echo y)" yy
ok "… and the engine gets no lock pattern" grep -qx 'WORKER_EXCLUSIVE_RE=' "$FAKE/worker.envdump"
env_new lock-web
{ issue 10 ready; } | issues
dispatch --once
ok "the web rules pass their pattern to the engine" grep -qxF 'WORKER_EXCLUSIVE_RE=contracts/|"name":"[^"]*contract' "$FAKE/worker.envdump"

# the rules of the test project web (tests/fixtures/rules/web) reach the prompts and gates
env_new web-prompts
{ issue 30 ready; } | issues
dispatch --once
ok "worker prompt: WORKER_EXTRA in its place" \
  grep -qF 'stop when the PR is ready and CI is green. Legacy code is in ~/old-code (read-only). Stop and say why on:' "$FAKE/worker.log"
ok "reviewer prompt: REVIEW_EXTRA in its place" eq "$(lib review_prompt 50 5 x f high | grep -o 'Check every acceptance criterion[^.]*PR body')" \
  "Check every acceptance criterion, the no-personal-data rule (no real names, hostnames, IPs or personal paths), that contract changes are additive and migrations non-destructive, and the implementation choices listed under 'Decisions made:' in the PR body"
ok "answerer prompt: ANSWER_READ and ANSWER_READ_ALSO" \
  grep -qF 'Read the issue (gh issue view 5 -R example-org/web --comments), docs/decisions/, docs/roadmap.md, AGENTS.md, the PR so far (gh pr view 50 -R example-org/web and gh pr diff 50 -R example-org/web) and the legacy code in ~/old-code. Treat' \
  <<<"$(lib answer_prompt 5 q 50)"
ok "web: setup/ is gated" eq "$(lib classify_pure setup/x.sh "" "" "" example-org/web 0)" "manual: changes setup/ (setup/x.sh)"
ok "web: on the AUTO_MERGE_UNTIL date → manual" \
  eq "$(lib eval 'CANCCU_NOW=$(date -u -d 2031-03-01T08:00:00Z +%s); classify_pure src/a.ts "" "" "" example-org/web 0')" "manual: on or after AUTO_MERGE_UNTIL (2031-03-01)"
penv generic tools
ok "a generic project: no extra reviewer checks" grep -qF 'Check every acceptance criterion and the implementation choices' <<<"$(plib tools review_prompt 50 5 x f high)"
ok "a generic project: the answerer reads AGENTS.md" grep -qF 'Read the issue (gh issue view 5 -R example-user/tools --comments), AGENTS.md, the PR so far. Treat' <<<"$(plib tools answer_prompt 5 q "")"
ok "a generic project: no freeze date → auto" eq "$(plib tools classify_pure src/a.ts "" "" "" example-user/tools 0)" auto
ok "a generic project: agent config is still gated" eq "$(plib tools classify_pure CLAUDE.md "" "" "" example-user/tools 0)" "manual: changes agent config (CLAUDE.md)"
ok "a generic project: .github/ is gated" eq "$(plib tools classify_pure .github/x.yml "" "" "" example-user/tools 0)" "manual: changes .github/ (.github/x.yml)"
ok "a generic project: setup/ is not" eq "$(plib tools classify_pure setup/x.sh "" "" "" example-user/tools 0)" auto
ok "a generic project: a gated path below the top" eq "$(plib tools eval 'GATED_PATHS="(^|/)infra/"; classify_pure a/infra/x "" "" "" example-user/tools 0')" "manual: changes a gated path (a/infra/x)"
ok "a generic project: no extra worker text" grep -qF 'CI is green. Stop and say why on:' <<<"$(plib tools eval 'printf "$WORKER_PROMPT" example-user/tools 1 1 1 1-x ""')"

# only the generic template ships
ok "profiles/: the default template only" eq "$(ls "$root/profiles")" default

# canccu-init
penv init tools
echo '[{"name": "ready"}, {"name": "blocked"}]' > "$FAKE/labels.json"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" web example-org/web 2>&1); rc=$?
w=$CANCCU_ROOT/projects/web
ok "canccu-init: succeeds" eq "$rc" 0
ok "canccu-init: the config names the repo and its clone" eq "$(grep -E '^(REPO|CLONE)=' "$w/config" | tr '\n' ' ')" 'REPO=example-org/web CLONE=$HOME/code/web '
ok "canccu-init: the rules from the generic template" eq "$(grep -v '^#' "$w/rules")" "$(grep -v '^#' "$root/profiles/default/rules")"
ok "canccu-init: says which template" grep -q "^wrote .*/projects/web/config and rules (from the template default: .*profiles/default)$" <<<"$out"
ok "canccu-init: the only project so far becomes the default (it keeps session canccu)" eq "$(cat "$CANCCU_ROOT/default-project")" tools
ok "canccu-init: creates the missing labels in the repo" eq "$(grep -c '^label create .* -R example-org/web' "$FAKE/gh.log")" 11
ok "… none that exist" not grep -q '^label create ready' "$FAKE/gh.log"
ok "canccu-init: no other gh call (rulesets, secrets, variables, collaborators)" eq "$(grep -cvE '^label (list|create) ' "$FAKE/gh.log")" 0
for w8 in 'as a collaborator' 'repo scope' 'repo variable REVIEWER_LOGIN' 'review-gate workflow and its script' 'required checks' \
          'canccu-up --project web' 'tmux session canccu-web' 'Resource owner: example-org ' 'Only
     select repositories → example-org/web' 'Read and write: Contents, Issues, Pull requests, Workflows' \
          'Read-only:      Actions, Commit statuses, Metadata' 'no Administration, no Secrets' \
          "install -m 600 /dev/null $CANCCU_ROOT/projects/web/gh-token" \
          "GH_CONFIG_DIR=$CANCCU_ROOT/projects/web/gh gh auth login --with-token --insecure-storage < $CANCCU_ROOT/projects/web/gh-token"; do
  ok "canccu-init checklist: $w8" grep -qF "$w8" <<<"$out"
done
ok "canccu-init checklist: never points at another project for the review-gate" not grep -q 'from a project that has them' <<<"$out"
tdir=$(grep -oE '[^ ]*/templates/repo/\.github/' <<<"$out"); tdir=${tdir/#\~/$HOME}
ok "canccu-init checklist: names this tree's review-gate templates" test -x "$tdir/scripts/review-gate"
ok "canccu-init checklist: says REVIEWER_LOGIN is not set yet" grep -qF 'the reviewer bot (REVIEWER_LOGIN: not set yet' <<<"$out"
ok "canccu-init: the new project resolves" eq "$(pick --project web)" "web canccu-web example-org/web"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" web example-org/other 2>&1); rc=$?
ok "canccu-init: an existing project is refused, unchanged" eq "$rc $(grep -c "project 'web' exists" <<<"$out") $(grep -c example-org/other "$w/config")" "1 1 0"
PATH="$fb:$PATH" "$root/bin/canccu-init" Bad/x example-org/x > /dev/null 2>&1; rc=$?
ok "canccu-init: a bad name is refused" eq "$rc$(test -e "$CANCCU_ROOT/projects/Bad" && echo made)" 1
PATH="$fb:$PATH" "$root/bin/canccu-init" x notarepo > /dev/null 2>&1; rc=$?
ok "canccu-init: a bad repo is refused" eq "$rc$(test -e "$CANCCU_ROOT/projects/x" && echo made)" 1

# canccu-init: the template no longer follows the project's name, --profile picks one
penv init-name
mkdir -p "$E/tpl"; cp -r "$root/bin" "$root/lib" "$root/libexec" "$root/profiles" "$E/tpl/"
mkdir -p "$E/tpl/profiles/web"; printf 'REPO=@REPO@\nCLONE=$HOME/code/@REPO_NAME@\n' > "$E/tpl/profiles/web/config"
echo "RISKY_PATHS='^repo-web/'" > "$E/tpl/profiles/web/rules"
PATH="$fb:$PATH" "$E/tpl/bin/canccu-init" web example-org/web > /dev/null 2>&1; rc=$?
ok "canccu-init: a template named like the project is not picked by the name" \
  eq "$rc $(grep -c 'repo-web' "$CANCCU_ROOT/projects/web/rules")" "0 0"
penv init-profile
mkdir -p "$CANCCU_ROOT/profiles/mine"
printf 'REPO=@REPO@\nCLONE=$HOME/code/@REPO_NAME@\nCAP=1\n' > "$CANCCU_ROOT/profiles/mine/config"
echo "RISKY_PATHS='^mine/'" > "$CANCCU_ROOT/profiles/mine/rules"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --profile mine web example-org/web 2>&1); rc=$?
ok "canccu-init --profile: the user's own template from ~/.canccu/profiles/<name>" \
  eq "$rc $(grep -c "^RISKY_PATHS='^mine/'" "$CANCCU_ROOT/projects/web/rules") $(grep -c '^CAP=1' "$CANCCU_ROOT/projects/web/config")" "0 1 1"
ok "… and says so" grep -q "(from the template mine: .*/profiles/mine)" <<<"$out"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --profile default tools example-user/tools 2>&1); rc=$?
ok "canccu-init --profile default: the shipped template" eq "$rc $(grep -c 'from the template default' <<<"$out")" "0 1"
mkdir -p "$CANCCU_ROOT/profiles/default"; printf 'REPO=@REPO@\nCLONE=$HOME/code/@REPO_NAME@\n' > "$CANCCU_ROOT/profiles/default/config"
echo "RISKY_PATHS='^own-default/'" > "$CANCCU_ROOT/profiles/default/rules"
PATH="$fb:$PATH" "$root/bin/canccu-init" --profile default shop example-org/shop > /dev/null 2>&1
ok "canccu-init: ~/.canccu/profiles/<name> comes before the shipped one" grep -q own-default "$CANCCU_ROOT/projects/shop/rules"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --profile nope x example-org/x 2>&1); rc=$?
ok "canccu-init --profile: an unknown one is refused, nothing made" \
  eq "$rc $(grep -c "no template 'nope'" <<<"$out")$(test -e "$CANCCU_ROOT/projects/x" && echo made)" "1 1"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" --profile ../x y example-org/y 2>&1); rc=$?
ok "canccu-init --profile: a path is refused" eq "$rc $(grep -c "is no template name" <<<"$out")" "1 1"

# ---------------------------------------------------------------- follow-ups

# 1: every pane of a project's session acts on that project
mkdir -p "$T/tmuxup"
cat > "$T/tmuxup/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE/tmux.log"
# panes %0, %1, ... in creation order; $FAKE/has-session: the session exists
case $1 in
  has-session) [ -e "$FAKE/has-session" ] || exit 1 ;;
esac
# the environment a new-session client would start the server with
[ "$1" = new-session ] && env > "$FAKE/tmux.start-env"
case $1 in
  new-session|split-window|new-window) n=$(cat "$FAKE/panes" 2>/dev/null || echo 0); echo "%$n"; echo $((n + 1)) > "$FAKE/panes" ;;
esac
exit 0
EOF
chmod +x "$T/tmuxup/tmux"
penv up-panes tools shop
echo tools > "$CANCCU_ROOT/default-project"; mkdir -p "$E/home"
HOME=$E/home PATH="$T/tmuxup:$fb:$PATH" "$root/bin/canccu-up" --project shop > "$E/out" 2>&1
ok "canccu-up shop: the session is canccu-shop" grep -q -- '^new-session .* -s canccu-shop ' "$FAKE/tmux.log"
ok "canccu-up shop: every pane gets CANCCU_PROJECT=shop" \
  eq "$(grep -cE '^(new-session|split-window|new-window) ' "$FAKE/tmux.log") $(grep -E '^(new-session|split-window|new-window) ' "$FAKE/tmux.log" | grep -c -- '-e CANCCU_PROJECT=shop ')" "4 4"
ok "canccu-up shop: … and so does the session environment" grep -qx 'set-environment -t =canccu-shop CANCCU_PROJECT shop' "$FAKE/tmux.log"
ok "canccu-up shop: window main: the lead, and the monitor split off to its right" \
  eq "$(grep -c -- '^new-session .* -n main ' "$FAKE/tmux.log") $(grep -c -- '^split-window -h -l 40% .* -t %0 ' "$FAKE/tmux.log") $(grep -cxF 'send-keys -t %0 claude C-m' "$FAKE/tmux.log") $(grep -cxF 'send-keys -t %1 canccu-monitor --project shop C-m' "$FAKE/tmux.log")" "1 1 1 1"
ok "canccu-up shop: window dispatch runs shop's dispatcher" \
  eq "$(grep -c -- '^new-window -d .* -t =canccu-shop: -n dispatch ' "$FAKE/tmux.log") $(grep -cxF 'send-keys -t %2 canccu-dispatch --project shop C-m' "$FAKE/tmux.log")" "1 1"
ok "canccu-up shop: window shell" grep -q -- '^new-window -d .* -t =canccu-shop: -n shell ' "$FAKE/tmux.log"
ok "canccu-up shop (no gh config dir): every pane gets GH_CONFIG_DIR and GIT_CONFIG_COUNT empty" \
  eq "$(grep -E '^(new-session|split-window|new-window) ' "$FAKE/tmux.log" | grep -c -- '-e GH_CONFIG_DIR= -e GIT_CONFIG_COUNT= ')" 4
ok "canccu-up shop: one split only (main has two panes), the focus on the lead" \
  eq "$(grep -c '^split-window' "$FAKE/tmux.log") $(tail -1 "$FAKE/tmux.log")" "1 select-pane -t %0"
: > "$FAKE/tmux.log"; touch "$FAKE/has-session"
HOME=$E/home PATH="$T/tmuxup:$fb:$PATH" "$root/bin/canccu-up" --project shop > "$E/out" 2>&1
ok "canccu-up shop, the session exists: never killed or rearranged" not grep -qE '^(kill|new-|split|send-keys|select-|move|swap|rename|set)' "$FAKE/tmux.log"
ok "… and says where to start the dispatcher" grep -qF 'start it in its window dispatch (or any window): canccu-dispatch --project shop' "$E/out"
ok "a pane's CANCCU_PROJECT picks shop over the default" eq "$(CANCCU_PROJECT=shop pick)" "shop canccu-shop example-org/shop"
penv up-gh tools; mkdir -p "$E/home" "$CANCCU_ROOT/projects/tools/gh"
HOME=$E/home PATH="$T/tmuxup:$fb:$PATH" "$root/bin/canccu-up" --project tools > "$E/out" 2>&1
ok "canccu-up tools (its own gh login): every pane gets its config dir and git's helper" \
  eq "$(grep -E '^(new-session|split-window|new-window) ' "$FAKE/tmux.log" | grep -F -- "-e GH_CONFIG_DIR=$CANCCU_ROOT/projects/tools/gh -e GIT_CONFIG_COUNT=4 " | grep -c -- '-e GIT_CONFIG_VALUE_1=!gh auth git-credential')" 4
ok "… and so does the session environment (new-session -e)" grep -qF -- "-e GH_CONFIG_DIR=$CANCCU_ROOT/projects/tools/gh" <(grep '^new-session ' "$FAKE/tmux.log")
ok "canccu-up tools: the client that may start the tmux server holds no gh dir, owner or git entry (review #1)" \
  eq "$(grep -cE '^(GH_CONFIG_DIR|CANCCU_GH_OWNER|GIT_CONFIG_)' "$FAKE/tmux.start-env")" 0
penv up-gh-token tools; mkdir -p "$E/home" "$CANCCU_ROOT/projects/tools/gh"
GH_TOKEN=classic-from-env GITHUB_TOKEN=classic-from-env HOME=$E/home PATH="$T/tmuxup:$fb:$PATH" "$root/bin/canccu-up" --project tools > "$E/out" 2>&1
ok "canccu-up tools, GH_TOKEN in the caller: every pane blanks the token variables (review #2)" \
  eq "$(grep -E '^(new-session|split-window|new-window) ' "$FAKE/tmux.log" | grep -cF -- '-e GH_TOKEN= -e GITHUB_TOKEN= ')" 4
ok "… and the token value reaches no tmux call" not grep -q classic-from-env "$FAKE/tmux.log"
penv up-gh-none tools; mkdir -p "$E/home"
GH_TOKEN=classic-from-env HOME=$E/home PATH="$T/tmuxup:$fb:$PATH" "$root/bin/canccu-up" --project tools > "$E/out" 2>&1
ok "canccu-up without a gh dir: tokens are left alone (today's behaviour)" not grep -qF -- '-e GH_TOKEN=' "$FAKE/tmux.log"

# 2: a second project never claims a repo or a clone another project has
penv init-claims web
echo '[]' > "$FAKE/labels.json"
mkdir -p "$E/home"
run_init() { HOME=$E/home PATH="$fb:$PATH" "$root/bin/canccu-init" "$@" 2>&1; }
out=$(run_init tools example-org/app); rc=$?
ok "init tools example-org/app: succeeds, clone ~/code/app" eq "$rc $(grep -c '^CLONE=\$HOME/code/app$' "$CANCCU_ROOT/projects/tools/config")" "0 1"
out=$(run_init shop example-user/app); rc=$?
ok "init shop example-user/app: the clone ~/code/app is tools's: refused" eq "$rc $(grep -c "project 'tools' already uses the clone ~/code/app" <<<"$out")" "1 1"
ok "… nothing written" test ! -e "$CANCCU_ROOT/projects/shop"
out=$(run_init shop example-user/app "$E/home/code/example-user-app"); rc=$?
ok "init shop example-user/app <path>: its own clone is fine" eq "$rc $(grep -c "^CLONE=$E/home/code/example-user-app\$" "$CANCCU_ROOT/projects/shop/config")" "0 1"
ok "… and shop resolves to it" eq "$( (HOME=$E/home; PATH="$fb:$PATH"; . "$root/lib/canccu-common.sh" --project shop; echo "$REPO $CLONE $REPO_NAME") 2>&1)" "example-user/app $E/home/code/example-user-app example-user-app"
out=$(run_init c Example-Org/App "$E/home/code/other"); rc=$?
ok "init c Example-Org/App: the repo is tools's (any case): refused" eq "$rc $(grep -c "project 'tools' already runs example-org/app" <<<"$out")" "1 1"
ok "… nothing written" test ! -e "$CANCCU_ROOT/projects/c"
out=$(run_init d example-org/web); rc=$?
ok "init d example-org/web: the project web runs example-org/web: refused" eq "$rc $(grep -c "project 'web' already runs example-org/web" <<<"$out")" "1 1"
out=$(run_init e example-org/x relative/path); rc=$?
ok "init with a relative clone path: refused" eq "$rc $(test -e "$CANCCU_ROOT/projects/e" && echo made)" "1 "

# 7: canccu-init says which labels it created, and which it could not
penv init-labels
echo '[{"name": "ready"}]' > "$FAKE/labels.json"; route 'label list*' labels.json
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" web example-org/web 2>&1)
ok "canccu-init: lists the labels it created" grep -qx 'labels: created blocked in-progress epic needs-you plan-ok awaiting-accept needs-work accepted manual-accept checkpoint checkpoint-ok fast' <<<"$out"
ok "canccu-init: lists the labels once" eq "$(grep -c '^label list' "$FAKE/gh.log")" 1
penv init-labels-fail
echo '[{"name": "ready"}]' > "$FAKE/labels.json"; route 'label list*' labels.json; echo 'fail:label create' >> "$FAKE/routes"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" web example-org/web 2>&1); rc=$?
ok "canccu-init: a failed label create is not called created" eq "$(grep -c '^labels: created' <<<"$out") $(grep -c '^labels: could not create blocked .* fast (canccu-dispatch tries again' <<<"$out")" "0 1"
penv init-labels-all
route 'label list*' labels.json
out=$(PATH="$fb:$PATH" "$root/bin/canccu-init" web example-org/web 2>&1)
ok "canccu-init: all labels there" grep -qx 'labels: all there already' <<<"$out"

# non-blocking 2: a global rules value holds where the project's rules leave it out
penv global-rules tools
echo 'AUTO_MERGE_UNTIL=2030-01-01' > "$CANCCU_ROOT/config"
ok "a global AUTO_MERGE_UNTIL holds for a project on the generic rules" eq "$(plib tools classify_pure src/a.ts "" "" "" example-user/tools 0)" "manual: on or after AUTO_MERGE_UNTIL (2030-01-01)"
env_new global-rules-web
echo 'AUTO_MERGE_UNTIL=2030-01-01' > "$CANCCU_ROOT/config"
ok "… never for a project whose rules set it" eq "$(lib classify_pure src/a.ts "" "" "" example-org/web 0)" auto

# non-blocking 4: CANCCU_TMUX_SESSION renames the default project's session only
penv session-override tools shop
echo tools > "$CANCCU_ROOT/default-project"
ok "CANCCU_TMUX_SESSION renames the default project's session" eq "$(CANCCU_TMUX_SESSION=x pick)" "tools x example-user/tools"
ok "… and not another project's" eq "$(CANCCU_TMUX_SESSION=x pick --project shop)" "shop canccu-shop example-org/shop"

# non-blocking 5: the security-review trigger comes from the rules
env_new security-when
ok "the default security-review trigger" \
  grep -qF 'also run the security-review skill if it touches sign-in, rights, sessions, secrets, tenancy/RLS or deploy/. Check' <<<"$(lib review_prompt 50 5 x f high)"
ok "a project's own trigger" grep -qF 'if it touches payments or deploy/. Check' \
  <<<"$(lib eval 'SECURITY_REVIEW_WHEN="payments or deploy/"; review_prompt 50 5 x f high')"

# non-blocking 8: a refused reviewer start leaves the last run's sha, effort and mode
effenv refused-review '[{"filename": "src/a.ts", "changes": 12}]' 'Tier: fix'
mkdir -p "$CANCCU_HOME/reviews"; echo old > "$CANCCU_HOME/reviews/50.sha"; echo fixcheck > "$CANCCU_HOME/reviews/50.mode"
touch "$FAKE/refuse"
dispatch --once
ok "a refused reviewer start: no run" test ! -e "$WORKERS_DIR/web-review-50.lock"
ok "… reviews/50.sha and .mode keep the last run's" eq "$(cat "$CANCCU_HOME/reviews/50.sha" "$CANCCU_HOME/reviews/50.mode" | tr '\n' ' ')" "old fixcheck "
rm -f "$FAKE/refuse"
dispatch --once
ok "a started reviewer: the sha and mode are its" eq "$(cat "$CANCCU_HOME/reviews/50.sha" "$CANCCU_HOME/reviews/50.mode" | tr '\n' ' ')" "$HA review "

# ---------------------------------------------------------------- a narrow token per project

PTOK=fake-project-token-for-tests
# ghlogin <dir>: a gh config dir logged in with the fake project token, as gh auth login writes it
ghlogin() { mkdir -p "$1"; printf 'github.com:\n    oauth_token: %s\n    user: octo\n' "$PTOK" > "$1/hosts.yml"; chmod 600 "$1/hosts.yml"; }
# noptok <files...>: the project token is in none of them
noptok() { ! grep -rqF -- "$PTOK" "$@" 2>/dev/null || { echo "    the project token leaked"; return 1; }; }
gstatus() { PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1; }

# GH_CONFIG_DIR in the project's config: the pass and its run use it, an inherited token is dropped
env_new token-start 'GH_CONFIG_DIR=$CANCCU_HOME/ghp'
G=$CANCCU_HOME/ghp; ghlogin "$G"
issue 3 ready | issues
GH_TOKEN=user-token-from-env GH_CONFIG_DIR=$E/elsewhere dispatch --once
ok "token: a working project login → the issue starts" started 3
ok "… every gh call used the project's config dir" eq "$(cut -f2 "$FAKE/gh.cfg" | sort -u)" "$G"
ok "… none with the token from the environment" eq "$(cut -f2 "$FAKE/gh.env" | sort -u)" user
ok "… the credential check comes before the pass reads GitHub" \
  eq "$(sed '/^api repos\/example-org\/web -q/q' "$FAKE/gh.log" | grep -c '^issue list') $(grep -c '^api repos/example-org/web -q .full_name$' "$FAKE/gh.log")" "0 1"
ok "… the worker run gets the config dir" grep -qx "GH_CONFIG_DIR=$G" "$FAKE/worker.envdump"
ok "… and git's credential helper for it" \
  eq "$(grep -cxE 'GIT_CONFIG_COUNT=4|GIT_CONFIG_VALUE_0=|GIT_CONFIG_VALUE_1=!gh auth git-credential|GIT_CONFIG_KEY_1=credential.https://github.com.helper' "$FAKE/worker.envdump")" 4
ok "… but no token" eq "$(tail -1 "$FAKE/worker.env")" "GH_TOKEN=<unset> GITHUB_TOKEN=<unset> WORKER_GH_TOKEN_FILE=<unset> REVIEWER_TOKEN_FILE=<unset>"
ok "… canccu-status names the project's login" grep -qx "gh: the project's own login ($G)" <<<"$(gstatus)"
ok "… the project token is in no log, output, state, snapshot or run environment" \
  noptok "$FAKE/gh.log" "$FAKE/worker.log" "$FAKE/worker.envdump" "$E/out" "$CANCCU_HOME/dispatch.log" "$CANCCU_HOME/state" "$CANCCU_HOME/status.json" "$WORKERS_DIR"

# the default dir (~/.canccu/projects/<name>/gh): every run kind gets it, the reviewer token stays apart
env_new token-kinds CAP=10; echo TOTAL_CAP=10 > "$CANCCU_ROOT/config"
G=$CANCCU_HOME/gh; ghlogin "$G"
state 5 phase=needs-you pr=50
lib start_issue 7 > /dev/null
lib resume 5 "go on" > /dev/null
lib start_review 50 5 "$HA" > /dev/null
lib start_fixcheck 50 5 "$HA" "$HB" > /dev/null
lib start_answer 5 > /dev/null
ok "token: work, resume, review, fix-check and answerer all started" \
  eq "$(grep -oE -- '--name [^ ]+' "$FAKE/worker.log" | tr '\n' ' ')" "--name #7 --name #5 --name review#50 --name fixcheck#50 --name answer#5 "
ok "… each with the project's config dir" eq "$(grep -c '^=== ' "$FAKE/worker.envdump") $(grep -cx "GH_CONFIG_DIR=$G" "$FAKE/worker.envdump")" "5 5"
ok "… each with git's credential helper for it" eq "$(grep -cx 'GIT_CONFIG_VALUE_1=!gh auth git-credential' "$FAKE/worker.envdump")" 5
ok "… the review setup's git calls too (fetch, worktree)" \
  eq "$(grep -c 'pull/50/head' "$FAKE/git.cfg") $(grep -vc "^$G	4	" "$FAKE/git.cfg")" "2 0"
ok "… the reviewer login check still uses the reviewer token" eq "$(grep -P '^api user\t' "$FAKE/gh.env" | sort -u)" "api user	reviewer"
ok "… the project token is in no run's environment" noptok "$FAKE/worker.envdump" "$FAKE/worker.log" "$WORKERS_DIR"

# a config dir without a login: TOKEN MISSING, nothing happens, one log line
env_new token-missing; mkdir -p "$CANCCU_HOME/gh"
issue 3 ready | issues
dispatch --once; dispatch --once
ok "token missing: nothing starts" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… no gh call but the check (and the labels at start)" eq "$(grep -vcE '^(auth token|label list)' "$FAKE/gh.log")" 0
ok "… one clear log line over two passes" \
  eq "$(grep -cF "TOKEN MISSING (no token in $CANCCU_HOME/gh/hosts.yml; log in with gh auth login --with-token --insecure-storage): project web does nothing until it works" "$CANCCU_HOME/dispatch.log")" 1
ok "… the snapshot says so" eq "$(jq -r '"\(.pass.ok) \(.pass.error)"' "$CANCCU_HOME/status.json")" "false TOKEN MISSING (no token in $CANCCU_HOME/gh/hosts.yml; log in with gh auth login --with-token --insecure-storage)"
ok "… canccu-status shows TOKEN MISSING" grep -q '^TOKEN MISSING (no token in .*/gh/hosts.yml; .*): the dispatcher does nothing for this project' <<<"$(gstatus)"
dispatch --dry-run; rc=$?
ok "… --dry-run stops and says why" eq "$rc $(grep -c '^canccu-dispatch: TOKEN MISSING' "$E/out")" "1 1"
ghlogin "$CANCCU_HOME/gh"; dispatch --once
ok "… once logged in, the next pass runs" started 3
ok "… and the warning resets, so a new failure logs again" test ! -e "$CANCCU_HOME/.warned-credential"

# a login that cannot reach REPO
env_new token-reach; ghlogin "$CANCCU_HOME/gh"; touch "$CANCCU_HOME/gh/noreach"
issue 3 ready | issues
dispatch --once
ok "token cannot reach: nothing starts" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… logged with gh's reason" grep -q 'TOKEN CANNOT REACH example-org/web (gh: gh: Not Found (HTTP 404)): project web does nothing' "$CANCCU_HOME/dispatch.log"
ok "… canccu-status shows TOKEN CANNOT REACH example-org/web" grep -q '^TOKEN CANNOT REACH example-org/web ' <<<"$(gstatus)"
ok "… the token is in no log or snapshot" noptok "$CANCCU_HOME/dispatch.log" "$CANCCU_HOME/status.json" "$E/out" "$FAKE/gh.log"

# a broken project stops alone: the other one keeps running on its own login
penv token-two tools shop
echo tools > "$CANCCU_ROOT/default-project"; echo 'TOTAL_CAP=10' > "$CANCCU_ROOT/config"
ghlogin "$CANCCU_ROOT/projects/tools/gh"; touch "$CANCCU_ROOT/projects/tools/gh/noreach"; ghlogin "$CANCCU_ROOT/projects/shop/gh"
projissues tools 1; projissues shop 11
dispatch --project tools --once; dispatch --project shop --once
ok "two projects: a (cannot reach) starts nothing, b starts its issue" eq "$(pstarted tools 1 && echo a)$(pstarted shop 11 && echo b)" b
ok "… shop's run has shop's config dir, never a's" \
  eq "$(grep -cx "GH_CONFIG_DIR=$CANCCU_ROOT/projects/shop/gh" "$FAKE/worker.envdump") $(grep -c "projects/tools/gh" "$FAKE/worker.envdump")" "1 0"
ok "… tools's log has the line, shop's does not" \
  eq "$(grep -c 'TOKEN CANNOT REACH example-user/tools' "$CANCCU_ROOT/projects/tools/dispatch.log") $(grep -c TOKEN "$CANCCU_ROOT/projects/shop/dispatch.log")" "1 0"

# no config dir: today's behaviour, with a warning
env_new token-none
issue 3 ready | issues
dispatch --once
ok "no config dir: the issue starts on the default login" started 3
ok "… no credential check, every gh call on the default login" \
  eq "$(grep -c '^auth token' "$FAKE/gh.log") $(cut -f2 "$FAKE/gh.cfg" | sort -u)" "0 <default>"
ok "… the run gets no config dir and no git helper" eq "$(grep -cE '^(GH_CONFIG_DIR|GIT_CONFIG_)' "$FAKE/worker.envdump")" 0
ok "… canccu-status warns in one line" \
  eq "$(gstatus | grep -c '^warning: no gh config dir for project web (GH_CONFIG_DIR, or .*/gh): it uses the default gh login')" 1
: > "$FAKE/gh.cfg"; GH_CONFIG_DIR=$CANCCU_ROOT/projects/other/gh dispatch --once
ok "… another project's config dir inherited from tmux is dropped" eq "$(cut -f2 "$FAKE/gh.cfg" | sort -u)" "<default>"
: > "$FAKE/gh.cfg"; GH_CONFIG_DIR=$E/mygh dispatch --once
ok "… the user's own GH_CONFIG_DIR is kept, as today" eq "$(cut -f2 "$FAKE/gh.cfg" | sort -u)" "$E/mygh"

# the spawn: the config dir and git's helper reach the window; without them, empty values override
# what the tmux server inherited
env_new token-spawn; mkdir -p "$E/code/web/.git"; G=$CANCCU_HOME/gh; ghlogin "$G"
: > "$FAKE/tmux.log"
( PATH="$T/tmuxrec:$fb:$PATH"; . "$root/lib/canccu-common.sh"
  CODE_ROOT="$E/code" TMUX_SESSION=canccu-t "$root/libexec/canccu-worker" --quiet web "61 work on it" turns=5 cost=1 min=2 ) > /dev/null 2>&1
ok "spawn: the window gets the project's config dir" grep -qF -- "-e GH_CONFIG_DIR=$G -e GIT_CONFIG_COUNT=4" "$FAKE/tmux.log"
ok "spawn: … and git's credential helper" grep -qF -- '-e GIT_CONFIG_VALUE_1=!gh auth git-credential' "$FAKE/tmux.log"
ok "spawn: … never the token" noptok "$FAKE/tmux.log"
: > "$FAKE/tmux.log"
env PATH="$T/tmuxrec:$fb:$PATH" CODE_ROOT="$E/code" TMUX_SESSION=canccu-t "$root/libexec/canccu-worker" --quiet web "62 work on it" turns=5 cost=1 min=2 > /dev/null 2>&1
ok "spawn: no config dir → sent empty" grep -qF -- '-e GH_CONFIG_DIR= -e GIT_CONFIG_COUNT= ' "$FAKE/tmux.log"
: > "$FAKE/tmux.log"; touch "$FAKE/no-server"
( PATH="$T/tmuxrec:$fb:$PATH"; . "$root/lib/canccu-common.sh"
  CODE_ROOT="$E/code" TMUX_SESSION=canccu-t "$root/libexec/canccu-worker" --quiet web "63 work on it" turns=5 cost=1 min=2 ) > /dev/null 2>&1
ok "spawn, no tmux server yet: the window still gets the project's dir (review #1)" \
  grep -qF -- "-e GH_CONFIG_DIR=$G -e GIT_CONFIG_COUNT=4" <(grep '^new-session ' "$FAKE/tmux.log")
ok "… but the client that starts the server holds no gh dir, owner or git entry" \
  eq "$(grep -cE '^(GH_CONFIG_DIR|CANCCU_GH_OWNER|GIT_CONFIG_)' "$FAKE/tmux.start-env")" 0
rm -f "$FAKE/no-server"
if rt=$(command -v tmux) && [ -x "$rt" ]; then
  sock=canccu-t37-$$
  ( . "$root/lib/canccu-common.sh"; without_gh_env "$rt" -L "$sock" -f /dev/null new-session -d -s proj -e "GH_CONFIG_DIR=$G" sleep 30 ) > /dev/null 2>&1
  genv=$("$rt" -L "$sock" show-environment -g 2>/dev/null); senv=$("$rt" -L "$sock" show-environment -t proj 2>/dev/null)
  "$rt" -L "$sock" kill-server > /dev/null 2>&1
  ok "real tmux: a server started by a project's client has no gh dir or git entry in its global environment" \
    eq "$(grep -cE '^(GH_CONFIG_DIR|CANCCU_GH_OWNER|GIT_CONFIG_)' <<<"$genv")" 0
  ok "real tmux: … while the project's session has its dir" grep -qx "GH_CONFIG_DIR=$G" <<<"$senv"
fi

# another project's values inherited (a pane of its session): a project without a dir drops its
# dir and its four git entries, keeps the user's own git entry (review #3)
env_new token-inherit
issue 3 ready | issues
other=(CANCCU_GH_OWNER=a "GH_CONFIG_DIR=$E/a-gh-elsewhere" GIT_CONFIG_COUNT=5 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x
       GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1=
       "GIT_CONFIG_KEY_2=credential.https://github.com.helper" "GIT_CONFIG_VALUE_2=!gh auth git-credential"
       GIT_CONFIG_KEY_3=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_3=git@github.com:
       GIT_CONFIG_KEY_4=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_4=ssh://git@github.com/)
ok "inherited from project a (dir outside projects/): only the user's own git entry is left" \
  eq "$(env "${other[@]}" bash -c '. "$1/lib/canccu-common.sh"; env' _ "$root" 2>/dev/null | grep -E '^(GH_CONFIG_DIR|CANCCU_GH_OWNER|GIT_CONFIG_)' | sort | tr '\n' ' ')" \
     "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x "
env "${other[@]}" PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1
ok "… the pass's gh calls use the default login" eq "$(cut -f2 "$FAKE/gh.cfg" | sort -u)" "<default>"
ok "… its git calls see only the user's entry" eq "$(cut -f2 "$FAKE/git.cfg" | sort -u)" 1
ok "… and so does its run: no helper, no rewrite, no owner" \
  eq "$(grep -cE '^(GIT_CONFIG_COUNT=1|GIT_CONFIG_KEY_0=user.name)$' "$FAKE/worker.envdump") $(grep -cE 'gh auth git-credential|insteadOf|^CANCCU_GH_OWNER|^GH_CONFIG_DIR' "$FAKE/worker.envdump")" "2 0"
ok "a project with its own dir: the owner is set, the entries added once after the user's" \
  eq "$(mkdir -p "$CANCCU_HOME/gh"; env "${other[@]}" GIT_CONFIG_KEY_1=x.y "GIT_CONFIG_VALUE_1=!gh auth git-credential" bash -c '. "$1/lib/canccu-common.sh"; echo "$CANCCU_GH_OWNER $GIT_CONFIG_COUNT $GIT_CONFIG_KEY_1 $GIT_CONFIG_KEY_3"' _ "$root" 2>/dev/null)" \
     "web 6 x.y credential.https://github.com.helper"
rm -rf "$CANCCU_HOME/gh"

# a dir whose hosts.yml holds no token (a keyring login): TOKEN MISSING, even though gh would fall
# back to the keyring's default login and reach the repo (review #4)
env_new token-keyring; mkdir -p "$CANCCU_HOME/gh"; printf 'github.com:\n    user: octo\n    git_protocol: https\n' > "$CANCCU_HOME/gh/hosts.yml"
issue 3 ready | issues
dispatch --once
ok "keyring login: TOKEN MISSING, nothing starts" \
  eq "$(wc -l < "$FAKE/worker.log") $(grep -c 'TOKEN MISSING (no token in .*/gh/hosts.yml' "$CANCCU_HOME/dispatch.log")" "0 1"
ok "… and no gh call reached GitHub for it" eq "$(grep -vcE '^label list' "$FAKE/gh.log")" 0

# no answer from GitHub is not a bad token
env_new token-down; ghlogin "$CANCCU_HOME/gh"; touch "$CANCCU_HOME/gh/down"
issue 3 ready | issues
dispatch --once
ok "GitHub down: CREDENTIAL CHECK FAILED, not TOKEN CANNOT REACH; nothing starts" \
  eq "$(wc -l < "$FAKE/worker.log") $(grep -c 'CREDENTIAL CHECK FAILED (GitHub did not answer for example-org/web; gh: dial tcp' "$CANCCU_HOME/dispatch.log") $(grep -c 'TOKEN CANNOT REACH' "$CANCCU_HOME/dispatch.log")" "0 1 0"

# the real git: a push's credential comes from gh for the project's config dir, never from the
# user's own helper, and an ssh remote of github.com goes over https
env_new token-git; G=$CANCCU_HOME/gh; ghlogin "$G"
mkdir -p "$E/cb" "$E/h"
printf '#!/bin/sh\n[ "$1 $2" = "auth git-credential" ] || exit 1\necho "$GH_CONFIG_DIR" >> "$FAKE/gitcred.log"\necho username=x-access-token\necho password=from-gh\n' > "$E/cb/gh"
chmod +x "$E/cb/gh"
printf 'https://octo:from-store@%s\n' github.com > "$E/h/store"
printf '[credential]\n\thelper = store --file %s\n' "$E/h/store" > "$E/h/.gitconfig"
git init -q "$E/repo" && git -C "$E/repo" remote add origin git@github.com:example-org/web.git
out=$( export HOME=$E/h GIT_CONFIG_NOSYSTEM=1 PATH="$E/cb:$PATH"; . "$root/lib/canccu-common.sh"
       printf 'protocol=https\nhost=github.com\npath=example-org/web.git\n\n' | git credential fill
       git -C "$E/repo" remote get-url --push origin ) 2>&1
ok "git: the credential comes from gh" grep -qx 'password=from-gh' <<<"$out"
ok "… for the project's config dir" eq "$(cat "$FAKE/gitcred.log" 2>/dev/null)" "$G"
ok "… never from the user's own helper" not grep -q from-store <<<"$out"
ok "… an ssh remote of github.com is pushed over https" grep -qx 'https://github.com/example-org/web.git' <<<"$out"
out=$( export HOME=$E/h GIT_CONFIG_NOSYSTEM=1; . "$root/lib/canccu-common.sh"; . "$root/lib/canccu-common.sh"; echo "$GIT_CONFIG_COUNT" ) 2>&1
ok "… set once, even when the lib is read twice" eq "$out" 4


echo "canccu-projects tests: $npass passed, $nfail failed"
(( nfail == 0 ))
