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
# the configuration reference is five topics: config (the defaults and the host profiles), its
# parts config-steps (steps, packages, reviews, usage) and config-runs (CI, release-reds, the
# narrow runs' models), rules, and notify's table of when Telegram sends
cfgref="$R/config.md $R/config-steps.md $R/config-runs.md $R/rules.md $R/notify.md"
# keys <file...>: the KEY of each KEY=value line, commented out (the templates) or not
keys() { sed -nE 's/^(# )?([A-Z][A-Z0-9_]*)=.*/\2/p' "$@" 2>/dev/null | sort -u; }
# documented: the key of each table row "| `KEY` | …" of the configuration reference
# shellcheck disable=SC2086  # several files
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
# code_default <KEY>: its value in lib/canccu-config.default, unquoted, $CANCCU_ROOT shown as ~/.canccu
code_default() {
  sed -nE "s/^$1=//p" lib/canccu-config.default | sed -E "s/[[:space:]]+#.*//; s/^[\"']//; s/[\"']\$//" |
    sed "s|^\\\$CANCCU_ROOT|~/.canccu|"
}
# a row's default is compared when it is one value in backticks, or empty/none; a default given in
# words (the path patterns) is not
wrong="" compared=0
# shellcheck disable=SC2086  # several files
while IFS='|' read -r _ k d _; do
  k=${k//[\` ]/} d=$(sed -E 's/^ +| +$//g' <<<"$d")
  case $d in empty|none) want="" ;; \`*\`) [[ $d == *\`*\`*\`* ]] && continue; want=${d:1:-1} ;; *) continue ;; esac
  compared=$((compared + 1))
  [ "$(code_default "$k")" = "$want" ] || wrong+=" $k (docs: '$want', code: '$(code_default "$k")')"
done < <(grep -hE '^\| `[A-Z][A-Z0-9_]*` \|' $cfgref 2>/dev/null)
ok "each documented default is the code's" eq "${wrong# }" ""
ok "… and most defaults are compared (a sanity check of the parse)" test "$compared" -ge 40

# ---------------------------------------------------------------- the sections the code cites

# the code's comments cite 'docs/canccu-dispatch.md, "<section>"' (and '… and "<section>"'),
# sometimes across a line break
cited=$(for f in $(git ls-files -co --exclude-standard bin libexec lib profiles hosts install.sh); do
          [ -f "$f" ] && sed -E 's/^[[:space:]#]*//' "$f" | tr '\n' ' '
        done | grep -oE 'docs/canccu-dispatch\.md, "[^"]+"( and "[^"]+")?' | grep -oE '"[^"]+"' | tr -d '"' | sort -u)
ok "the code cites sections (a sanity check of the grep)" test "$(grep -c . <<<"$cited")" -ge 5
ok "docs/canccu-dispatch.md exists and points at the reference" grep -qF 'reference/README.md' docs/canccu-dispatch.md
nohead="" nomap=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  sed -nE 's/^#{2,4} //p' "$R"/*.md 2>/dev/null | grep -qxF -- "$s" || nohead+=" \"$s\""
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
# #209: CI runs the full suite; a worker that ran it locally spent its time budget on it
ok "AGENTS.md tells no one to run the full suite locally" not grep -qE '(full local check|`tests/run`\)? \*\*once|tests/run`[^ ]* (once|in full|before push))' AGENTS.md
ok "… but the repo checks before every push" grep -qF 'Before every push, run `tests/run repo`' AGENTS.md
ok "CLAUDE.md's finish runs the repo checks, not the full suite (#209)" \
  eq "$(grep -cE '^1\. .*`tests/run repo`' CLAUDE.md) $(grep -cE '(once, in full|rerun the local check)' CLAUDE.md)" "1 0"
ok "… and no worker adds a size exemption" grep -qF "A new exemption needs the product owner's accept; a worker never adds one." AGENTS.md

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
    # the headings outside fenced code; a repeated slug gets GitHub's -1, -2, … suffix
    found=0; declare -A seen=()
    while IFS= read -r h; do
      s=$(slug "$h"); n=${seen[$s]:-0}; seen[$s]=$((n + 1)); (( n )) && s+="-$n"
      [ "$s" = "$a" ] && { found=1; break; }
    done < <(awk '/^```/ { f = !f; next } !f && /^#+ / { sub(/^#+ /, ""); print }' "$t")
    unset seen
    (( found )) || broken+=" $f→$l"
  done < <(grep -oE '\]\([^) ]+\)' "$f" | sed -E 's/^\]\((.*)\)$/\1/')
