#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/leak.sh — tests/leak-check.sh against throwaway repos. The words, e-mails and paths it
# must catch are put together at run time, so this file never trips the check itself.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
check=$root/tests/leak-check.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
npass=0 nfail=0 tname=""
ok() { if "${@:2}"; then npass=$((npass + 1)); else nfail=$((nfail + 1)); echo "FAIL [$tname] $1"; fi; }
eq() { [ "$1" = "$2" ] || { echo "    expected: $2"; echo "    got:      $1"; return 1; }; }
has() { grep -qF -- "$2" <<<"$1" || { echo "    output lacks: $2"; return 1; }; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || { echo "    output has: $2"; return 1; }; }

WORD="zor""blax"                       # the secret word of the deny-list
HOMEP="/ho""me/alice/src"              # an absolute home path
MAIL="a.person""@""mail.test"          # an e-mail that is not a noreply one
NOREPLY="123+octo""@""users.noreply.github.com"
IP="192.168.""4.20"
export HOME=$T/home; mkdir -p "$HOME/.config"
printf '# a comment\n\n%s\nexample-org\n' "$WORD" > "$T/words"
unset CANCCU_LEAK_WORDS

# repo <name>: a fresh repo whose origin is example-org/web, with one clean commit
repo() {
  tname=$1; R=$T/$1; mkdir -p "$R"; cd "$R" || exit 1
  git init -q -b main . && git remote add origin https://github.com/example-org/web.git
  git config user.name octo && git config user.email "$NOREPLY"
  echo "clean text" > README.md && git add -A && git commit -qm "first"
}
run() { out=$("$check" "$@" 2>&1); rc=$?; }

repo clean
CANCCU_LEAK_WORDS=$T/words run
ok "a clean repo passes" eq "$rc" 0

repo word
printf 'line one\nsee %s here\n' "$WORD" > notes.txt
CANCCU_LEAK_WORDS=$T/words run
ok "a deny-listed word fails" eq "$rc" 1
ok "… naming file and line" has "$out" "notes.txt:2"
ok "… never the word" hasnt "$out" "$WORD"
ok "… nor the line" hasnt "$out" "see "
ok "a word is matched in any case" bash -c "printf '%s\n' '${WORD^^}' > up.txt; CANCCU_LEAK_WORDS=$T/words '$check' | grep -q up.txt:1"
rm -f up.txt

repo own
printf 'clone example-org/web, see https://github.com/example-org/web/pull/3\n' > own.txt
printf 'by %s\n' "$NOREPLY" > mail.txt
CANCCU_LEAK_WORDS=$T/words run
ok "the repo's own owner/name and noreply e-mails pass" eq "$rc" 0
printf 'other: example-org/tools\n' > other.txt
CANCCU_LEAK_WORDS=$T/words run
ok "the owner in another repo's name fails" has "$out" "other.txt:1"

repo default-list
cp "$T/words" "$HOME/.config/canccu-leak-words"
printf '%s\n' "$WORD" > w.txt
run
ok "without CANCCU_LEAK_WORDS the list in ~/.config is read" has "$out" "w.txt:1"
rm -f "$HOME/.config/canccu-leak-words"

repo generic
printf '%s\n' "$WORD" > w.txt
run
ok "with no list a word passes" eq "$rc" 0
printf 'cd %s\n' "$HOMEP" > p.txt; printf 'mail %s\n' "$MAIL" > m.txt; printf 'host %s\n' "$IP" > i.txt
printf 'HOME=/ho%sme/someone and git@github.com:x\n' "" > fine.txt
run
ok "an absolute home path fails" has "$out" "p.txt:1"
ok "another e-mail fails" has "$out" "m.txt:1"
ok "a private IP fails" has "$out" "i.txt:1"
ok "the test home and git@github.com pass" hasnt "$out" "fine.txt"
ok "… exit 1" eq "$rc" 1

repo history
printf '%s\n' "$WORD" > gone.txt && git add -A && git commit -qm "add" && git rm -q gone.txt && git commit -qm "rm"
CANCCU_LEAK_WORDS=$T/words run
ok "a word only in history passes the working-tree scan" eq "$rc" 0
CANCCU_LEAK_WORDS=$T/words run --history
ok "--history finds it" eq "$rc" 1
ok "… naming the path" has "$out" "gone.txt:1"
ok "… never the word" hasnt "$out" "$WORD"

repo commits
git -c user.email="$MAIL" commit -q --allow-empty -m "plain"
CANCCU_LEAK_WORDS=$T/words run --history
ok "--history: an author e-mail fails" has "$out" "author e-mail"
ok "… exit 1" eq "$rc" 1
repo message
git commit -q --allow-empty -m "fix the $WORD bug"
CANCCU_LEAK_WORDS=$T/words run --history
ok "--history: a commit message fails" has "$out" "message"
ok "… exit 1" eq "$rc" 1
ok "… never the word" hasnt "$out" "$WORD"
repo noreply
git commit -q --allow-empty -m "$(printf 'x\n\nCo-Authored-By: Bot <noreply@example.test>')"
CANCCU_LEAK_WORDS=$T/words run --history
ok "--history: a noreply co-author passes" eq "$rc" 0

repo bad-list
printf '%s\n' "$WORD" > w.txt
printf '%s\n(unclosed\n' "$WORD" > "$T/bad-words"
CANCCU_LEAK_WORDS=$T/bad-words run
ok "an invalid regex in the deny-list: a usage error, never clean" eq "$rc $(grep -c 'leak-check: clean' <<<"$out")" "2 0"
ok "… saying the list is broken" has "$out" "the deny-list has an invalid regex"

tname=usage
run --bogus
ok "an unknown flag is a usage error" eq "$rc" 2

echo "leak: $npass passed, $nfail failed"
(( nfail == 0 ))
