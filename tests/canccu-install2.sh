#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-install2.sh — releases over time, in a fake HOME, offline: an upgrade while a
# dispatcher runs (its release stays), pruning that skips a release in use, rollback, and
# uninstall with and without the state dir (the harness: tests/lib/harness.sh and
# tests/lib/install.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=lib/install.sh
. "$(dirname "$0")/lib/install.sh"

for v in 0 1 2 3 4 5; do src_copy "$T/src$v" "9.9.$v"; done
rels() { ls "$R" 2>/dev/null | tr '\n' ' '; }
cur() { readlink "$B/current"; }

# ---------------------------------------------------------------- an upgrade while a dispatcher runs

inst_env upgrade
inst "$T/src0" --no-monitor
mkdir -p "$C/projects/web"
holder "$C/projects/web/.dispatch.lock" "$R/9.9.0/bin/canccu-dispatch"; d0=$HPID
sum0=$(cd "$R/9.9.0" && find . -type f -exec md5sum {} + | sort)
inst "$T/src1" --no-monitor
ok "an upgrade while a dispatcher holds its lock: installed" eq "$rc $(cur)" "0 releases/9.9.1"
ok "… the dispatcher's release stays, unchanged" eq "$(cd "$R/9.9.0" && find . -type f -exec md5sum {} + | sort)" "$sum0"
ok "… the install names the process still on it" out_has "pid $d0 still runs release 9.9.0"
ok "… the lock is still held" not flock -n "$C/projects/web/.dispatch.lock" true
# the same version with other files, while a process runs from it: refused
echo "# changed" >> "$T/src0/README.md"
inst "$T/src0" --no-monitor
ok "a release in use is never rewritten: refused" eq "$rc $(cur)" "1 releases/9.9.1"
ok "… its files unchanged" eq "$(cd "$R/9.9.0" && find . -type f -exec md5sum {} + | sort)" "$sum0"
ok "… and it says why" out_has "processes run from it (pid $d0)"
holders_stop
inst "$T/src0" --no-monitor
ok "… once nothing runs from it, it is replaced" eq "$rc $(cur) $(grep -c changed "$R/9.9.0/README.md")" "0 releases/9.9.0 1"
src_copy "$T/src0" 9.9.0

# ---------------------------------------------------------------- pruning

inst_env prune
inst "$T/src0" --no-monitor
holder_fd "$R/9.9.0/bin/canccu-dispatch"
for v in 1 2 3 4; do inst "$T/src$v" --no-monitor; done
ok "the last three releases are kept, and one in use" eq "$(rels)" "9.9.0 9.9.2 9.9.3 9.9.4 "
ok "… the install says why it kept it" out_has "kept release 9.9.0: a process runs from it"
holders_stop
inst "$T/src5" --no-monitor
ok "… removed once nothing runs from it" eq "$(rels)" "9.9.3 9.9.4 9.9.5 "
ok "… the install says so" out_has "removed release 9.9.0"
# a python process runs from its argv (the monitor: python3 <release>/lib/canccu-monitor.py)
inst_env prune-argv
inst "$T/src0" --no-monitor
( exec -a python3 bash -c 'while :; do sleep 1; done' x "$R/9.9.0/lib/canccu-monitor.py" ) >/dev/null 2>&1 & HOLDERS+=($!); sleep 0.2
for v in 1 2 3; do inst "$T/src$v" --no-monitor; done
ok "a release named in a process's arguments is in use" eq "$(rels)" "9.9.0 9.9.1 9.9.2 9.9.3 "
holders_stop

# ---------------------------------------------------------------- rollback

inst_env rollback
for v in 0 1 2; do inst "$T/src$v" --no-monitor; done
hrun "$P/bin/canccu-dispatcher" rollback
ok "rollback: current is the previous release" eq "$rc $(cur)" "0 releases/9.9.1"
ok "… it says so" out_has "current is release 9.9.1 (was 9.9.2)"
ok "… the commands run it" eq "$(HOME=$H "$P/bin/canccu-dispatcher" --version)" "canccu-dispatcher 9.9.1"
hrun "$P/bin/canccu-dispatcher" rollback --prefix "$P"
ok "rollback again: the one before" eq "$rc $(cur)" "0 releases/9.9.0"
hrun "$P/bin/canccu-dispatcher" rollback
ok "no release before: refused, current unchanged" eq "$rc $(cur) $(grep -c 'no release before 9.9.0' "$E/out")" "1 releases/9.9.0 1"
inst "$T/src3" --no-monitor
ok "an install after a rollback: the new one is current" eq "$(cur)" "releases/9.9.3"
hrun "$P/bin/canccu-dispatcher" rollback
ok "… and rollback goes to the one installed before it" eq "$(cur)" "releases/9.9.2"
inst_env rollback-reinstall
for v in 0 1 0; do inst "$T/src$v" --no-monitor; done
hrun "$P/bin/canccu-dispatcher" rollback
ok "install A, B, A again: rollback goes back to B" eq "$rc $(cur)" "0 releases/9.9.1"
# B drops a command A has and adds one of its own: a rollback to A puts PREFIX/bin back as A has it
inst_env rollback-links
src_copy "$E/b" 9.9.1; rm "$E/b/bin/canccu-pause"; cp "$E/b/bin/canccu-resume" "$E/b/bin/canccu-newcmd"
inst "$T/src0" --no-monitor; inst "$E/b" --no-monitor
ok "B installed: its links" eq "$(test -L "$P/bin/canccu-pause" && echo pause) $(test -L "$P/bin/canccu-newcmd" && echo new)" " new"
hrun "$P/bin/canccu-dispatcher" rollback
ok "rollback to A: A's command linked again, B's own gone" eq "$rc $(readlink "$P/bin/canccu-pause") $(test -e "$P/bin/canccu-newcmd" || test -L "$P/bin/canccu-newcmd" && echo new)" \
  "0 $B/current/bin/canccu-pause "

