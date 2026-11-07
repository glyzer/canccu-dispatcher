#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-install.sh — install.sh in a fake HOME, offline: the dependency check (--check),
# a fresh install and an idempotent re-install, the links (foreign ones kept or replaced, a
# regular file never), the state dir, the host profile, the monitor venv, --dev (the harness:
# tests/lib/harness.sh and tests/lib/install.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
# shellcheck source=lib/install.sh
. "$(dirname "$0")/lib/install.sh"

S=$T/src; src_copy "$S" 9.9.0
cmds=$(cd "$root/bin" && ls)

# ---------------------------------------------------------------- the dependency check

tname=flags
used=$(grep -E 'args=\(|args\+=\(|sargs=\(' "$root/libexec/canccu-worker" | grep -oE -- '--[a-z][a-z-]+' | sort -u)
missing=$(comm -23 <(echo "$used") <(tr ' ' '\n' <<<"$CLAUDE_FLAGS" | sort -u) | tr '\n' ' ')
ok "the check knows every flag the run engine passes to claude" eq "${missing% }" ""
ok "… and the short ones by their long names (-p, -n)" eq "$(grep -cE -- '(-p|-n) ' <<<"$(grep -E 'args=\(' "$root/libexec/canccu-worker")") $(tr ' ' '\n' <<<"$CLAUDE_FLAGS" | grep -cxE -- '--print|--name')" "1 2"

tested=$( . "$root/lib/canccu-deps.sh"; echo "$CANCCU_CLAUDE_TESTED")
ok "docs/install.md names the tested minimum claude" grep -qF "Claude Code $tested" "$root/docs/install.md"
ok "… and every minimum version the check holds" eq "$(for v in 'bash 5.0' 'git 2.30' 'jq 1.6' 'tmux 3.2' 'python3 3.10'; do grep -qF "$v" "$root/docs/install.md" || echo "$v"; done)" ""

inst_env check-ok
inst "$S" --check
ok "--check: every tool there: exit 0" eq "$rc" 0
ok "… says so" out_has "all dependencies found"
ok "… and installs nothing" eq "$(ls -A "$H" | tr '\n' ' ')" ""

inst_env check-claude-flag
echo --permission-prompts > "$FAKE/claude-drop"
inst "$S" --check
ok "a claude without a flag the engine passes: exit 2" eq "$rc" 2
ok "… names the flag and how to get a newer claude" out_has "claude: its --help lacks --permission-prompts"
ok "… with the tested minimum version" out_has "2.1.319"
inst "$S"
ok "… and an install installs nothing" eq "$rc $(ls -A "$H" | tr '\n' ' ')" "2 "

inst_env check-old
tool_fake git "git version 2.20.1"; tool_fake jq "jq-1.5"; tool_fake python3 "Python 3.9.18"
tool_fake ps "ps from busybox"; touch "$FAKE/gh-nologin"
inst "$S" --check; FAKE_TMUX_V=3.0a hrun bash "$S/install.sh" --check
ok "old and missing tools: exit 2" eq "$rc" 2
ok "… git too old, with how to get it" out_has "git ≥ 2.30 (found 2.20.1)"
ok "… jq too old" out_has "jq ≥ 1.6 (found 1.5)"
ok "… python3 too old" out_has "python3 ≥ 3.10 (found 3.9.18)"
ok "… tmux too old" out_has "tmux ≥ 3.2 (found 3.0a)"
ok "… no procps" out_has "procps"
ok "… gh without a login" out_has "gh: not logged in"
ok "… one line per tool, each with a way to get it" eq "$(grep -c '^  ' "$E/out")" 6

# coreutils by what the tool uses (date -d, stat -c, realpath -m, sort -V), not by its brand:
# a GNU-compatible one (uutils, the default on newer distributions) passes
inst_env check-uutils
mkdir -p "$FAKE/bin"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "date (uutils coreutils) 0.2.2"; exit 0; }\nexec /usr/bin/date "$@"\n' > "$FAKE/bin/date"
chmod +x "$FAKE/bin/date"; inst "$S" --check
ok "a GNU-compatible coreutils that brands itself otherwise: accepted" eq "$rc" 0
inst_env check-no-gnu-date
mkdir -p "$FAKE/bin"
printf '#!/bin/sh\ncase "$*" in *-d*) echo "date: unrecognized option: d" >&2; exit 1 ;; esac\nexec /usr/bin/date "$@"\n' > "$FAKE/bin/date"
chmod +x "$FAKE/bin/date"; inst "$S" --check
ok "a date without -d: refused as no GNU coreutils" eq "$rc $(grep -c 'GNU coreutils' "$E/out")" "2 1"

