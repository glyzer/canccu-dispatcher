#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-docs.sh — the docs keep up with the code: every config key in the configuration
# reference, every section the code cites, small indexed reference topics, links that resolve,
# and the repo-contract snippets the prompts rely on (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
cd "$root" || exit 1
tname=docs

R=docs/reference
# the configuration reference is two topics: config (the defaults and the host profiles) and rules
cfgref="$R/config.md $R/rules.md"
# keys <file...>: the KEY of each KEY=value line, commented out (the templates) or not
keys() { sed -nE 's/^(# )?([A-Z][A-Z0-9_]*)=.*/\2/p' "$@" 2>/dev/null | sort -u; }
# documented: the key of each table row "| `KEY` | …" of the configuration reference
# shellcheck disable=SC2086  # two files
documented=$(sed -nE 's/^\| `([A-Z][A-Z0-9_]*)` \|.*/\1/p' $cfgref 2>/dev/null | sort -u)

# ---------------------------------------------------------------- the configuration reference

missing=$(comm -23 <(keys lib/canccu-config.default) <(echo "$documented"))
ok "every key of lib/canccu-config.default has its row in the configuration reference" eq "$(echo $missing)" ""
missing=$(comm -23 <(keys hosts/*.conf) <(echo "$documented"))
ok "… every key of the host profiles too" eq "$(echo $missing)" ""
missing=$(comm -23 <(keys profiles/*/config profiles/*/rules) <(echo "$documented"))
ok "… and every key of the project templates" eq "$(echo $missing)" ""
stale=$(comm -13 <(keys lib/canccu-config.default) <(echo "$documented"))
ok "the reference documents no key the defaults do not have" eq "$(echo $stale)" ""
ok "the reference gives CAP's default" grep -qE '^\| `CAP` \| `3` \|' "$R/config.md"

# ---------------------------------------------------------------- the sections the code cites

# the code's comments cite 'docs/canccu-dispatch.md, "<section>"' (and '… and "<section>"'),
# sometimes across a line break
cited=$(for f in bin/* libexec/* lib/* profiles/*/* hosts/*; do
          [ -f "$f" ] && sed -E 's/^[[:space:]#]*//' "$f" | tr '\n' ' '
        done | grep -oE 'docs/canccu-dispatch\.md, "[^"]+"( and "[^"]+")?' | grep -oE '"[^"]+"' | tr -d '"' | sort -u)
ok "the code cites sections (a sanity check of the grep)" test "$(grep -c . <<<"$cited")" -ge 10
ok "docs/canccu-dispatch.md exists and points at the reference" grep -qF 'reference/README.md' docs/canccu-dispatch.md
nohead="" nomap=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  grep -qxE "#{2,4} $s" "$R"/*.md 2>/dev/null || nohead+=" \"$s\""
  grep -qF "| $s |" "$R/README.md" 2>/dev/null || nomap+=" \"$s\""
done <<<"$cited"
ok "every section the code cites is a heading of a reference topic" eq "${nohead# }" ""
ok "… and the index maps it to its topic" eq "${nomap# }" ""

# ---------------------------------------------------------------- the reference topics

topics=$(cd "$R" 2>/dev/null && ls ./*.md 2>/dev/null | sed 's|^\./||' | grep -vx README.md)
ok "the reference is split into topics" test "$(grep -c . <<<"$topics")" -ge 10
big="" unlisted=""
for t in $topics; do
  (( $(wc -c < "$R/$t") < 15000 )) || big+=" $t"
  grep -qF "]($t)" "$R/README.md" || unlisted+=" $t"
done
ok "each reference topic stays under 15 KB" eq "${big# }" ""
ok "the reference index lists every topic" eq "${unlisted# }" ""
unlisted=""
for d in docs/*.md; do
  [ "$d" = docs/README.md ] && continue
  grep -qF "](${d#docs/})" docs/README.md 2>/dev/null || unlisted+=" $d"
done
ok "docs/README.md lists every guide" eq "${unlisted# }" ""
ok "… and the reference index" grep -qF '](reference/README.md)' docs/README.md
ok "AGENTS.md tells a change to read and update only its reference topic" grep -qF 'docs/reference/' AGENTS.md

# ---------------------------------------------------------------- links

# slug <heading>: GitHub's anchor of a heading
slug() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'; }
broken=""
for f in README.md CONTRIBUTING.md SECURITY.md CHANGELOG.md docs/*.md "$R"/*.md templates/*.md templates/repo/*.md; do
  [ -f "$f" ] || continue
  while IFS= read -r l; do
    case $l in http*|mailto:*) continue ;; esac
    p=${l%%#*} a=""; [[ $l == *#* ]] && a=${l#*#}
    if [ -n "$p" ]; then t=$(realpath -m "$(dirname "$f")/$p"); else t=$root/$f; fi
    [ -e "$t" ] || { broken+=" $f→$l"; continue; }
    [ -n "$a" ] || continue
    found=0
    while IFS= read -r h; do [ "$(slug "$h")" = "$a" ] && { found=1; break; }; done \
      < <(sed -nE 's/^#+ (.*)/\1/p' "$t")
    (( found )) || broken+=" $f→$l"
  done < <(grep -oE '\]\([^) ]+\)' "$f" | sed -E 's/^\]\((.*)\)$/\1/')
done
ok "every relative link in the docs resolves, anchors included" eq "${broken# }" ""

# ---------------------------------------------------------------- the README

# shellcheck disable=SC2088  # the literal text the README names
for w in install.sh canccu-init canccu-up uninstall REVIEWER_LOGIN templates/repo/ gh git jq tmux bash python3 \
         "$(sed -n 's/^CANCCU_CLAUDE_TESTED=//p' lib/canccu-deps.sh)" ruleset collaborator '~/.canccu'; do
  ok "README.md names $w" grep -qF -- "$w" README.md
done
ok "the CHANGELOG lists the docs" grep -qF 'docs/' CHANGELOG.md
for w in tests/run 'Acceptance criteria' 'Out of scope' 'Risk:' 'type(scope)' 'run by canccu-dispatcher'; do
  ok "CONTRIBUTING.md covers $w" grep -qF -- "$w" CONTRIBUTING.md
done
ok "SECURITY.md says how to report a problem" grep -qi 'report' SECURITY.md

# ---------------------------------------------------------------- the repo-contract snippets

S=templates/repo
ok "no template is named CLAUDE.md or AGENTS.md (no session here loads it)" \
  eq "$(find templates -name CLAUDE.md -o -name AGENTS.md)" ""
ok "the CLAUDE.md snippet holds the <n> / execute / finish flow the worker prompt names" \
  eq "$(grep -cE '^#+ `(<n>|execute|finish)`' "$S/CLAUDE.snippet.md" 2>/dev/null)" 3
ok "… the plan file" grep -qF 'docs/plans/issue-<n>.md' "$S/CLAUDE.snippet.md"
ok "… and the question line" grep -qF '`Question:' "$S/CLAUDE.snippet.md"
ok "the AGENTS.md snippet holds the comment and file-size rules the health pass names" \
  eq "$(grep -cE '^## (Comment rule|File-size rule)$' "$S/AGENTS.snippet.md" 2>/dev/null)" 2
miss=""
for w in 'Closes #' 'Package:' 'Risk:' 'Tier:' 'Decisions made:' 'Follow-up:' 'Roadmap note:' 'git merge origin/main'; do
  grep -qF -- "$w" "$S/AGENTS.snippet.md" 2>/dev/null || miss+=" '$w'"
done
ok "… and the PR body lines the prompts and the classifier read" eq "${miss# }" ""
ok "docs explain how to merge the snippets into a repo's own files" grep -qF 'CLAUDE.snippet.md' docs/repo-contract.md

echo "canccu-docs tests: $npass passed, $nfail failed"
(( nfail == 0 ))
