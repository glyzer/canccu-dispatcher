#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-repo.sh — the repo's own rules: licence headers, the file-size rule and the layout
# (the workflows: tests/canccu-ci.sh; the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
cd "$root" || exit 1
tname=repo

# the tracked and new files of the working tree, as the leak check sees them
files=$(git ls-files -co --exclude-standard | sort)
kind() {   # kind <file>: shell, python, yaml, markdown or other
  case $1 in
    *.py) echo python ;; *.yml|*.yaml) echo yaml ;; *.md) echo markdown ;; *.sh) echo shell ;;
    *.json|*.txt|*.jq|LICENSE|REUSE.toml|VERSION|.file-size-exemptions|.gitignore) echo other ;;
    *) if head -n2 "$1" | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)|^# shellcheck shell='; then echo shell; else echo other; fi ;;
  esac
}

# ---------------------------------------------------------------- licence headers

# the review-gate templates, and this repo's copies of them, are 0BSD (templates/LICENSE): a
# target repo copies them without taking on the AGPL
zero_bsd() { case $1 in templates/repo/*|.github/workflows/review-gate.yml|.github/scripts/review-gate) return 0 ;; esac; return 1; }
missing=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case $(kind "$f") in
    # line 1, or line 2 after a shebang; an issue template's front matter must come first, so
    # there the line after it
    shell|python|yaml|markdown)
      n=1; head -n1 "$f" | grep -q '^#!' && n=2
      [[ $f == .github/ISSUE_TEMPLATE/*.md ]] && n=$(( $(sed -n '2,$p' "$f" | grep -n -m1 '^---$' | cut -d: -f1) + 2 ))
      lic=AGPL-3.0-or-later; zero_bsd "$f" && lic=0BSD
      sed -n "${n}p" "$f" | grep -q "SPDX-License-Identifier: $lic" || missing+=" $f" ;;
  esac
done <<<"$files"
ok "every shell, Python, YAML and Markdown source starts with its SPDX line (0BSD: the templates)" eq "${missing# }" ""
ok "REUSE.toml covers the JSON fixtures and the monitor's requirements" \
  eq "$(grep -oE 'tests/fixtures/\*\*/\*\.json|lib/canccu-monitor\.requirements\.txt' REUSE.toml 2>/dev/null | wc -l)" 2
ok "… and VERSION" grep -q '"VERSION"' REUSE.toml
ok "… with the licence" grep -q 'SPDX-License-Identifier = "AGPL-3.0-or-later"' REUSE.toml
ok "the JSON fixtures carry no header" not grep -lq SPDX tests/fixtures/monitor/*.json tests/fixtures/plans/*.json
ok "README.md says the tool is pre-release" grep -qi 'pre-release' README.md

# ---------------------------------------------------------------- the file-size rule

over=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case $f in tests/*|docs/*|*/fixtures/*|LICENSE) continue ;; esac
  [ "$(kind "$f")" = other ] && [[ $f != *.jq ]] && continue
  (( $(wc -l < "$f") > 400 )) || continue
  grep -qE "^$f — .+" .file-size-exemptions 2>/dev/null || over+=" $f"
done <<<"$files"
ok "every source file over 400 lines is listed with a reason in .file-size-exemptions" eq "${over# }" ""
stale=""
while IFS= read -r l; do
  [[ $l =~ ^([^[:space:]]+)\ —\ .+ ]] || { [[ -z $l || $l == \#* ]] && continue; stale+=" (bad line: $l)"; continue; }
  f=${BASH_REMATCH[1]}
  [ -f "$f" ] && (( $(wc -l < "$f") > 400 )) || stale+=" $f"
done < .file-size-exemptions
ok "… and lists nothing else" eq "${stale# }" ""

# ---------------------------------------------------------------- the layout

ok "bin/: the 13 commands" eq "$(cd bin && ls | tr '\n' ' ')" \
  "canccu-classify canccu-dispatch canccu-dispatcher canccu-init canccu-monitor canccu-pause canccu-resume canccu-review canccu-run canccu-ship canccu-status canccu-stop canccu-up "
ok "libexec/: the run engine and its nudge hook" eq "$(cd libexec && ls | tr '\n' ' ')" "canccu-nudge-hook canccu-worker "
ok "every command and the engine find their libs from their real path" \
  eq "$(grep -L 'realpath' bin/* libexec/canccu-worker | tr '\n' ' ')" ""
mkdir -p "$T/links"; ln -s "$root/bin/canccu-status" "$T/links/canccu-status"
ok "… so a symlink to a command works" grep -q "no project in" <<<"$(env -u CANCCU_PROJECT CANCCU_ROOT="$T/none" "$T/links/canccu-status" 2>&1)"

echo "canccu-repo tests: $npass passed, $nfail failed"
(( nfail == 0 ))
