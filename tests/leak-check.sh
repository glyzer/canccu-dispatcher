#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/leak-check.sh [--history] — fail when the repo names what it must not: a word of the
# private deny-list, an absolute home path, an e-mail address, a private-network IP.
#
#   The deny-list: extended regexes, one per line (# comments and blank lines skipped), matched
#   in any case, from the file CANCCU_LEAK_WORDS names, else ~/.config/canccu-leak-words. The list
#   is never committed; without one only the generic patterns are checked.
#   Ignored: the repo's own owner/name (from the origin remote), noreply e-mails, git@github.com
#   and /home/someone (the tests' invented home).
#   Scans the working tree (tracked and untracked, not ignored files). --history also scans every
#   object of every ref (git rev-list --objects --all) and every commit's author and committer
#   names and e-mails and its message.
# Prints "<where>:<line>: <kind>" per hit, never the matched text or the list. Exit 1 on a hit,
# 2 on a usage error.
set -uo pipefail

history=0
for a; do
  case $a in
    --history) history=1 ;;
    *) echo "usage: tests/leak-check.sh [--history]" >&2; exit 2 ;;
  esac
done
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "leak-check: not in a git repo" >&2; exit 2; }
cd "$top" || exit 2

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
words=${CANCCU_LEAK_WORDS:-$HOME/.config/canccu-leak-words}
: > "$tmp/deny"
[ -r "$words" ] && grep -vE '^[[:space:]]*(#|$)' "$words" > "$tmp/deny"
# the generic patterns; each one cannot match its own source text here
cat > "$tmp/generic" <<'EOF'
(^|[^A-Za-z0-9_.~-])/(home|Users)/[A-Za-z0-9_.-]+
(^|[^A-Za-z0-9_.~-])/root/[A-Za-z0-9_.-]+
[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}
(^|[^0-9.])(10(\.[0-9]{1,3}){3}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2})($|[^0-9.])
EOF

# what is never a hit, taken out of each line before matching (sed -E; the own slug in any case)
own=$(git remote get-url origin 2>/dev/null |
  sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#\.git$##; s#/$##')
strip='s/[A-Za-z0-9._%+-]+@users\.noreply\.github\.com//g; s/noreply@[A-Za-z0-9.-]+//g; s/git@github\.com//g; s#/home/someone##g'
if [[ $own =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  strip+="; s#(^|[^A-Za-z0-9_.-])${own//./\\.}(\$|[^A-Za-z0-9_.-])#\\1\\2#Ig"
fi

hits=0
# scan <where> [note]: stdin's lines, filtered, against both lists; prints one line per hit
scan() {
  local f=$tmp/text n
  sed -E "$strip" > "$f"
  # an empty deny-list file makes grep -f match nothing
  for n in $(grep -niE -f "$tmp/deny" "$f" | cut -d: -f1); do echo "$1:$n: deny-list${2:+ ($2)}"; hits=1; done
  for n in $(grep -nE -f "$tmp/generic" "$f" | cut -d: -f1); do
    echo "$1:$n: home path, e-mail or private IP${2:+ ($2)}"; hits=1
  done
}
text_file() { [ -f "$1" ] && [ ! -L "$1" ] && grep -qI '' "$1" 2>/dev/null; }

while IFS= read -r -d '' p; do
  text_file "$p" && scan "$p" < "$p"
done < <(git ls-files -z -co --exclude-standard)

if (( history )); then
  while read -r sha type path; do
    [ "$type" = blob ] || continue
    git cat-file blob "$sha" > "$tmp/blob" 2>/dev/null || continue
    grep -qI '' "$tmp/blob" || continue
    scan "${path:-?}" "blob ${sha:0:7}" < "$tmp/blob"
  done < <(git rev-list --objects --all | git cat-file --batch-check='%(objectname) %(objecttype) %(rest)')
  while read -r c; do
    scan "commit ${c:0:7} author name" < <(git log -1 --format='%an' "$c")
    scan "commit ${c:0:7} author e-mail" < <(git log -1 --format='%ae' "$c")
    scan "commit ${c:0:7} committer name" < <(git log -1 --format='%cn' "$c")
    scan "commit ${c:0:7} committer e-mail" < <(git log -1 --format='%ce' "$c")
    scan "commit ${c:0:7} message" < <(git log -1 --format='%B' "$c")
  done < <(git rev-list --all)
fi

if (( hits )); then echo "leak-check: hits found"; exit 1; fi
echo "leak-check: clean"