# an older release's own commands never count as processes left on it
inst_env own-pids
inst "$T/src0" --no-monitor; inst "$T/src1" --no-monitor
hrun "$R/9.9.0/bin/canccu-dispatcher" doctor
ok "doctor run from an older release does not name itself" eq "$(grep -c 'still in use' "$E/out")" 0

# a checkout's commands reached through PREFIX/bin act on that prefix
inst_env dev-prefix
D=$E/checkout; src_copy "$D" 9.9.0
(cd "$D" && git init -q && git -c user.name=octo -c user.email=octo@users.noreply.github.com add -A &&
  git -c user.name=octo -c user.email=octo@users.noreply.github.com commit -qm one) >/dev/null 2>&1
inst "$D" --dev --no-monitor --prefix "$E/opt"
hrun "$E/opt/bin/canccu-dispatcher" doctor
ok "--dev --prefix DIR: doctor through DIR/bin checks DIR" eq "$(grep -c 'not installed in' "$E/out") $(grep -c 'links to' "$E/out")" "0 0"
hrun "$E/opt/bin/canccu-dispatcher" uninstall
ok "… and uninstall removes DIR's tree" eq "$rc $(test -e "$E/opt/lib/canccu-dispatcher" && echo tree)" "0 "

inst_env rollback-none
inst "$T/src0" --no-monitor
hrun "$P/bin/canccu-dispatcher" rollback
ok "rollback with one release: refused" eq "$rc $(cur)" "1 releases/9.9.0"
hrun bash "$T/src0/bin/canccu-dispatcher" rollback --prefix "$E/nothing"
ok "rollback where nothing is installed: refused, named" eq "$rc $(grep -c 'nothing installed' "$E/out")" "1 1"

# ---------------------------------------------------------------- uninstall

