#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/store.sh — the store and the tally command: bash tests/store.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
TALLY_FILE=$(mktemp -u); export TALLY_FILE
trap 'rm -f "$TALLY_FILE" "$TALLY_FILE.tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$3', got '$2'"; fail=1; fi; }
t() { "$root/bin/tally" "$@"; }

t add apples; t add apples 2; t add pears
check "add counts up" "$(t show apples)" "$(printf 'apples\t3')"
check "the file is sorted" "$(t show)" "$(printf 'apples\t3\npears\t1')"
t reset apples
check "reset removes the counter" "$(t show)" "$(printf 'pears\t1')"
check "an unknown name counts 0" "$(t show plums)" "$(printf 'plums\t0')"
# --- new checks above this line
exit "$fail"
