#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/lib/install.sh — the fakes and helpers of the installer's tests (canccu-install*.sh,
# canccu-doctor.sh), sourced after tests/lib/harness.sh. Each test gets a fake HOME and a PATH of
# the fake tools first, then only the system dirs: nothing of the user's own install is seen.
# shellcheck disable=SC2034  # the test files read these

tb=$T/toolbin; mkdir -p "$tb"
SYSPATH="$tb:/usr/local/bin:/usr/bin:/bin"
# the claude flags the run engine passes: the fake claude's --help lists them, less those named
# in $FAKE/claude-drop
# shellcheck source=../../lib/canccu-deps.sh
CLAUDE_FLAGS=$( . "$root/lib/canccu-deps.sh" 2>/dev/null; echo "${CANCCU_CLAUDE_FLAGS:-}")
export CLAUDE_FLAGS
cat > "$tb/claude" <<'EOF'
#!/bin/sh
case $1 in
  --version) echo "2.1.319 (Claude Code)" ;;
  --help) echo "Usage: claude [options] [command] [prompt]"
          for f in $CLAUDE_FLAGS; do grep -qxF -- "$f" "$FAKE/claude-drop" 2>/dev/null || echo "  $f <value>  what it does"; done ;;
esac
EOF
# gh: logged in unless $FAKE/gh-nologin exists
cat > "$tb/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "auth status") [ -e "$FAKE/gh-nologin" ] && { echo "You are not logged into any GitHub hosts." >&2; exit 1; }; echo "Logged in to github.com" ;;
  "--version "*) echo "gh version 2.60.0 (2030-01-01)" ;;
esac
EOF
cat > "$tb/tmux" <<'EOF'
#!/bin/sh
case $1 in -V) echo "tmux ${FAKE_TMUX_V:-3.5a}" ;; *) exit 1 ;; esac
EOF
# uv: records each call; a venv is a dir with bin/python; fails when $FAKE/uv-fail exists, and
# only its pip install when $FAKE/uv-fail-pip does (the venv is made, the packages are not)
cat > "$tb/uv" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE/uv.log"
[ -e "$FAKE/uv-fail" ] && { echo "uv: no network" >&2; exit 1; }
case $1 in
  venv) for d; do :; done; mkdir -p "$d/bin" && printf '#!/bin/sh\n' > "$d/bin/python" && chmod +x "$d/bin/python" ;;
  pip) [ -e "$FAKE/uv-fail-pip" ] && { echo "uv: no network" >&2; exit 1; } ;;
esac
exit 0
EOF
chmod +x "$tb"/*
# tool_fake <name> <version line>: a tool of that version, for one test (in $FAKE/bin, first on
# PATH through IPATH)
tool_fake() {
  mkdir -p "$FAKE/bin"
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$FAKE/bin/$1"; chmod +x "$FAKE/bin/$1"
}

# inst_env <name>: a fake HOME (H) with its prefix (P = ~/.local) and state dir (C = ~/.canccu)
inst_env() {
  tname=$1; E=$T/$1; H=$E/home; P=$H/.local; C=$H/.canccu; FAKE=$E/fake
  B=$P/lib/canccu-dispatcher; R=$B/releases
  mkdir -p "$H" "$FAKE"; : > "$FAKE/uv.log"
  export FAKE
  IPATH="$FAKE/bin:$SYSPATH"
}
# hrun <cmd...>: a command as the fake HOME's user would run it; output to $E/out, exit code in rc
hrun() {
  env -u CANCCU_ROOT -u CANCCU_HOME -u CANCCU_PROJECT -u WORKERS_DIR -u CANCCU_VENV -u CANCCU_HOST_PROFILE \
    HOME="$H" PATH="$IPATH" "$@" > "$E/out" 2>&1
  rc=$?
}
# inst <src dir> [args...]: install.sh of that tree
inst() { local s=$1; shift; hrun bash "$s/install.sh" "$@"; }
out_has() { grep -qF -- "$1" "$E/out" || { echo "    out lacks: $1"; sed 's/^/      | /' "$E/out" | head -20; return 1; }; }
out_hasnt() { ! grep -qF -- "$1" "$E/out" || { echo "    out has: $1"; return 1; }; }
# tree <dir...>: every path with its type, link target, mode and mtime: equal before and after
# means nothing changed
tree() { find "$@" -printf '%p %y %l %m %T@\n' 2>/dev/null | sort; }

# holder <lock> <path>: a process that holds the lock (flock) and runs from the path, the way a
# dispatcher of that release does (its argv names it); its pid in HPID. Not in $(…): the
# holders are stopped from this shell. holder_fd <path>: one that only has the path open, the way
# bash holds the script it runs (fd 255).
HOLDERS=()
holder() {
  ( exec 8>"$1"; flock 8; exec -a "$2" sleep 300 ) >/dev/null 2>&1 &
  HPID=$!; HOLDERS+=("$HPID")
  local i; for i in $(seq 50); do flock -n "$1" true 2>/dev/null || break; sleep 0.1; done
}
holder_fd() { ( exec sleep 300 9<"$1" ) >/dev/null 2>&1 & HOLDERS+=($!); sleep 0.2; }
holders_stop() { local p; for p in "${HOLDERS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; HOLDERS=(); }
trap 'holders_stop; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