inst_env check-no-claude
mkdir -p "$E/bin"; for t in "$tb"/*; do [ "${t##*/}" = claude ] || ln -s "$t" "$E/bin/"; done
if PATH=/usr/local/bin:/usr/bin:/bin command -v claude >/dev/null; then
  echo "skip: a claude in the system dirs"
else
  IPATH="$E/bin:/usr/local/bin:/usr/bin:/bin"; hrun bash "$S/install.sh" --check
  ok "no claude at all: exit 2, named" eq "$rc $(grep -c 'claude: not found' "$E/out")" "2 1"
fi

# ---------------------------------------------------------------- a fresh install

inst_env fresh
inst "$S" --no-monitor
ok "a fresh install: exit 0" eq "$rc" 0
ok "… the tree is a release of its version" test -f "$R/9.9.0/bin/canccu-dispatch"
ok "… current points at it" eq "$(readlink "$B/current")" releases/9.9.0
bad=""
for c in $cmds; do [ "$(readlink "$P/bin/$c")" = "$B/current/bin/$c" ] || bad+=" $c"; done
ok "… every command is linked through current" eq "${bad# }" ""
ok "… the linked command runs the release" eq "$(HOME=$H "$P/bin/canccu-dispatcher" --version)" "canccu-dispatcher 9.9.0"
ok "… a missing ~/.canccu/config is written" test -f "$C/config"
ok "… with every default commented out" eq "$(grep -cE '^[[:space:]]*[A-Z_]+=' "$C/config") $(grep -c '^# CAP=3' "$C/config")" "0 1"
ok "… and no project made" not test -e "$C/projects"
ok "… it says what it did" out_has "installed canccu-dispatcher 9.9.0"
before=$(tree "$H")
inst "$S" --no-monitor
ok "a re-install: exit 0" eq "$rc" 0
ok "… changes nothing" eq "$(tree "$H")" "$before"
ok "… and says it is installed already" out_has "9.9.0 is installed already"

inst_env prefix
hrun bash "$S/install.sh" --no-monitor --prefix "$E/opt"
ok "--prefix: the tree and links there" eq "$rc $(readlink "$E/opt/bin/canccu-status")" "0 $E/opt/lib/canccu-dispatcher/current/bin/canccu-status"
ok "… nothing in ~/.local" not test -e "$P"

inst_env root
CANCCU_ROOT=$E/state; export CANCCU_ROOT
HOME=$H PATH=$IPATH bash "$S/install.sh" --no-monitor > "$E/out" 2>&1
unset CANCCU_ROOT
ok "CANCCU_ROOT: the config is written there" eq "$(test -f "$E/state/config" && echo y)$(test -e "$C" && echo n)" y

# ---------------------------------------------------------------- the state dir

inst_env state-kept
mkdir -p "$C/projects/web"; printf 'TOTAL_CAP=4\n' > "$C/config"; printf 'REPO=example-org/web\n' > "$C/projects/web/config"
before=$(tree "$C"); sums=$(cd "$C" && find . -type f -exec md5sum {} + | sort)
inst "$S" --no-monitor
ok "an existing state dir: not changed" eq "$(tree "$C")" "$before"
ok "… not a byte" eq "$(cd "$C" && find . -type f -exec md5sum {} + | sort)" "$sums"

