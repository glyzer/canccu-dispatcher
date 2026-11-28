#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-doctor.sh — canccu-dispatcher doctor in a fake HOME, offline: a clean host (exit 0)
# and a dirty one, each problem on a line of its own (the harness: tests/lib/harness.sh and
# tests/lib/install.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=lib/install.sh
. "$(dirname "$0")/lib/install.sh"

src_copy "$T/src0" 9.9.0; src_copy "$T/src1" 9.9.1
# a host set up the way docs/install.md says: installed, a host profile, the logins, the token
# behind a deny rule, one project with its rules and clone
clean_host() {
  inst_env "$1"
  IPATH="$P/bin:$IPATH"
  inst "$T/src0" --no-monitor --host-profile max
  printf 'USER_LOGIN=octo\nREVIEWER_LOGIN=review-bot\n' >> "$C/config"
  printf '%s\n' "$FAKE_TOKEN" > "$C/reviewer-token"; chmod 600 "$C/reviewer-token"
  mkdir -p "$H/.claude"; echo '{"permissions": {"deny": ["Read(~/.canccu/reviewer-token)", "Edit(~/.canccu/reviewer-token)"]}}' > "$H/.claude/settings.json"
  mkdir -p "$C/projects/web" "$H/code/web"; git -C "$H/code/web" init -q
  printf 'REPO=example-org/web\nCLONE=%s\n' "$H/code/web" > "$C/projects/web/config"
  cp "$root/tests/fixtures/rules/web" "$C/projects/web/rules"
  # the project's own gh login (the fake gh reaches every repo)
  mkdir -p "$C/projects/web/gh"; printf 'github.com:\n    oauth_token: fake-project-token\n' > "$C/projects/web/gh/hosts.yml"
}
doctor() { hrun "$P/bin/canccu-dispatcher" doctor "$@"; }
# the problem lines, and the host report (lines "host: ") after them
probs() { grep -v "^host: " "$E/out"; }
line() { probs | grep -c -- "$1"; }
hline() { grep -c -- "$1" "$E/out"; }

clean_host clean
doctor
ok "a clean host: exit 0" eq "$rc" 0
ok "… one line that says so" eq "$(probs)" "no problems found"
mkdir -p "$C/projects/web/workers"
printf 'repo=web\nkey=5\nkind=worker\npid=%s\nwindow=\nstarted=1\n' "$$" > "$C/projects/web/workers/web-5.lock"
jq -n --argjson at "$(date +%s)" '{schema: 2, version: "9.9.0", pass: {at: $at, ok: true}}' > "$C/projects/web/status.json"
doctor
ok "… a live run and a fresh snapshot are no problem" eq "$rc $(probs)" "0 no problems found"
mkdir -p "$C/projects/web/workers/tmp/web-5.$$"; truncate -s 4G "$C/projects/web/workers/tmp/web-5.$$/big"   # sparse: no disk used
doctor
ok "… run temp dirs under 5 GB are no problem" eq "$rc $(probs)" "0 no problems found"
# Claude's own path forms, not shell paths: ~ is Claude's to expand
# shellcheck disable=SC2088
for pat in '~/.canccu/**' '/'"$H"'/.canccu/reviewer-token' '~/.canccu/*-token'; do
  echo "{\"permissions\": {\"deny\": [\"Read($pat)\"]}}" > "$H/.claude/settings.json"; doctor
  ok "the token covered by Read($pat)" eq "$rc" 0
done

# the host's room (#238): /tmp or memory under 10% free, a container no run tagged that runs for
# over 2 days; a tagged one, a stopped one and a young one are no problem
clean_host room
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\ntmpfs 16777216 16043212 734004 96%% /tmp\n' > "$FAKE/df"
printf 'MemTotal: 16777216 kB\nMemAvailable: 1048576 kB\n' > "$FAKE/meminfo"
d3=$(date -u -d '3 days ago' '+%F %T +0000 UTC') d1=$(date -u -d '1 day ago' '+%F %T +0000 UTC')
{ printf 'c1\tpkg211-agenda-pg\trunning\t%s\t\t\n' "$d3"; printf 'c2\tm383-pg\trunning\t%s\t\tlook\n' "$d3"
  printf 'c3\tweb5-pg\trunning\t%s\tcanccu_web_5\t\n' "$d3"; printf 'c4\tdb\trunning\t%s\t\tcanccu_web_review-5\n' "$d3"
  printf 'c5\told\texited\t%s\t\t\n' "$d3"; printf 'c6\tnew\trunning\t%s\t\t\n' "$d1"; } > "$FAKE/docker.containers"
