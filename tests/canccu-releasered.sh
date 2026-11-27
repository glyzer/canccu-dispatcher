#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-releasered.sh — a release-red issue ("release red at <sha7>") is not work until the
# dispatcher reran the failed jobs at that commit once: green closes it (a flaky check gets its
# "flaky: <check>" issue; an infrastructure error files nothing), red leaves it as work
# (lib/canccu-releasered.sh; the harness: tests/lib/harness.sh).
. "$(dirname "$0")/lib/harness.sh"

sha=abc1234def5678abc1234def5678abc1234def56
fx=$root/tests/fixtures/ci
rr() { cat "$CANCCU_HOME/release-red/7" 2>/dev/null | grep "^$1=" | cut -d= -f2-; }
# relenv <name> [config...]: issue 7 "release red at abc1234" (ready, release-red), run 700 at
# that commit failed in job 77 (test, the vitest log); issue 8 is ready work
relenv() {
  env_new "$@"
  { issue 7 ready,release-red | jq '.title = "release red at abc1234"'; issue 8 ready; } | issues
  json commit.json "{\"sha\": \"$sha\"}"; route 'api repos/example-org/web/commits/abc1234*' commit.json
  json rr-runs.json '[{"databaseId": 700, "conclusion": "failure", "attempt": 1}, {"databaseId": 701, "conclusion": "success", "attempt": 1}]'
  route 'run list *' rr-runs.json
  json jobs.json '{"jobs": [{"name": "test", "databaseId": 77, "conclusion": "failure", "url": "https://github.com/example-org/web/actions/runs/700/job/77"},
    {"name": "lint", "databaseId": 78, "conclusion": "success", "url": "u"}]}'
  route 'run view 700 * --json jobs' jobs.json
  json status.json '{"status": "in_progress", "conclusion": "", "attempt": 2}'
  route 'run view 700 * --json status,conclusion,attempt' status.json
  cp "$fx/vitest.log" "$FAKE/log77"; route 'run view --job 77 *' log77
  json ok.json '{}'; route 'run rerun *' ok.json
}
ended() { json status.json "{\"status\": \"completed\", \"conclusion\": \"$1\", \"attempt\": 2}"; }

relenv green
dispatch --once
ok "a release-red: the failed run at its commit rerun, failed jobs only" \
  eq "$(grep -c "^run list .*--commit $sha --branch main" "$FAKE/gh.log") $(grep -c '^run rerun 700 --failed' "$FAKE/gh.log") $(grep -c '^run rerun 701' "$FAKE/gh.log")" "1 1 0"
ok "… not taken as work while its rerun runs; the other ready issue is" \
  eq "$(grep -c -- '--name #7 ' "$FAKE/worker.log") $(grep -c -- '--name #8 ' "$FAKE/worker.log")" "0 1"
ok "… its state: rerun, run 700 at attempt 1" eq "$(rr rr) $(rr rr_runs)" "rerun 700:1"
dispatch --once
ok "the rerun happens once across passes" eq "$(grep -c '^run rerun' "$FAKE/gh.log")" 1
ok "… a rerun still running: nothing closed or commented" eq "$(grep -cE '^issue (close|comment) 7' "$FAKE/gh.log")" 0
ended success
dispatch --once
ok "red then green → a flaky: test issue, with the count 1, not ready" \
  eq "$(grep -c '^issue create .*--title flaky: test' "$FAKE/gh.log") $(grep -c '^Failures: 1$' "$FAKE/created-900") $(grep -c '^issue edit 900 .*--add-label ready' "$FAKE/gh.log")" "1 1 0"
ok "… its comment has the job, the runs and the failing lines" \
  eq "$(grep -c 'actions/runs/700/job/77' "$FAKE/comment-900") $(grep -c 'AssertionError: expected' "$FAKE/comment-900")" "1 2"
ok "… the release-red gets a link to it and is closed" \
  eq "$(grep -c '#900 (`flaky: test`)' "$FAKE/comment-7") $(grep -c '^issue close 7' "$FAKE/gh.log") $(rr rr)" "1 1 closed"
ok "… the rerun ran once in all" eq "$(grep -c '^run rerun' "$FAKE/gh.log")" 1

# two failed jobs, one's name the start of the other's: each flaky: issue has its own job's lines
relenv prefix
json jobs.json '{"jobs": [{"name": "test", "databaseId": 77, "conclusion": "failure", "url": "https://github.com/example-org/web/actions/runs/700/job/77"},
  {"name": "test arm", "databaseId": 79, "conclusion": "failure", "url": "https://github.com/example-org/web/actions/runs/700/job/79"}]}'
cp "$fx/eslint.log" "$FAKE/log79"; route 'run view --job 79 *' log79
printf '900\n901\n' > "$FAKE/new-issues"
dispatch --once; ended success; dispatch --once
ok "jobs test and test arm → flaky: test has only test's lines, flaky: test arm only its own" \
  eq "$(grep -c 'AssertionError: expected' "$FAKE/comment-900") $(grep -cE '✖ 2 problems|30:1 +error' "$FAKE/comment-900") $(grep -c 'AssertionError: expected' "$FAKE/comment-901") $(grep -cE '✖ 2 problems|30:1 +error' "$FAKE/comment-901")" "2 0 0 2"

