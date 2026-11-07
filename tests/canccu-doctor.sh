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
}
doctor() { hrun "$P/bin/canccu-dispatcher" doctor "$@"; }
line() { grep -c -- "$1" "$E/out"; }

clean_host clean
doctor
ok "a clean host: exit 0" eq "$rc" 0
ok "… one line that says so" eq "$(cat "$E/out")" "no problems found"
mkdir -p "$C/projects/web/workers"
printf 'repo=web\nkey=5\nkind=worker\npid=%s\nwindow=\nstarted=1\n' "$$" > "$C/projects/web/workers/web-5.lock"
jq -n --argjson at "$(date +%s)" '{schema: 2, version: "9.9.0", pass: {at: $at, ok: true}}' > "$C/projects/web/status.json"
doctor
ok "… a live run and a fresh snapshot are no problem" eq "$rc $(cat "$E/out")" "0 no problems found"
# Claude's own path forms, not shell paths: ~ is Claude's to expand
# shellcheck disable=SC2088
for pat in '~/.canccu/**' '/'"$H"'/.canccu/reviewer-token' '~/.canccu/*-token'; do
  echo "{\"permissions\": {\"deny\": [\"Read($pat)\"]}}" > "$H/.claude/settings.json"; doctor
  ok "the token covered by Read($pat)" eq "$rc" 0
done

clean_host off-path
IPATH=${IPATH#"$P/bin:"}; hrun "$P/bin/canccu-dispatcher" doctor
ok "the prefix bin dir not on the user's PATH: named" eq "$rc $(line '/.local/bin is not on PATH')" "1 1"

clean_host no-project
rm -rf "$C/projects"
doctor
ok "no project yet, the logins in ~/.canccu/config: clean" eq "$rc $(cat "$E/out")" "0 no problems found"
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
ok "… one line per problem, nothing else" eq "$(grep -cvE '^(claude|release|canccu-|HOST_PROFILE|project |reviewer token|~)' "$E/out")" 0
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

echo "canccu-doctor tests: $npass passed, $nfail failed"
(( nfail == 0 ))
