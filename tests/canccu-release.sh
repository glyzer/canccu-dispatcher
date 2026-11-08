#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-release.sh — the release scripts of CI and release.yml: the tag check, the notes,
# the tarball with its SHA256SUMS, and the tarball's install smoke test (the harness:
# tests/lib/harness.sh). Each runs on a throwaway git repo of the working tree, the way
# release.yml runs on a tag's checkout.
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
REL=$root/.github/scripts/release SMOKE=$root/.github/scripts/release-smoke
tname=release

# repo_of <dir> [version]: the working tree as a git repo of one commit (git archive reads commits)
repo_of() {
  src_copy "$1" "${2:-}"
  git -C "$1" init -q && git -C "$1" add -A &&
    git -C "$1" -c user.name=octo -c user.email=octo@users.noreply.github.com commit -qm release
}
# changelog <dir> <heading line>: a CHANGELOG.md with that section and an older one below it
changelog() {
  printf '%s\n' '<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->' '# Changelog' '' "$2" '' \
    '- the new thing' '- and another' '' '## [0.0.1] — 2030-01-01' '' '- the old thing' > "$1/CHANGELOG.md"
}
rel() { (cd "$1" && shift && "$REL" "$@") > "$T/out" 2>&1; rc=$?; }

# ---------------------------------------------------------------- check: VERSION and CHANGELOG.md match the tag

mkdir -p "$T/chk"; echo 1.2.3 > "$T/chk/VERSION"
changelog "$T/chk" '## [1.2.3] — 2030-11-05'
rel "$T/chk" check v1.2.3
ok "check: VERSION and a dated changelog section of the tag: ok" eq "$rc" 0
rel "$T/chk" check v1.2.4
ok "check: VERSION is not the tag's: fails" eq "$rc $(grep -c 'VERSION' "$T/out")" "1 1"
rel "$T/chk" check 1.2.3
ok "check: a tag without the v: fails" eq "$rc" 1
echo 1.2.4 > "$T/chk/VERSION"; rel "$T/chk" check v1.2.4
ok "check: no changelog section for the version: fails" eq "$rc $(grep -c 'CHANGELOG.md' "$T/out")" "1 1"
changelog "$T/chk" '## [1.2.4] — unreleased'; rel "$T/chk" check v1.2.4
ok "check: a section still marked unreleased: fails" eq "$rc $(grep -c 'unreleased' "$T/out")" "1 1"
changelog "$T/chk" '## [1.2.40] — 2030-11-05'; rel "$T/chk" check v1.2.4
ok "check: the section of 1.2.40 is not the one of 1.2.4" eq "$rc" 1
rel "$T/chk" check
ok "check: no tag: a usage error" eq "$rc" 2

# ---------------------------------------------------------------- notes: the section's body

changelog "$T/chk" '## [1.2.4] — 2030-11-05'
rel "$T/chk" notes 1.2.4
ok "notes: the section's body, without its heading or the older section" \
  eq "$(cat "$T/out")" "- the new thing"$'\n'"- and another"
rel "$T/chk" notes 9.9.9
ok "notes: no such section: fails" eq "$rc" 1

# ---------------------------------------------------------------- build: git archive and SHA256SUMS

repo_of "$T/repo" 9.9.0
rel "$T/repo" build 9.9.0 "$T/dist"
ok "build: exit 0" eq "$rc" 0
ok "build: the tarball and SHA256SUMS, nothing else" eq "$(cd "$T/dist" 2>/dev/null && ls | tr '\n' ' ')" \
  "SHA256SUMS canccu-dispatcher-9.9.0.tar.gz "
ok "build: SHA256SUMS verifies the tarball" eval '(cd "$T/dist" && sha256sum -c --quiet SHA256SUMS)'
ok "build: every file sits under canccu-dispatcher-9.9.0/" \
  eq "$(tar -tzf "$T/dist/canccu-dispatcher-9.9.0.tar.gz" | grep -cv '^canccu-dispatcher-9\.9\.0/')" 0
ok "build: the committed tree, the installer included" \
  eq "$(tar -tzf "$T/dist/canccu-dispatcher-9.9.0.tar.gz" | grep -cxE 'canccu-dispatcher-9\.9\.0/(install\.sh|VERSION|bin/canccu-dispatcher)')" 3
echo stray > "$T/repo/stray-file"; rel "$T/repo" build 9.9.0 "$T/dist2"
ok "build: a file never committed never ships" \
  eq "$(tar -tzf "$T/dist2/canccu-dispatcher-9.9.0.tar.gz" | grep -c stray-file)" 0
rel "$T/repo" build 9.9.1 "$T/dist3"
ok "build: a version that is not VERSION's: fails, builds nothing" eq "$rc $(ls "$T/dist3" 2>/dev/null | wc -l)" "1 0"

# ---------------------------------------------------------------- smoke: the tarball installs, runs and goes

mkdir -p "$T/tmp"
smoke() { TMPDIR=$T/tmp "$SMOKE" "$1" > "$T/out" 2>&1; rc=$?; }
smoke "$T/dist/canccu-dispatcher-9.9.0.tar.gz"
ok "smoke: a good tarball passes" eq "$rc" 0
[ "$rc" = 0 ] || sed 's/^/      | /' "$T/out" | tail -20
for step in 'install.sh --check' 'canccu-dispatcher 9.9.0' 'doctor: no problems found' 'uninstall: nothing left'; do
  ok "smoke: it reports $step" grep -qF "$step" "$T/out"
done
ok "smoke: the temp prefix and HOME are cleaned up" eq "$(ls -A "$T/tmp")" ""

# a tarball whose uninstall leaves a file behind, and one that does not run at all
mkdir -p "$T/bad"; tar -xzf "$T/dist/canccu-dispatcher-9.9.0.tar.gz" -C "$T/bad"
b=$T/bad/canccu-dispatcher-9.9.0
cp -a "$b" "$T/bad/keep"
sed -i 's|^\(canccu_link "$prefix".*\)$|\1; : > "$prefix/bin/left-behind"|' "$b/install.sh"
tar -czf "$T/bad/leaves.tar.gz" -C "$T/bad" canccu-dispatcher-9.9.0
smoke "$T/bad/leaves.tar.gz"
ok "smoke: an uninstall that leaves a file behind fails, naming it" eq "$rc $(grep -c 'left-behind' "$T/out")" "1 1"
rm -rf "$b"; mv "$T/bad/keep" "$b"; rm "$b/bin/canccu-dispatcher"
tar -czf "$T/bad/broken.tar.gz" -C "$T/bad" canccu-dispatcher-9.9.0
smoke "$T/bad/broken.tar.gz"
ok "smoke: a tarball without canccu-dispatcher fails" eq "$rc" 1
smoke "$T/none.tar.gz"
ok "smoke: no tarball: a usage error" eq "$rc" 2

echo "canccu-release tests: $npass passed, $nfail failed"
(( nfail == 0 ))