inst_env profile
mkdir -p "$C"; printf '# HOST_PROFILE=\nTOTAL_CAP=4\n' > "$C/config"
chmod 640 "$C/config"
inst "$S" --no-monitor --host-profile max
ok "--host-profile: added to a config that lacks the key" eq "$(grep -c '^HOST_PROFILE=max$' "$C/config") $(head -n2 "$C/config" | tr '\n' ' ')" "1 # HOST_PROFILE= TOTAL_CAP=4 "
ok "… the file keeps its mode" eq "$(stat -c %a "$C/config")" 640
before=$(tree "$C")
inst "$S" --no-monitor --host-profile max
ok "… once" eq "$(tree "$C")" "$before"
printf 'HOST_PROFILE=max\n' > "$C/config"; before=$(tree "$C")
src_copy "$E/s2" 9.9.1; printf '# shellcheck shell=bash\n' > "$E/s2/hosts/lab.conf"
inst "$E/s2" --no-monitor --host-profile lab
ok "a config that sets another profile: kept, said" eq "$(tree "$C")$(grep -c 'keeps HOST_PROFILE=max' "$E/out")" "${before}1"
printf 'HOST_PROFILE="max"   # this host\n' > "$C/config"; before=$(tree "$C")
inst "$S" --no-monitor --host-profile max
ok "a quoted, commented HOST_PROFILE of the same profile: the same, nothing said" eq "$(tree "$C")$(grep -c 'keeps HOST_PROFILE' "$E/out")" "${before}0"
inst_env profile-fresh
inst "$S" --no-monitor --host-profile max
ok "--host-profile on a fresh host: the written config sets it" eq "$(grep -cE '^[[:space:]]*[A-Z_]+=' "$C/config") $(grep -c '^HOST_PROFILE=max$' "$C/config")" "1 1"
inst_env profile-unknown
inst "$S" --no-monitor --host-profile nosuch
ok "an unknown --host-profile: refused with the list, exit 2" eq "$rc $(grep -c "no host profile 'nosuch'.*max" "$E/out")" "2 1"
ok "… nothing installed" eq "$(ls -A "$H" | tr '\n' ' ')" ""

# ---------------------------------------------------------------- the links

inst_env links
mkdir -p "$P/bin" "$E/old/bin"; for c in canccu-status canccu-up; do printf '#!/bin/sh\n' > "$E/old/bin/$c"; ln -s "$E/old/bin/$c" "$P/bin/$c"; done
printf '#!/bin/sh\necho mine\n' > "$P/bin/canccu-stop"; chmod +x "$P/bin/canccu-stop"
ln -s "$E/old/bin/other" "$P/bin/other"
inst "$S" --no-monitor
ok "a foreign canccu-* link: kept" eq "$(readlink "$P/bin/canccu-status")" "$E/old/bin/canccu-status"
ok "… and named, with the way to replace it" out_has "kept ~/.local/bin/canccu-status → $E/old/bin/canccu-status"
ok "… --replace-links named" out_has "--replace-links"
ok "a regular file of a command's name: never replaced" eq "$("$P/bin/canccu-stop")" mine
ok "… and named" out_has "kept ~/.local/bin/canccu-stop: a file, not a link"
ok "… the other commands are linked" eq "$(readlink "$P/bin/canccu-pause")" "$B/current/bin/canccu-pause"
ok "… the install still succeeds" eq "$rc" 0
inst "$S" --no-monitor --replace-links
ok "--replace-links: the foreign links replaced" eq "$(readlink "$P/bin/canccu-status") $(readlink "$P/bin/canccu-up")" \
  "$B/current/bin/canccu-status $B/current/bin/canccu-up"
ok "… still never the file" eq "$("$P/bin/canccu-stop")" mine
ok "… nor a link that is not canccu-*" eq "$(readlink "$P/bin/other")" "$E/old/bin/other"

# ---------------------------------------------------------------- the monitor venv