done
ok "every relative link in the docs resolves, anchors included" eq "${broken# }" ""
# the role is the leader (#187): its topic is leader.md, and nothing points at the old name
ok "docs/reference/leader.md is the leader's topic" grep -qx '# The leader' docs/reference/leader.md
ok "no link or pointer to lead.md is left" eq "$(grep -rlE '(^|[^a-z_-])lead\.md' --exclude-dir=.git --exclude-dir=plan --exclude=canccu-docs.sh . | sort | tr '\n' ' ')" ""

# ---------------------------------------------------------------- the README

tested=$(sed -n 's/^CANCCU_CLAUDE_TESTED=//p' lib/canccu-deps.sh)
ok "the tested Claude Code version is read from lib/canccu-deps.sh" test -n "$tested"
ok "docs/getting-started.md names it too" grep -qF -- "Claude Code ${tested:-?}" docs/getting-started.md
# shellcheck disable=SC2088  # the literal text the README names
for w in install.sh canccu-init canccu-up uninstall REVIEWER_LOGIN templates/repo/ gh git jq tmux bash python3 \
         "${tested:-?}" ruleset collaborator '~/.canccu'; do
  ok "README.md names $w" grep -qF -- "$w" README.md
done
# the superpowers plugin is optional (#43): only docs/hosts.md, the plans and the changelogs name it
gs1=$(awk '/^## 1\./ { on = 1; next } /^## / { on = 0 } on' docs/getting-started.md)
ok "getting-started section 1 is read" grep -qF Claude <<<"$gs1"
ok "… it does not name the superpowers plugin" not grep -qi superpowers <<<"$gs1"
ok "… nor README.md, nor the reference" eq "$(grep -lir superpowers README.md docs/reference | tr '\n' ' ')" ""
ok "getting-started's Next points at the optional plugin" grep -qxF 'Optional: a skills plugin for the workers: [hosts.md](hosts.md#skills).' docs/getting-started.md
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
ok "the REVIEW.md snippet holds the three headings review_md keeps (#193)" \
  eq "$(grep -E '^#+ ' "$S/REVIEW.snippet.md" 2>/dev/null | tr '\n' '|')" "## Also check|## Never blocks|## Known false positives|"
ok "… and docs name it" grep -qF 'REVIEW.snippet.md' docs/repo-contract.md

# the person who accepts is the product owner (contracts §1): the agent instructions and the
# prompts never call them "the maintainer", or workers copy it into their PR bodies (#131)
ok "CLAUDE.md and lib/ never say \"the maintainer\"" eq "$(grep -rniw 'the maintainer' CLAUDE.md lib/)" ""

# ---------------------------------------------------------------- the kickoff and gate guides (#216 D7)

tname=guides
for g in kickoff gates; do
  ok "docs/$g.md exists with its SPDX line" eq "$(head -1 "docs/$g.md" 2>/dev/null)" "<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->"
  ok "… linked from docs/README.md" grep -qF "]($g.md)" docs/README.md
done
miss=""; for h in Vision Users 'Their experiences' 'Quality bar' Constraints 'The step ladder' 'Question bank'; do
  grep -qE "^#+ $h" docs/kickoff.md 2>/dev/null || miss+=" $h"
done
ok "docs/kickoff.md has the template's headings and a question bank" eq "${miss# }" ""
miss=""; for h in 'Always: the functional gate' 'Chosen per step' UX 'API or library' 'CLI or tooling' Performance Security Operations 'Data or AI'; do
  grep -qE "^#+ $h" docs/gates.md 2>/dev/null || miss+=" $h"
done
ok "docs/gates.md has the functional gate and each gate chosen per step" eq "${miss# }" ""

# ---------------------------------------------------------------- how it works, two paths (#40)

H=docs/how-it-works.md
ok "docs/how-it-works.md exists with its SPDX line" eq "$(head -1 "$H" 2>/dev/null)" "<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->"
ok "… at most 250 lines" test "$(wc -l < "$H" 2>/dev/null || echo 999)" -le 250
ok "… with its six sections, in order" eq "$(grep -E '^## ' "$H" 2>/dev/null | tr '\n' '|')" \
  "## One issue|## When it needs someone|## Steps|## Without a leader|## With a leader|## Who accepts|"