inst_env uninstall
inst "$T/src0"
mkdir -p "$E/old/bin" "$C/projects/web/workers"; ln -s "$E/old/bin/canccu-x" "$P/bin/canccu-x"; ln -s "$E/old/bin/other" "$P/bin/other"
holder "$C/projects/web/.dispatch.lock" "$R/9.9.0/bin/canccu-dispatch"
hrun "$P/bin/canccu-dispatcher" uninstall
ok "uninstall while a dispatcher holds its lock: refused" eq "$rc $(cur)" "1 releases/9.9.0"
ok "… it names the project" out_has "project web"
ok "… and --force" out_has "--force"
hrun "$P/bin/canccu-dispatcher" uninstall --purge-state --yes --force
ok "--purge-state while a lock is held: refused, even with --force" eq "$rc $(cur) $(test -d "$C" && echo state)" "1 releases/9.9.0 state"
hrun "$P/bin/canccu-dispatcher" uninstall --force
ok "--force: the tree goes" eq "$rc $(test -e "$B" && echo tree)" "0 "
ok "… the links into it" eq "$(find "$P/bin" -name 'canccu-*' -lname "$B/*" | wc -l)" 0
ok "… not the links elsewhere" eq "$(readlink "$P/bin/canccu-x") $(readlink "$P/bin/other")" "$E/old/bin/canccu-x $E/old/bin/other"
ok "… the venv goes" not test -e "$H/.local/share/canccu/venv"
ok "… the state dir stays" test -d "$C/projects/web"
holders_stop

# a run still live after its dispatcher stopped: its release stays unless --force
inst_env uninstall-run
inst "$T/src0" --no-monitor
mkdir -p "$C/projects/web/workers"
printf 'repo=web\nkey=5\nkind=worker\npid=%s\nwindow=\nstarted=1\n' "$$" > "$C/projects/web/workers/web-5.lock"
hrun "$P/bin/canccu-dispatcher" uninstall
ok "uninstall while a run's lock is live: refused" eq "$rc $(cur) $(grep -c 'web-5.lock' "$E/out")" "1 releases/9.9.0 1"
hrun "$P/bin/canccu-dispatcher" uninstall --force
ok "… --force removes it anyway" eq "$rc $(test -e "$B" && echo tree)" "0 "

inst_env purge
inst "$T/src0" --no-monitor
printf 'TOTAL_CAP=4\n' > "$C/config"
hrun "$P/bin/canccu-dispatcher" uninstall --purge-state
ok "--purge-state without --yes: refused, nothing removed" eq "$rc $(cur) $(test -d "$C" && echo state)" "2 releases/9.9.0 state"
mkdir -p "$C/projects/web/workers"
printf 'repo=web\nkey=5\nkind=worker\npid=%s\nwindow=\nstarted=1\n' "$$" > "$C/projects/web/workers/web-5.lock"
hrun "$P/bin/canccu-dispatcher" uninstall --purge-state --yes
ok "--purge-state --yes while a run's lock is live: refused" eq "$rc $(test -d "$C" && echo state) $(grep -c 'web-5.lock' "$E/out")" "1 state 1"
printf 'repo=web\nkey=5\nkind=worker\npid=999999999\nwindow=\nstarted=1\n' > "$C/projects/web/workers/web-5.lock"
hrun "$P/bin/canccu-dispatcher" uninstall --purge-state --yes
ok "--purge-state --yes, no lock held: the state dir goes too" eq "$rc $(test -e "$C" && echo state) $(test -e "$B" && echo tree)" "0  "
ok "… it says so" out_has "removed the state dir ~/.canccu"

inst_env uninstall-venv
inst "$T/src0" --venv "$E/v"
mkdir -p "$E/other-venv"
hrun "$P/bin/canccu-dispatcher" uninstall
ok "uninstall: the venv the install built, wherever it is" eq "$rc $(test -e "$E/v" && echo v)" "0 "

# a HOME reached through a symlink: install, doctor, an explicit --prefix and uninstall all
# agree on whose links are whose
inst_env symlink-home
mkdir -p "$E/real/home"; ln -s real "$E/link"
H=$E/link/home P=$E/link/home/.local C=$E/link/home/.canccu B=$E/link/home/.local/lib/canccu-dispatcher R=$B/releases
IPATH="$P/bin:$IPATH"
inst "$T/src0" --no-monitor
ok "a symlinked HOME: installed" eq "$rc $(cur)" "0 releases/9.9.0"
hrun "$P/bin/canccu-dispatcher" doctor
ok "… doctor finds the links and PATH as they are" eq "$(grep -cE 'links to|not linked|not on PATH|on PATH is' "$E/out")" 0
inst "$T/src0" --no-monitor --prefix "$H/.local"
ok "… an explicit --prefix of the same dir calls no link foreign" eq "$rc $(grep -c 'kept ' "$E/out")" "0 0"
hrun "$P/bin/canccu-dispatcher" uninstall
ok "… uninstall removes every link into its tree" eq "$rc $(find "$P/bin" -type l | wc -l)" "0 0"
# --dev: the commands run the checkout, whose default prefix is ~/.local, resolved like install.sh's
D=$E/checkout; src_copy "$D" 9.9.0
(cd "$D" && git init -q && git -c user.name=octo -c user.email=octo@users.noreply.github.com add -A &&
  git -c user.name=octo -c user.email=octo@users.noreply.github.com commit -qm one) >/dev/null 2>&1
inst "$D" --dev --no-monitor
ok "a symlinked HOME, --dev: current is the checkout" eq "$rc $(cur)" "0 $D"
hrun "$P/bin/canccu-dispatcher" doctor
ok "… doctor (run from the checkout) finds the links and PATH as they are" eq "$(grep -cE 'links to|not linked|not on PATH|on PATH is|not installed' "$E/out")" 0
# a link written through the symlinked form of the prefix (an older install, or by hand): ours
ln -s "$B/current/bin/canccu-status" "$P/bin/canccu-old-form"
ln -sfn "$B/current/bin/canccu-up" "$P/bin/canccu-up"
inst "$D" --dev --no-monitor
ok "… a link through the symlinked form: not called foreign" eq "$(grep -c 'kept ' "$E/out")" 0
hrun "$P/bin/canccu-dispatcher" doctor
ok "… nor flagged by doctor" eq "$(grep -c 'links to' "$E/out")" 0
hrun "$P/bin/canccu-dispatcher" uninstall
ok "… uninstall (run from the checkout) removes every link into its tree" eq "$rc $(find "$P/bin" -type l | wc -l) $(test -e "$B" && echo tree)" "0 0 "

# the old install's venv (the same marker, the same default place): never this install's to remove
inst_env uninstall-foreign-venv
mkdir -p "$H/.local/share/canccu/venv/bin"; echo old > "$H/.local/share/canccu/venv/.requirements.sha256"
inst "$T/src0" --no-monitor
hrun "$P/bin/canccu-dispatcher" uninstall
ok "uninstall after a --no-monitor install: a venv it never built stays" eq "$rc $(cat "$H/.local/share/canccu/venv/.requirements.sha256")" "0 old"

inst_env uninstall-none
hrun bash "$T/src0/bin/canccu-dispatcher" uninstall --prefix "$E/nothing"
ok "uninstall where nothing is installed: said, exit 1" eq "$rc $(grep -c 'nothing installed' "$E/out")" "1 1"

echo "canccu-install2 tests: $npass passed, $nfail failed"
(( nfail == 0 ))
