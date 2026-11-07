#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-version.sh — the installed version shown everywhere: VERSION and CHANGELOG.md,
# canccu-dispatcher --version (with the commit from a checkout), canccu-status's first line and
# the snapshot's version field (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

tname=files
V=$(tr -d '[:space:]' < "$root/VERSION" 2>/dev/null)
ok "VERSION holds one semantic version" grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$V"
ok "CHANGELOG.md has a section for it" grep -qE "^## \[?$V\]?" "$root/CHANGELOG.md"

# ---------------------------------------------------------------- --version

tname=version-tarball
# a copy without .git stands for a release tarball: the version only
S=$T/src; src_copy "$S" 9.8.7
out=$("$S/bin/canccu-dispatcher" --version 2>&1); rc=$?
ok "from a tarball: the version, nothing else" eq "$rc $out" "0 canccu-dispatcher 9.8.7"

tname=version-checkout
(cd "$S" && git init -q && git -c user.name=octo -c user.email=octo@example.com add -A &&
  git -c user.name=octo -c user.email=octo@example.com commit -qm one) >/dev/null 2>&1
c=$(git -C "$S" rev-parse --short HEAD)
out=$("$S/bin/canccu-dispatcher" --version 2>&1)
ok "from a checkout: the version and the commit" eq "$out" "canccu-dispatcher 9.8.7 (commit $c)"
echo x >> "$S/README.md"
out=$("$S/bin/canccu-dispatcher" --version 2>&1)
ok "… marked dirty with uncommitted changes" eq "$out" "canccu-dispatcher 9.8.7 (commit $c, dirty)"
mkdir -p "$T/links"; ln -s "$S/bin/canccu-dispatcher" "$T/links/canccu-dispatcher"
ok "… also through a link" eq "$("$T/links/canccu-dispatcher" --version 2>&1)" "canccu-dispatcher 9.8.7 (commit $c, dirty)"
out=$("$S/bin/canccu-dispatcher" 2>&1); rc=$?
ok "no subcommand: the usage, exit 2" eq "$rc $(grep -c 'canccu-dispatcher --version' <<<"$out")" "2 1"
out=$("$S/bin/canccu-dispatcher" frobnicate 2>&1); rc=$?
ok "an unknown subcommand: named, exit 2" eq "$rc $(grep -c 'frobnicate' <<<"$out")" "2 1"

# ---------------------------------------------------------------- status and the snapshot

env_new status
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)
ok "canccu-status: the version starts its first line" eq "$(head -n1 <<<"$out")" \
  "canccu-dispatcher $V · example-org/web · running · canccu-dispatch is NOT running (canccu-up, or run it in the window dispatch)"

env_new snapshot
dispatch --once
ok "the snapshot has the version" eq "$(jq -r .version "$CANCCU_HOME/status.json")" "$V"
ok "… its schema number is unchanged" eq "$(jq -r .schema "$CANCCU_HOME/status.json")" 2

echo "canccu-version tests: $npass passed, $nfail failed"
(( nfail == 0 ))