CANCCU_MEMINFO=$FAKE/meminfo doctor
ok "room: /tmp under 10% free is a problem" eq "$(line '^/tmp: 716.8M free of 16.0G: what runs leave there fills it (du -sh /tmp/\*)$')" 1
ok "… memory under 10% available too" eq "$(line '^memory: 1.0G available of 16.0G: Claude Code kills background tasks when it runs out$')" 1
ok "… and the untagged containers over 2 days old, by name" \
  eq "$(line '^2 container(s) no run tagged have run for over 2 days (pkg211-agenda-pg, m383-pg): remove the ones nothing needs (docker rm -f -v <name>)$')" 1
ok "… three problems: exit 1" eq "$rc $(probs | wc -l)" "1 3"
rm "$FAKE/df" "$FAKE/docker.containers"; doctor
ok "room: enough /tmp and memory, no old containers: no problem" eq "$rc $(probs)" "0 no problems found"

clean_host no-login
rm -r "$C/projects/web/gh"; doctor
ok "a project without its own gh login: named, with the steps" \
  eq "$rc $(line '^project web: no gh login of its own (GH_CONFIG_DIR) and ALLOW_DEFAULT_GH_LOGIN=0: it starts no run; to set one up, create a fine-grained token for example-org/web only (Repository permissions: Contents, Issues and Pull requests, read and write), then GH_CONFIG_DIR=~/.canccu/projects/web/gh gh auth login --with-token --insecure-storage < <the token file>$')" "1 1"
ok "… on one line" eq "$(probs | wc -l)" 1
echo ALLOW_DEFAULT_GH_LOGIN=1 >> "$C/projects/web/config"; doctor
ok "… ALLOW_DEFAULT_GH_LOGIN=1: no problem" eq "$rc $(probs)" "0 no problems found"