# a second flaky failure of the same check: count 2, ready, after every other ready issue
relenv second
{ issue 7 ready,release-red | jq '.title = "release red at abc1234"'
  issue 30 "" "The check \`test\` failed …

Failures: 1" | jq '.title = "flaky: test"'
  issue 40 ready; } | issues
dispatch --once; ended success; dispatch --once
ok "a second flaky failure → the issue's count is 2, no new issue" \
  eq "$(grep -c '^issue create' "$FAKE/gh.log") $(grep -c '^Failures: 2$' "$FAKE/body-30")" "0 1"
ok "… and it gets ready" grep -q '^issue edit 30 .*--add-label ready' "$FAKE/gh.log"
ok "a flaky: issue comes after every other ready issue in the queue" \
  eq "$(lib eval 'ISSUES=$(jq -n "[{number: 3, title: \"flaky: test\", labels: [{name: \"ready\"}], body: \"\", milestone: null}, {number: 9, title: \"Issue 9\", labels: [{name: \"ready\"}], body: \"\", milestone: null}]"); candidates' | tr '\n' ' ')" "9 3 "

# the close fails once: the next pass retries the close only, the flaky: check is not counted again
relenv closefails
dispatch --once; ended success
echo 'fail:issue close' >> "$FAKE/routes"
dispatch --once
ok "the close fails → the flaky: issue is filed, the release-red is not closed yet" \
  eq "$(grep -c '^issue create .*--title flaky: test' "$FAKE/gh.log") $(rr rr)" "1 rerun"
sed -i '/^fail:issue close$/d' "$FAKE/routes"
{ issue 7 ready,release-red | jq '.title = "release red at abc1234"'
  issue 900 "" "Failures: 1" | jq '.title = "flaky: test"'
  issue 8 ready; } | issues
dispatch --once
ok "… the next pass closes it, the check counted once: no second comment, edit or ready" \
  eq "$(grep -c '^issue create' "$FAKE/gh.log") $(grep -cE '^issue (comment|edit) 900' "$FAKE/gh.log") $(grep -c '^issue comment 7' "$FAKE/gh.log") $(grep -c '^issue close 7' "$FAKE/gh.log") $(rr rr)" "1 1 1 2 closed"
ok "… its close comment still links the flaky: issue" grep -q '#900 (`flaky: test`)' "$FAKE/comment-7"

relenv red
dispatch --once; ended failure; dispatch --once
ok "red then red → an ordinary issue: a comment with the digest, not closed, nothing filed" \
  eq "$(grep -c 'red again' "$FAKE/comment-7") $(grep -c 'AssertionError: expected' "$FAKE/comment-7") $(grep -c '^issue close 7' "$FAKE/gh.log") $(grep -c '^issue create' "$FAKE/gh.log") $(rr rr)" "1 2 0 0 ordinary"
dispatch --once
ok "… then taken as work" grep -q -- '--name #7 ' "$FAKE/worker.log"

relenv infra
printf 'test\tPull\t2030-11-05T10:00:00Z Error response from daemon: toomanyrequests: You have reached your pull rate limit\n' > "$FAKE/log77"
dispatch --once; ended success; dispatch --once
ok "a registry error then green → closed with a comment naming it, nothing filed" \
  eq "$(grep -c 'infrastructure error' "$FAKE/comment-7") $(grep -c 'toomanyrequests' "$FAKE/comment-7") $(grep -c '^issue close 7' "$FAKE/gh.log") $(grep -c '^issue create' "$FAKE/gh.log")" "1 1 1 0"

relenv norun
json rr-runs.json '[{"databaseId": 701, "conclusion": "success", "attempt": 1}]'
dispatch --once
ok "no failed run at the commit → logged, an ordinary issue taken as work" \
  eq "$(grep -c '#7 release-red: no failed run at abc1234' "$CANCCU_HOME/dispatch.log") $(grep -c -- '--name #7 ' "$FAKE/worker.log") $(rr rr)" "1 1 ordinary"

relenv refused
sed -i 's/^run rerun \*\tok.json$/run rerun *\tFAIL/' "$FAKE/routes"
dispatch --once
ok "a rerun that cannot start → logged, an ordinary issue" \
  eq "$(grep -c '#7 release-red: no rerun started' "$CANCCU_HOME/dispatch.log") $(rr rr)" "1 ordinary"

relenv off RELEASE_RED_LABEL=
dispatch --once
ok "RELEASE_RED_LABEL empty → as before: no rerun, the issue is work at once" \
  eq "$(grep -c '^run rerun' "$FAKE/gh.log") $(grep -c -- '--name #7 ' "$FAKE/worker.log")" "0 1"

echo "canccu-releasered tests: $npass passed, $nfail failed"
(( nfail == 0 ))