ok "… and three mermaid diagrams" eq "$(grep -cx '```mermaid' "$H" 2>/dev/null)" 3
# section <file> <heading>: the lines under a ## heading, up to the next one
section() { awk -v h="$2" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$1" 2>/dev/null; }
whowhat=$(section "$H" '## With a leader')
ok "the \"Who does what\" table has the columns Task, Without a leader, With a leader" \
  grep -qxF '| Task | Without a leader | With a leader |' <<<"$whowhat"
miss=""
for r in 'Write issues' 'Plan the steps (kickoff)' 'Answer an escalated question' 'Clear a failed run or red CI' \
         'Accept a technical PR' 'Accept what users see' 'Accept a gated path' 'Accept a high-risk PR' \
         'Checkpoint' 'Change a locked setting' 'Watch the pace'; do
  grep -qF -- "| $r |" <<<"$whowhat" || miss+=" '$r'"
done
ok "… and its 11 rows" eq "${miss# }" ""
ok "… and no other" eq "$(grep -cE '^\| [A-Z]' <<<"$whowhat")" 12
matrix=$(section "$H" '## Who accepts')
miss=""
for r in '`LEADER=off`' '`on`, `LEADER_ACCEPTS=none`' '`on`, `LEADER_ACCEPTS=technical`' \
         '`on`, `technical`, `LEADER_ACCEPTS_HIGH_RISK=1`'; do
  grep -qF "| $r |" <<<"$matrix" || miss+=" $r"
done
ok "the \"Who accepts\" matrix has its 4 rows" eq "${miss# }" ""
ok "… 4 settings rows under the header" eq "$(grep -cE '^\| `' <<<"$matrix")" 4
ok "… and the 60-minute hand-over below it" grep -qF '60 minutes' <<<"$matrix"
ok "the steps section links kickoff.md, gates.md and the pacing" \
  eq "$(section "$H" '## Steps' | grep -oE '\]\((kickoff\.md|gates\.md|reference/usage\.md#pacing)\)' | sort -u | wc -l)" 3
ok "how-it-works says leader and product owner, never lead or maintainer" \
  eq "$(grep -ciwE 'the lead|maintainer' "$H" 2>/dev/null)" 0

G=docs/getting-started.md
ok "getting-started has sections 1 to 8 and Next" eq "$(grep -E '^## ' "$G" | sed -E 's/^## ([0-9]+\.|Next).*/\1/' | tr '\n' ' ')" \
  "1. 2. 3. 4. 5. 6. 7. 8. Next "
ok "… named 6. Notifications, 7. Without a leader, 8. With a leader" \
  eq "$(grep -E '^## [678]\. ' "$G" | tr '\n' '|')" "## 6. Notifications|## 7. Without a leader|## 8. With a leader|"
intro=$(awk '/^## 1\./ { exit } { print }' "$G")
ok "… its intro's table names the two paths" \
  eq "$(grep -cE '^\| (Without a leader \| 1 to 7|With a leader \| 1 to 6, then 8) ' <<<"$intro")" 2
ok "… section 5 ends in canccu-init --check web" grep -qF 'canccu-init --check web' <<<"$(section "$G" '## 5. Add the project' | tail -8)"
ok "… section 6 links Telegram's setup" grep -qF '](reference/notify.md#setting-it-up)' <<<"$(section "$G" '## 6. Notifications')"
ok "… section 7 has no leader paragraph" not grep -qF 'canccu-init --leader' <<<"$(section "$G" '## 7. Without a leader')"
s8=$(section "$G" '## 8. With a leader')
ok "… section 8 sets up the leader and names LEADER_ACCEPTS" eq "$(grep -cE 'canccu-init --leader web|LEADER_ACCEPTS' <<<"$s8" | tr -d ' ')" 2
above=$(awk '/^## Prerequisites/ { exit } { print }' README.md | grep -vE '^\s*$' | tail -1)
ok "README.md links how-it-works and getting-started on the line above ## Prerequisites" \
  eq "$(grep -oE '\]\(docs/(how-it-works|getting-started)\.md\)' <<<"$above" | wc -l)" 2
ok "docs/README.md lists how-it-works right after getting-started" \
  eq "$(grep -oE '^\| \[`[a-z-]+\.md`\]' docs/README.md | sed -n '1,2p' | tr -d '|[]` ' | tr '\n' ' ')" "getting-started.md how-it-works.md "

# ---------------------------------------------------------------- PACE=pause drains (#216 D6)

# PACE=pause holds new work only (draining), as the weekly drain: the docs say so, not "resumes
# nothing" or "not resumed" (#222)
ok "usage.md: PACE=pause lets the resumes and fix runs of started work go on" \
  eq "$(grep -c 'resumes nothing' $R/usage.md) $(tr '\n' ' ' < $R/usage.md | grep -c 'the resumes of *stopped runs .* and the fix runs of work already *started')" "0 1"
ok "… config-steps.md's PACE row too" grep -qF 'resumes and fix runs of started work go on' $R/config-steps.md

echo "canccu-docs tests: $npass passed, $nfail failed"
(( nfail == 0 ))