clean_host off-path
IPATH=${IPATH#"$P/bin:"}; hrun "$P/bin/canccu-dispatcher" doctor
ok "the prefix bin dir not on the user's PATH: named" eq "$rc $(line '/.local/bin is not on PATH')" "1 1"

# a token outside HOME: the rule doctor suggests is the one that then covers it
clean_host token-outside
mkdir -p "$E/tokens"; mv "$C/reviewer-token" "$E/tokens/rt"; echo "REVIEWER_TOKEN_FILE=$E/tokens/rt" >> "$C/config"
doctor
rule=$(grep -o 'add "Read([^)]*)"' "$E/out" | sed 's/^add "//; s/"$//')
ok "a token outside HOME: the suggested rule is Claude's absolute form" eq "$rule" "Read(/$E/tokens/rt)"
jq -n --arg r "$rule" '{permissions: {deny: [$r]}}' > "$H/.claude/settings.json"
doctor
ok "… and with it the host is clean" eq "$rc $(probs)" "0 no problems found"

# PREFIX/bin itself a link (~/.local/bin → ~/bin), on PATH as ~/.local/bin
inst_env bin-link
mkdir -p "$H/bin" "$P"; ln -s ../bin "$P/bin"
IPATH="$P/bin:$IPATH"
inst "$T/src0" --no-monitor
doctor
ok "PREFIX/bin a link: no command called another install's" eq "$(grep -c 'on PATH is' "$E/out")" 0

clean_host no-project
rm -rf "$C/projects"
doctor
ok "no project yet, the logins in ~/.canccu/config: clean" eq "$rc $(probs)" "0 no problems found"
sed -i 's/^USER_LOGIN=octo$//' "$C/config"; chmod 644 "$C/reviewer-token"
doctor
ok "… without USER_LOGIN: named, with the token's mode" eq "$rc $(line 'USER_LOGIN is not set in ~/.canccu/config') $(line 'has mode 644')" "1 1 1"

# ---------------------------------------------------------------- a dirty host

clean_host dirty
echo --verbose > "$FAKE/claude-drop"
echo "# edited" >> "$R/9.9.0/README.md"
rm "$P/bin/canccu-up"; ln -sfn "$E/old/canccu-stop" "$P/bin/canccu-stop"
sed -i 's/^HOST_PROFILE=max$//; s/^USER_LOGIN=octo$//' "$C/config"
chmod 644 "$C/reviewer-token"; echo '{"permissions": {"deny": ["Read(~/.ssh/**)"]}}' > "$H/.claude/settings.json"
mkdir -p "$C/projects/tools/gh" "$C/projects/shop"
printf 'REPO=example-user/tools\nCLONE=%s\n' "$H/code/tools" > "$C/projects/tools/config"
cp "$root/tests/fixtures/rules/web" "$C/projects/tools/rules"
printf 'REPO=example-org/shop\n' > "$C/projects/shop/config"
mkdir -p "$C/projects/web/workers"
printf 'repo=web\nkey=6\nkind=worker\npid=999999999\nwindow=\nstarted=1\n' > "$C/projects/web/workers/web-6.lock"
jq -n '{schema: 2, pass: {at: 1000, ok: false, error: "gh error"}}' > "$C/projects/web/status.json"
mkdir -p "$C/projects/web/workers/tmp/web-6.999999999"; truncate -s 6G "$C/projects/web/workers/tmp/web-6.999999999/big"
holder "$C/projects/web/.dispatch.lock" "$E/stray"
doctor
ok "a dirty host: exit 1" eq "$rc" 1
ok "… claude without a flag" eq "$(line 'claude: its --help lacks --verbose')" 1
ok "… a changed release" eq "$(line 'release 9.9.0 is incomplete or changed')" 1
ok "… a command not linked" eq "$(line 'canccu-up is not linked')" 1
ok "… a link into another install" eq "$(line "canccu-stop links to $E/old/canccu-stop")" 1
ok "… no host profile" eq "$(line 'HOST_PROFILE is not set')" 1
ok "… USER_LOGIN unset, per project" eq "$(line 'project web: USER_LOGIN is not set') $(line 'project tools: USER_LOGIN is not set')" "1 1"
ok "… the token's mode" eq "$(line 'has mode 644, not 600')" 1
ok "… no deny rule for the token" eq "$(line 'no Claude deny rule covers it')" 1
ok "… a project's clone missing" eq "$(line "project tools: the clone ~/code/tools is not a git checkout")" 1
ok "… a project's gh login without a token" eq "$(line 'project tools: TOKEN MISSING')" 1
ok "… a project without rules or CLONE" eq "$(line "project shop:")" 1
ok "… a dispatcher lock held by no dispatcher" eq "$(line 'project web: its dispatcher lock is held, but no canccu-dispatch runs')" 1
ok "… an old snapshot while the lock is held" eq "$(line 'project web: the status snapshot is ')" 1
ok "… a failed last pass" eq "$(line 'project web: the last pass failed: gh error')" 1
ok "… a stale run lock" eq "$(line 'project web: stale run lock ~/.canccu/projects/web/workers/web-6.lock')" 1
ok "… run temp dirs over 5 GB" eq "$(line 'project web: run temp dirs use 6.0G; a run may leak, check ~/.canccu/projects/web/workers/tmp$')" 1
ok "… one line per problem, nothing else" eq "$(grep -cvE '^(claude|release|canccu-|HOST_PROFILE|project |reviewer token|~)' <(probs))" 0
ok "… the token never shows" notoken "$E/out"
doctor --project tools
ok "--project tools: that project's lines only" eq "$(line 'project web:') $(line 'project tools: TOKEN MISSING')" "0 1"
doctor --project nope
ok "--project with an unknown name: refused with the list" eq "$rc $(line "no project 'nope'. Projects: shop tools web")" "1 1"
holders_stop

clean_host old-release
holder_fd "$R/9.9.0/bin/canccu-dispatch"
inst "$T/src1" --no-monitor
doctor
ok "a process on an older release: named" eq "$rc $(line 'runs release 9.9.0; current is 9.9.1: restart it')" "1 1"
holders_stop

clean_host unknown-profile
sed -i 's/^HOST_PROFILE=max$/HOST_PROFILE=nosuch/' "$C/config"; doctor
ok "an unknown host profile: named with the list" eq "$rc $(line "no host profile 'nosuch'")" "1 1"
clean_host not-installed
rm -rf "$B"; hrun bash "$T/src0/bin/canccu-dispatcher" doctor
ok "nothing installed: said" eq "$rc $(line 'not installed in ~/.local')" "1 1"

# the host report (#14): the profile, what ~/.canccu/config changes, and the last day's runs
clean_host host-report
echo CAP=1 >> "$C/config"
mkdir -p "$C/projects/web/workers"; now=$(date +%s)
for k in 5 review-5 5 fix-5 7; do printf '%s\tweb\t%s\t0.50\tbuild\tm\n' "$((now - 600))" "$k"; done > "$C/projects/web/workers/spend.log"
printf '%s\tweb\t5\t?\tbuild\tm\n%s\tweb\t9\t1.00\tbuild\tm\n' "$((now - 300))" "$((now - 90000))" >> "$C/projects/web/workers/spend.log"
doctor
ok "host report: the problems are unchanged" eq "$rc $(probs)" "0 no problems found"
ok "… the profile" eq "$(hline '^host: profile max$')" 1
ok "… a key the host's config changes, with the profile's value" eq "$(hline '^host: ~/.canccu/config sets CAP=1; max: 2$')" 1
ok "… one the profile leaves at the default" eq "$(hline '^host: ~/.canccu/config sets USER_LOGIN=octo; max: (empty)$')" 1
ok "… not the profile's own keys, nor HOST_PROFILE" eq "$(hline 'sets MODEL=\|sets HOST_PROFILE=')" 0
ok "… an issue's runs of every kind, more than 3 marked" eq "$(hline '^host: project web: #5: 5 runs, \$2.00 (1 without a cost); more than 3 runs')" 1
ok "… one run, unmarked" eq "$(hline '^host: project web: #7: 1 run, \$0.50$')" 1
ok "… a run older than a day: left out" eq "$(hline '#9')" 0
rm "$C/projects/web/workers/spend.log"; doctor
ok "… no runs: said" eq "$(hline '^host: project web: no runs in the last 24 h$')" 1
# #250: the test tier the workers are told, the host's and a project's own
ok "… the test tier, from the profile" eq "$(hline '^host: test tier targeted$')" 1
ok "… no project line while a project keeps it" eq "$(hline '^host: project web: test tier')" 0
echo TEST_TIER=full >> "$C/projects/web/config"; doctor
ok "… a project's own tier" eq "$(hline '^host: project web: test tier full$')" 1
echo 'if then' >> "$C/projects/web/config"; doctor
ok "… a project whose config does not load: unknown, never a guessed tier" eq "$(hline '^host: project web: test tier unknown$')" 1

# the pre-push check (#328): the host report shows it, and a command not found is a problem
clean_host prepush; doctor
ok "pre-push: unset, no line" eq "$(hline 'pre-push')" 0
echo 'PRE_PUSH_CMD="no-such-lint --quiet"' >> "$C/projects/web/config"; doctor
ok "… set: the host report shows it with its limit" eq "$(hline '^host: project web: pre-push check `no-such-lint --quiet` (at most 600 s)$')" 1
ok "… a command not on PATH nor in the clone is a problem" eq "$(line '^project web: PRE_PUSH_CMD: no-such-lint is not on PATH nor in the clone: every worker push would be refused$')" 1
mkdir -p "$H/code/web/bin"; printf '#!/bin/sh\n' > "$H/code/web/bin/lint"; chmod +x "$H/code/web/bin/lint"
echo 'PRE_PUSH_CMD=bin/lint' >> "$C/projects/web/config"; doctor
ok "… a script of the repo is found in the clone" eq "$(line 'PRE_PUSH_CMD')" 0

# the skills line (#43): the worker method or the host's WORKER_SKILLS, and whether the plugin is on
clean_host skills; doctor
ok "skills: right after the profile line" eq "$(grep -A1 '^host: profile max$' "$E/out" | tail -1)" 'host: skills: worker method in plain words (WORKER_SKILLS is empty); superpowers plugin not installed'
ok "… never a problem line" eq "$rc $(probs)" "0 no problems found"
echo '{"enabledPlugins": {"superpowers@claude-plugins-official": true}}' > "$H/.claude/settings.json"; doctor
ok "… the plugin enabled: installed" eq "$(hline '^host: skills: worker method in plain words (WORKER_SKILLS is empty); superpowers plugin installed$')" 1
echo "WORKER_SKILLS='Use the superpowers skills.'" >> "$C/config"; doctor
ok "… WORKER_SKILLS set, the plugin installed" eq "$(hline '^host: skills: WORKER_SKILLS is set; superpowers plugin installed$')" 1
echo '{"enabledPlugins": {"superpowers@claude-plugins-official": false, "other@x": true}}' > "$H/.claude/settings.json"; doctor
ok "… WORKER_SKILLS set, the plugin disabled: not installed" eq "$(hline '^host: skills: WORKER_SKILLS is set; superpowers plugin not installed$')" 1
rm "$H/.claude/settings.json"; doctor
ok "… no settings file: not installed" eq "$(hline '^host: skills: WORKER_SKILLS is set; superpowers plugin not installed$')" 1

echo "canccu-doctor tests: $npass passed, $nfail failed"
(( nfail == 0 ))
