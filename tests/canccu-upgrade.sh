#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-upgrade.sh — offline tests for the upgrade between passes (lib/canccu-upgrade.sh,
# #20): the loop runs release 0.1 while `current` points at 0.2. Idle, it runs 0.2 in its place;
# while a run is live it starts nothing new and waits; UPGRADE=manual only says so (the harness:
# tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

REAL_SLEEP=$(command -v sleep)
# install: $E/base/releases/0.1 a copy of this tree, releases/0.2 a stub canccu-dispatch that
# records how it was run (its arguments, the project, the re-exec mark, and whether fd 8 is still
# the dispatch lock, held), and current -> releases/0.2
install() {
  B=$E/base; src_copy "$B/releases/0.1" 0.1
  mkdir -p "$B/releases/0.2/bin"; echo 0.2 > "$B/releases/0.2/VERSION"
  cat > "$B/releases/0.2/bin/canccu-dispatch" <<EOF
#!/usr/bin/env bash
{ echo "args: \$*"; echo "project: \$CANCCU_PROJECT"; echo "reexec: \${CANCCU_REEXEC:-}"; echo "pid: \$\$"
  [ /proc/\$\$/fd/8 -ef "\$CANCCU_HOME/.dispatch.lock" ] && echo "fd8: the lock"
  flock -n 9 9>"\$CANCCU_HOME/.dispatch.lock" || echo "lock: held"; } > "$E/reexec"
EOF
  chmod +x "$B/releases/0.2/bin/canccu-dispatch"; ln -s releases/0.2 "$B/current"
}
# loop <sleep body>: release 0.1's loop; its sleep between passes runs the body (a TERM to the
# dispatcher stops it: a clean stop)
loop() {
  mkdir -p "$E/sb"
  printf '#!/bin/sh\n[ "$1" = 60 ] || exec %s "$@"\n%s\n' "$REAL_SLEEP" "$1" > "$E/sb/sleep"; chmod +x "$E/sb/sleep"
  ( PATH="$E/sb:$fb:$PATH" CANCCU_WORKER="$fb/worker" timeout 60 "$B/releases/0.1/bin/canccu-dispatch" > "$E/out" 2>&1 ) 2>/dev/null
}
dlog() { grep -cF -- "$1" "$CANCCU_HOME/dispatch.log"; }
STOP='kill -TERM "$PPID"'

# ---------------------------------------------------------------- idle: the new release runs

env_new upgrade-idle; install
issue 5 ready | issues
loop "$STOP"
ok "idle: the loop runs current's canccu-dispatch, for the same project" has ../reexec "args: --project web"
ok "… marked as a re-exec" has ../reexec "reexec: 1"
ok "… in the same process (the same pane), on the dispatch lock it holds" has ../reexec "fd8: the lock"
ok "… the lock still held" has ../reexec "lock: held"
ok "… the pending upgrade is logged" eq "$(dlog 'upgrade to 0.2 pending')" 1
ok "… nothing new started first" not started 5

# ---------------------------------------------------------------- a live run: wait

env_new upgrade-wait; install
issue 5 ready | issues
live_lock 7
# the first sleep ends the run; the second pass ends with the dispatcher's re-exec
loop "rm -f '$WORKERS_DIR/web-7.lock'"
ok "wait: a live run holds the upgrade; the pass starts nothing new" not started 5
ok "… it is logged once" eq "$(dlog 'upgrade to 0.2 pending')" 1
ok "… the snapshot of that pass shows it" eq "$(jq -r .pass.upgrade "$CANCCU_HOME/status.json")" 0.2
ok "… once the run ended, the new release runs" has ../reexec "reexec: 1"

# ---------------------------------------------------------------- UPGRADE=manual

env_new upgrade-manual "UPGRADE=manual"; install
issue 5 ready | issues
loop "n=\$(cat '$E/n' 2>/dev/null); echo \$((n + 1)) > '$E/n'; [ \"\$n\" = 1 ] && $STOP"
ok "manual: the new release never runs" not test -e "$E/reexec"
ok "… the pending upgrade is logged once over two passes" eq "$(dlog 'upgrade to 0.2 pending')" 1
ok "… and work goes on" started 5
ok "… the snapshot shows it" eq "$(jq -r .pass.upgrade "$CANCCU_HOME/status.json")" 0.2
st=$(PATH="$fb:$PATH" "$B/releases/0.1/bin/canccu-status" 2>&1)
ok "… and canccu-status (the stopped dispatcher's file is gone: none)" not grep -qF "upgrade to" <<<"$st"
echo 0.2 > "$CANCCU_HOME/upgrade"
st=$(PATH="$fb:$PATH" "$B/releases/0.1/bin/canccu-status" 2>&1)
ok "… canccu-status shows a pending upgrade" grep -qF "upgrade to 0.2 pending" <<<"$st"

# ---------------------------------------------------------------- no upgrade

env_new upgrade-none; install; ln -sfn releases/0.1 "$B/current"
issue 5 ready | issues
loop "$STOP"
ok "none: current is this release: no re-exec" not test -e "$E/reexec"
ok "… work goes on, nothing logged" eq "$(started 5 && echo yes) $(dlog 'upgrade to')" "yes 0"
ok "… the snapshot has none" eq "$(jq -r .pass.upgrade "$CANCCU_HOME/status.json")" null

echo "canccu-upgrade tests: $npass passed, $nfail failed"
(( nfail == 0 ))
