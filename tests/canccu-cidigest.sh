#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-cidigest.sh — a red CI's fix run gets a digest of its failing jobs' logs, built by
# script (lib/canccu-cidigest.sh): the failure lines of every failing job under its name, none of
# the compose and teardown noise, never more than CI_DIGEST_LINES lines; the tail where nothing
# matches (the harness: tests/lib/harness.sh).
. "$(dirname "$0")/lib/harness.sh"

fx=$root/tests/fixtures/ci
wline() { grep -E "^--quiet --name #5 (--[a-z]+ [^ ]+ |--fresh )*web 5 " "$FAKE/worker.log" | tail -1; }
# digest <fixture> [max]: the fixture log's digest, as a CI fix run's task gets it, one line each
digest() { lib eval "ci_log_clean < '$fx/$1.log' | ci_log_digest ${2:-120}"; }
# red <name> <jobs json> [config...]: issue 5 in check, PR 50 red with these checks, main merged in
red() {
  local name=$1 checks=$2; shift 2
  env_new "$name" "$@"
  { issue 5 in-progress; } | issues
  pr 50 5 $HA red | jq --argjson c "$checks" '.statusCheckRollup = $c' | prs
  state 5 phase=check pr=50 "check_at=$NOW" "ci_rerun=$HA"
  mkdir -p "$WORKERS_DIR/worktrees/web/issue-5" && touch "$WORKERS_DIR/worktrees/web/issue-5/.git"
  echo 5-thing > "$FAKE/branch"; echo 0 > "$FAKE/behind"
}
check() {   # check <name> <run> <job>: a failed Actions check
  jq -n --arg n "$1" --arg u "https://github.com/example-org/web/actions/runs/$2/job/$3" \
    '{name: $n, status: "COMPLETED", conclusion: "FAILURE", completedAt: "2030-11-05T10:00:00Z", detailsUrl: $u}'
}

d=$(digest vitest)
ok "vitest: both failing tests, their assertion and the summary" eq "$(grep -cE 'FAIL +src/(cart|price).test.ts|AssertionError: expected|Tests  2 failed|Test Files  2 failed' <<<"$d")" 6
ok "… the lines after a failure (the diff, the source line)" grep -qF '❯ src/cart.test.ts:14:22' <<<"$d"
ok "… no ANSI codes, no timestamps, no job and step columns" not grep -qE $'\x1b|2030-11-05T|^test\t' <<<"$d"
ok "… not the setup lines above, nor Actions' exit code line" not grep -qE 'setup line|exit code 1' <<<"$d"
ok "… the summary lines first: the cap never cuts them" eq "$(head -n 2 <<<"$d" | grep -c failed)" 2
d=$(digest eslint)
ok "eslint: both errors and the problem count" eq "$(grep -cE '^ +(12:5|30:1) +error|✖ 2 problems' <<<"$d")" 3
d=$(digest screenshot)
ok "screenshots: each FAIL line with its reason" eq "$(grep -cE '^FAIL (cart|login)\.png: ' <<<"$d")" 2
ok "… and the count" grep -qF '22 passed, 2 failed' <<<"$d"
d=$(digest compose)
ok "compose noise: the failure and its error" eq "$(grep -cE 'FAIL  e2e/checkout.spec.ts|expected status 200, got 500|checkout.spec.ts:41:7' <<<"$d")" 3
ok "… none of the compose logs or the teardown, though they hold FAIL and Error:" \
  not grep -qE 'web-1|db-1|Container|Network|docker compose|ECONNREFUSED|##\[' <<<"$d"
ok "no failure line → an empty digest (the caller takes the tail)" eq "$(digest nomatch)" ""
ok "CI_DIGEST_PATTERN empty → an empty digest too" eq "$(lib eval "CI_DIGEST_PATTERN=; ci_log_clean < '$fx/vitest.log' | ci_log_digest 120")" ""
ok "a digest never has more lines than asked" eq "$(digest vitest 5 | wc -l)" 5

# a fix run's task: the digest of both failing jobs, each under its name
red two "[$(check test 700 77), $(check lint 700 78)]"
cp "$fx/vitest.log" "$FAKE/log77"; cp "$fx/eslint.log" "$FAKE/log78"
route 'run view --job 77 *' log77; route 'run view --job 78 *' log78
dispatch --once
l=$(wline)
ok "two failing jobs → one fix run whose task has the digest of both" \
  eq "$(grep -c 'CI gave this failure digest' <<<"$l") $(grep -oE 'AssertionError: expected 2 to be 3|30:1 +error' <<<"$l" | wc -l)" "1 2"
ok "… each under its job's name and link" \
  grep -qF '== test (https://github.com/example-org/web/actions/runs/700/job/77) == ⏎' <<<"$l"
ok "… the other job's too" grep -qF '== lint (https://github.com/example-org/web/actions/runs/700/job/78) == ⏎' <<<"$l"
ok "… each log read once" eq "$(grep -c '^run view --job 77 ' "$FAKE/gh.log") $(grep -c '^run view --job 78 ' "$FAKE/gh.log")" "1 1"
ok "… not the teardown or setup lines" not grep -qE 'setup line|exit code 1' <<<"$l"

red cap "[$(check test 700 77), $(check lint 700 78)]" CI_DIGEST_LINES=10
cp "$fx/vitest.log" "$FAKE/log77"; cp "$fx/eslint.log" "$FAKE/log78"
route 'run view --job 77 *' log77; route 'run view --job 78 *' log78
dispatch --once
ok "CI_DIGEST_LINES=10 → the digest has at most 10 lines, both jobs' names among them" \
  eq "$(wline | grep -o 'lines separated by ⏎: .*' | grep -o ' ⏎ ' | wc -l | awk '{ print ($1 + 1 <= 10) }') $(wline | grep -oE '== (test|lint) ' | wc -l)" "1 2"

red nomatch "[$(check build 700 77)]"
cp "$fx/nomatch.log" "$FAKE/log77"; route 'run view --job 77 *' log77
dispatch --once
l=$(wline)
ok "a log with no failure line → its tail, as before the digest: the last CI_LOG_LINES lines" \
  eq "$(grep -c 'No line of the failing jobs.* logs matched CI_DIGEST_PATTERN; the tail of each' <<<"$l") $(grep -c 'build step 41 ⏎' <<<"$l") $(grep -c 'build step 40 ⏎' <<<"$l") $(grep -c 'the build ended badly' <<<"$l")" "1 1 0 1"

red nolog "[$(check build 700 77)]"
route 'run view --job 77 *' FAIL
dispatch --once
ok "no log read → how to read the failing checks" grep -qF 'Read the failing checks with gh pr checks 50 -R example-org/web' <<<"$(wline)"

echo "canccu-cidigest tests: $npass passed, $nfail failed"
(( nfail == 0 ))