inst_env venv
V=$H/.local/share/canccu/venv
inst "$S"
ok "the venv: built with uv from the pinned requirements" eq "$(grep -c "pip install .*-r $R/9.9.0/lib/canccu-monitor.requirements.txt" "$FAKE/uv.log")" 1
ok "… in the default place, marked with the requirements' hash" eq "$(cat "$V/.requirements.sha256")" "$(sha256sum < "$S/lib/canccu-monitor.requirements.txt" | cut -d' ' -f1)"
: > "$FAKE/uv.log"; inst "$S"
ok "… not rebuilt while the requirements are the same" eq "$(wc -l < "$FAKE/uv.log")" 0
src_copy "$E/s2" 9.9.1; echo "# changed" >> "$E/s2/lib/canccu-monitor.requirements.txt"
inst "$E/s2"
ok "… rebuilt when they change" eq "$(grep -c 'pip install' "$FAKE/uv.log")" 1
inst_env venv-fail
touch "$FAKE/uv-fail"; inst "$S"
ok "a failed venv build: a warning" out_has "could not build the monitor's venv"
ok "… the rest is installed, exit 0" eq "$rc $(readlink "$B/current")" "0 releases/9.9.0"
ok "… no marker: the next install tries again" not test -e "$H/.local/share/canccu/venv/.requirements.sha256"
inst_env venv-dir
inst "$S" --venv "$E/v"
ok "--venv DIR: built there" test -f "$E/v/.requirements.sha256"
inst_env venv-env
CANCCU_VENV=$E/v2; export CANCCU_VENV; HOME=$H PATH=$IPATH bash "$S/install.sh" > "$E/out" 2>&1; unset CANCCU_VENV
ok "CANCCU_VENV: built there" test -f "$E/v2/.requirements.sha256"
inst_env no-monitor
inst "$S" --no-monitor
ok "--no-monitor: no venv" eq "$(wc -l < "$FAKE/uv.log") $(test -e "$H/.local/share/canccu" && echo there)" "0 "

# ---------------------------------------------------------------- --dev

inst_env dev
D=$E/checkout; src_copy "$D" 9.9.0
(cd "$D" && git init -q && git -c user.name=octo -c user.email=octo@users.noreply.github.com add -A &&
  git -c user.name=octo -c user.email=octo@users.noreply.github.com commit -qm one) >/dev/null 2>&1
inst "$D" --dev --no-monitor
ok "--dev: current is the checkout itself" eq "$rc $(readlink "$B/current")" "0 $D"
ok "… no release copied" not test -e "$R/9.9.0"
ok "… it warns that live projects must not run on it" out_has "live projects must not run on it"
ok "… the commands run the checkout" grep -q "^canccu-dispatcher 9.9.0 (commit " <<<"$(HOME=$H "$P/bin/canccu-dispatcher" --version)"
inst "$D" --no-monitor
ok "a release from a checkout is named by its commit" eq "$(readlink "$B/current")" "releases/9.9.0+$(git -C "$D" rev-parse --short HEAD)"
c=$(git -C "$D" rev-parse --short HEAD)
echo stray > "$D/notes.txt"; inst "$D" --no-monitor
ok "… an untracked file does not make it dirty, nor ship" eq "$(readlink "$B/current") $(test -e "$R/9.9.0+$c/notes.txt" && echo shipped)" "releases/9.9.0+$c "
echo "# edited" >> "$D/README.md"; inst "$D" --no-monitor
d1=$(readlink "$B/current")
ok "uncommitted changes: a release named by its content" grep -qE "^releases/9\.9\.0\+$c\.dirty\.[0-9a-f]{8}$" <<<"$d1"
echo "# again" >> "$D/README.md"; inst "$D" --no-monitor
ok "… another edit: another release, the first one kept as it was" \
  eq "$(test "$(readlink "$B/current")" != "$d1" && echo new) $(grep -c '# again' "$B/${d1}/README.md")" "new 0"
inst_env replace-current
inst "$S" --no-monitor
echo "# changed" >> "$S/README.md"; inst "$S" --no-monitor
ok "the same version with other files while it is current: refused" eq "$rc $(grep -c changed "$R/9.9.0/README.md")" "1 0"
ok "… it says to give the tree a new VERSION" out_has "new VERSION"
src_copy "$S" 9.9.0
inst_env dev-tarball
inst "$S" --dev --no-monitor
ok "--dev from a tarball: refused, exit 2" eq "$rc $(grep -c 'needs a git checkout' "$E/out")" "2 1"

# ---------------------------------------------------------------- usage

inst_env usage
inst "$S" --frobnicate
ok "an unknown option: the usage, exit 2" eq "$rc $(grep -c 'install.sh \[--prefix DIR\]' "$E/out")" "2 1"

echo "canccu-install tests: $npass passed, $nfail failed"
(( nfail == 0 ))
