#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-deep.sh — offline tests for the end of a step beyond the health pass (#216): the
# step's deep review (STEP_DEEP_REVIEW), its polish issue, the step tag (STEP_TAG) and cadence
# rounds (CADENCE_DAYS). The step's git reads and the tags go to a real repo with a bare origin;
# the rest to the harness's fakes (tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

ms() { jq -nc --argjson n "$1" --arg t "$2" --argjson c "${3:-0}" --arg d "${4:-}" '{number: $n, title: $t, open_issues: 0, closed_issues: $c, due_on: null, description: $d}'; }
cpi() { jq -nc --argjson n "$1" --arg s "$2" --arg m "$3" --arg l "${4:-}" '{number: $n, title: "Checkpoint \($n)", state: $s, milestone: {title: $m},
  labels: ([{name: "checkpoint"}] + ($l | split(",") | map(select(. != "")) | map({name: .})))}'; }
# rg <git args...>: the real git in CLONE
rg() { GIT_AUTHOR_DATE=2030-11-05T10:00:00Z GIT_COMMITTER_DATE=2030-11-05T10:00:00Z \
         "$FAKE_REAL_GIT" -C "$E/code/web" -c user.name=octo -c user.email=octo@example.com "$@"; }
# report <blocking items...>: the deep review's report of step 4 lands on origin/main
report() {
  local f=$E/code/web/docs/reports/step-4-deep-review.md n=$# i b=""
  mkdir -p "${f%/*}"
  for ((i = 1; i <= n; i++)); do b+="$i. [correctness] src/a.ts:$i ${!i}"$'\n'"   Evidence: line $i"$'\n'; done
  { printf '## Architecture\nfine\n## Security\nfine\n## Contracts\nfine\n## Test quality\nfine\n\n'
    if (( n )); then printf 'Blocking:\n%s' "$b"; else echo 'Blocking: none'; fi
    printf 'Non-blocking: none\nPre-existing: none\nFindings: %s blocking, 0 non-blocking, 0 pre-existing\n\nReview verdict: %s %s\n' \
      "$n" "$( (( n )) && echo changes || echo pass)" "$(rg rev-parse HEAD)"; } > "$f"
  rg add -A >/dev/null; rg commit -qm "the deep review's report"; rg push -q origin HEAD:main 2>/dev/null; rg fetch -q origin
}
# denv <name> [config...]: step 4 Search (milestone 12), its work done (3 closed issues), its PRs and a
# follow-up issue recorded; checkpoint 95 open; step 5 Later (13) has a ready issue. CLONE is a
# clone of a bare origin; the git calls the steps make go there ($E/sbin/git)
denv() {
  env_new "$1" "${@:2}"
  jq -s . > "$FAKE/ms.json" < <(ms 12 "4 Search" 3 "$DESC"; ms 13 "5 Later")
  cpi 95 OPEN "4 Search" | jq -s . > "$FAKE/cps.json"
  { issue 90 epic "" "4 Search"; issue 41 ready "" "5 Later"; } | issues
  json c90.json '{"comments": []}'; route 'issue view 90 *' c90.json; route 'api -X PATCH *' empty.json
  rm -rf "$E/code/web" "$E/origin.git"
  "$FAKE_REAL_GIT" init -q --bare -b main "$E/origin.git"; "$FAKE_REAL_GIT" clone -q "$E/origin.git" "$E/code/web" 2>/dev/null
  echo start > "$E/code/web/README.md"; rg add -A; rg commit -qm start; rg push -q origin HEAD:main 2>/dev/null; rg fetch -q origin
  mkdir -p "$CANCCU_HOME/steps" "$E/sbin"
  printf 'pkg-12-a\ta\t1\t101 103\tnormal\t50\tmerged\n104\tb\t1\t104\tlow\t51\tmerged\n' > "$CANCCU_HOME/steps/12.packages"
  printf 'step-12-wave-1\t900\nstep-11-wave-1\t800\n' > "$CANCCU_HOME/followups"
  printf '#!/usr/bin/env bash\ncase " $* " in\n  *" fetch "*|*" rev-parse "*|*" show "*|*" tag "*|*" ls-remote "*|*" push -q origin refs/tags/"*|*" check-ref-format "*)\n    printf "%%s\\n" "$*" >> "$FAKE/git.log"; exec "$FAKE_REAL_GIT" "$@" ;;\nesac\nexec "%s/git" "$@"\n' "$fb" > "$E/sbin/git"
  chmod +x "$E/sbin/git"
}
DESC=""
dpass() { PATH="$E/sbin:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1; }
dlib() { ( PATH="$E/sbin:$fb:$PATH"; . "$root/lib/canccu-common.sh"; "$@" ) 2>/dev/null; }
sf() { sed -n "s/^$1=//p" "$CANCCU_HOME/steps/12" | tail -1; }
dlog() { grep -cF -- "$1" "$CANCCU_HOME/dispatch.log"; }

# ---------------------------------------------------------------- the deep review starts

denv deep-start STEP_DEEP_REVIEW=1
dpass
ok "STEP_DEEP_REVIEW=1, every work issue closed → the deep review starts, not the health pass" \
  eq "$(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log") $(grep -c -- '--key pkg-12-health' "$FAKE/worker.log")" "1 0"
ok "… step phase deep, deep running, deep_head origin/main's head" eq "$(sf phase) $(sf deep) $(sf deep_head)" "deep running $(rg rev-parse origin/main)"
ok "… logged" eq "$(dlog '#pkg-12-deep started: the deep review of step 4 Search')" 1
ok "… on its own window, fresh, on BUDGET_DEEP_REVIEW" grep -qE -- '--name deep#12 .*--fresh.* turns=150 cost=40 min=120$' "$FAKE/worker.log"
p=$(grep -- '--key pkg-12-deep' "$FAKE/worker.log")
ok "the prompt names the base (the step's PRs), the head and the issues" \
  grep -qF "from the step's merged PRs #50, #51 (read them with gh pr view <n> -R example-org/web and gh pr diff <n> -R example-org/web) up to origin/main at $(sf deep_head)" <<<"$p"
ok "… the step's issues" grep -qF "The step's issues: #101, #103, #104." <<<"$p"
ok "… its follow-up issues only" grep -qF "do not report them again): #900." <<<"$p"
ok "… the report path, its sections and the verdict line" grep -qF "Write the report docs/reports/step-4-deep-review.md with the sections ## Architecture, ## Security, ## Contracts and ## Test quality" <<<"$p"
ok "… the PR body lines and no Closes line" grep -qF "\`Package: deep-review\`, \`Step: 4 Search\` and \`Risk: low — the step's deep-review report\`, and no \`Closes\` line" <<<"$p"
dpass
ok "the step stays current while the deep review runs: the next step does not plan" eq "$(grep -c -- '--key plan-13' "$FAKE/worker.log")" 0
ok "… and the deep review starts once" eq "$(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log")" 1

denv deep-off
dpass
ok "STEP_DEEP_REVIEW=0: the health pass, as before" eq "$(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log") $(grep -c -- '--key pkg-12-health' "$FAKE/worker.log")" "0 1"

denv deep-tag-base STEP_DEEP_REVIEW=1 "STEP_TAG='step-{n}'"
rg tag step-3 HEAD; rg push -q origin refs/tags/step-3 2>/dev/null
dpass
ok "with STEP_TAG the base is the newest tag of its pattern" grep -qF "from the tag step-3 (git diff step-3..<head>) up to origin/main" "$FAKE/worker.log"

# ---------------------------------------------------------------- its PR merged: polish or health

# merged <name> [blocking items...]: the deep review's PR 60 merged with that report
merged() {
  denv "$1" STEP_DEEP_REVIEW=1; shift
  report "$@"
  printf 'phase=deep\ndeep=running\ndeep_head=%s\ntitle=4 Search\nepic=90\ncheckpoint=95\nstarted_at=%s\n' "$(rg rev-parse HEAD)" "$((NOW - 3600))" > "$CANCCU_HOME/steps/12"
  state pkg-12-deep pkg=deep step=12 deep=1 branch=pkg-12-deep risk=low phase=merging pr=60 merge_sha=$HA how=auto
  json pv60.json '{"state": "MERGED", "title": "Step 4 Search: deep review", "body": "Package: deep-review"}'; route 'pr view 60 *' pv60.json
}
merged deep-polish 'the cache is never cleared' 'the search index skips deleted items'
dpass
ok "a merged report with 2 blocking items → one polish issue, ready, in the milestone" \
  eq "$(grep -c '^issue create -R example-org/web --title Step 4 Search: polish (deep review) --milestone 4 Search --label ready --body ' "$FAKE/gh.log")" 1
ok "… it lists the items, the report and the PR" grep -qF 'PR #60, `docs/reports/step-4-deep-review.md`) left 2 blocking finding(s)' "$FAKE/gh.log"
ok "… step fields and phase idle" eq "$(sf deep) $(sf polish) $(sf deep_blocking) $(sf phase)" "merged 900 2 idle"
ok "… logged" eq "$(dlog 'step 4 Search: the deep review found 2 blocking finding(s); polish issue #900 filed')" 1
ok "… the deep unit is finished" test ! -e "$CANCCU_HOME/state/pkg-12-deep"
{ issue 90 epic "" "4 Search"; issue 900 ready "" "4 Search"; issue 41 ready "" "5 Later"; } | issues
dpass
ok "while the polish issue is open: the planner plans it, no health pass" \
  eq "$(grep -c -- '--key plan-12' "$FAKE/worker.log") $(grep -c -- '--key pkg-12-health' "$FAKE/worker.log") $(grep -c -- '--key plan-13' "$FAKE/worker.log")" "1 0 0"
rm -f "$WORKERS_DIR/web-plan-12.lock" "$CANCCU_HOME/state/plan-12"; sed -i '/^planner_started=/d; s/^phase=.*/phase=idle/' "$CANCCU_HOME/steps/12"
{ issue 90 epic "" "4 Search"; issue 41 ready "" "5 Later"; } | issues
jq -s . > "$FAKE/ms.json" < <(ms 12 "4 Search" 4; ms 13 "5 Later")
dpass
ok "the polish issue closed → the health pass starts, no second deep review" \
  eq "$(grep -c -- '--key pkg-12-health' "$FAKE/worker.log") $(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log")" "1 0"

merged deep-clean
dpass
ok "a report with nothing blocking → no issue, the health pass follows" \
  eq "$(grep -c 'issue create' "$FAKE/gh.log") $(sf deep) $(sf phase) $(dlog 'step 4 Search: the deep review found nothing blocking; the health pass follows')" "0 merged health-due 1"
dpass
ok "… it starts next pass" eq "$(grep -c -- '--key pkg-12-health' "$FAKE/worker.log")" 1

merged deep-noreport
git -C "$E/code/web" rm -q -r docs; rg commit -qm gone; rg push -q origin HEAD:main 2>/dev/null
dpass; dpass
ok "a merged PR without the report on main: one warning, read again each pass" \
  eq "$(dlog 'the deep review'"'"'s report docs/reports/step-4-deep-review.md is not on origin/main; read again next pass') $(sf deep) $(sf phase)" "1 read deep"

denv deep-closed STEP_DEEP_REVIEW=1
printf 'phase=deep\ndeep=running\ndeep_head=%s\ntitle=4 Search\nepic=90\ncheckpoint=95\n' "$HA" > "$CANCCU_HOME/steps/12"
state pkg-12-deep pkg=deep step=12 deep=1 branch=pkg-12-deep risk=low phase=needs-you pr=60
json pv60.json '{"state": "CLOSED", "title": "x", "body": ""}'; route 'pr view 60 *' pv60.json
dpass; dpass
ok "its PR closed without merging → deep closed, logged, the health pass follows" \
  eq "$(sf deep) $(sf phase) $(dlog '#pkg-12-deep: PR #60 was closed without merging; the health pass follows')" "closed health-due 1"
dpass
ok "… it starts" eq "$(grep -c -- '--key pkg-12-health' "$FAKE/worker.log")" 1

# ---------------------------------------------------------------- the checkpoint summary

denv deep-summary STEP_DEEP_REVIEW=1
printf 'phase=health\ndeep=merged\ndeep_pr=60\ndeep_blocking=2\npolish=900\ntitle=4 Search\n' > "$CANCCU_HOME/steps/12"
ok "checkpoint_summary names the deep review with STEP_DEEP_REVIEW=1" \
  grep -qxF '**Deep review:** PR #60, 2 blocking (polish #900)' <<<"$(dlib eval 'fetch_steps; checkpoint_summary 12')"
ok "… not without it" not grep -q 'Deep review' <<<"$(dlib eval 'fetch_steps; STEP_DEEP_REVIEW=0; checkpoint_summary 12')"

# ---------------------------------------------------------------- the step tag

# tagenv <name> [config...]: step 4 Search waits at checkpoint 95, which octo labelled checkpoint-ok
tagenv() {
  denv "$@"
  cpi 95 OPEN "4 Search" checkpoint-ok | jq -s . > "$FAKE/cps.json"
  printf 'phase=checkpoint\nhealth=merged\ncheckpoint_at=%s\ntitle=4 Search\nepic=90\ncheckpoint=95\n' "$NOW" > "$CANCCU_HOME/steps/12"
  json ev95.json "$(jq -n --arg t 2030-11-05T13:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "octo"}, created_at: $t}]')"
  route 'api --paginate repos/example-org/web/issues/95/events' ev95.json
}
tagenv tag-new "STEP_TAG='step-{n}'"
dpass
h1=$(rg rev-parse origin/main)
ok "checkpoint-ok with STEP_TAG='step-{n}' → step-4 on origin, at origin/main" eq "$(git -C "$E/origin.git" rev-parse step-4 2>/dev/null) $(sf phase)" "$h1 done"
ok "… logged" eq "$(dlog "step 4 Search: tagged step-4 at ${h1:0:7}")" 1
ok "… one tag and one push" eq "$(grep -c ' tag step-4 ' "$FAKE/git.log") $(grep -c 'push -q origin refs/tags/step-4' "$FAKE/git.log")" "1 1"
echo more >> "$E/code/web/README.md"; rg commit -qam more; rg push -q origin HEAD:main 2>/dev/null
rg tag -d step-4 >/dev/null
printf 'phase=checkpoint\nhealth=merged\ncheckpoint_at=%s\ntitle=4 Search\nepic=90\ncheckpoint=95\n' "$NOW" > "$CANCCU_HOME/steps/12"
dpass
ok "a second time, the tag on origin → not moved" eq "$(git -C "$E/origin.git" rev-parse step-4) $(dlog 'step 4 Search: tag step-4 exists already; not moved')" "$h1 1"
tagenv tag-none
dpass
ok "empty STEP_TAG → no git tag call, the step done" eq "$(cat "$FAKE/git.log" 2>/dev/null | grep -c " tag ") $(sf phase)" "0 done"
tagenv tag-bad "STEP_TAG='bad..{n}'"
dpass
ok "STEP_TAG='bad..{n}' → no tag, one warning" \
  eq "$(grep -c ' tag bad' "$FAKE/git.log") $(dlog 'STEP_TAG gives bad..4, which is no valid tag name: no step tag')" "0 1"
tagenv tag-non "STEP_TAG='release'"
dpass
ok "STEP_TAG without {n} → no tag, one warning" eq "$(cat "$FAKE/git.log" 2>/dev/null | grep -c " tag release") $(dlog 'STEP_TAG (release) has no {n}: no step tag')" "0 1"

# ---------------------------------------------------------------- cadence rounds (#216 D8)

# cenv <name> <days since the step started> [config...]: step 4 Search, marked `Cadence: on`, runs
# wave 1: package a (#101) works, package b (#104) waits for a slot; checkpoint 95 is open
cenv() {
  DESC=$'Search across all items.\nCadence: on' denv "$1" CADENCE_DAYS=14 STEP_DEEP_REVIEW=1 "STEP_TAG='step-{n}'" "${@:3}"
  { issue 90 epic "" "4 Search"; issue 101 in-progress "" "4 Search"; issue 104 ready "" "4 Search"; issue 41 ready "" "5 Later"; } | issues
  printf '%s\n' '{"schema":1,"step":12,"wave":1,"packages":[{"name":"a","issues":[101],"risk":"normal","risk_reason":"x","areas":[],"depends_on":[]},{"name":"b","issues":[104],"risk":"low","risk_reason":"y","areas":[],"depends_on":[]}]}' > "$CANCCU_HOME/steps/12.plan-1.json"
  printf 'phase=running\nwave=1\nplan=%s\nstarted_at=%s\ntitle=4 Search\nepic=90\ncheckpoint=95\n' "$CANCCU_HOME/steps/12.plan-1.json" "$((NOW - $2 * 86400))" > "$CANCCU_HOME/steps/12"
  : > "$CANCCU_HOME/steps/12.packages"
  state pkg-12-a pkg=a step=12 wave=1 members=101 branch=pkg-12-a risk=normal phase=work; live_lock pkg-12-a
}
cenv cadence-13 13
dpass
ok "a Cadence: on step, 13 days in: no round" eq "$(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log") $(dlog 'cadence round')" "0 0"
cenv cadence 14
dpass
ok "14 days in: round 1 starts" eq "$(dlog 'step 4 Search: cadence round 1 starts (every 14 days)') $(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log")" "1 1"
ok "… its deep review reads from the step's PRs, the step stays running" \
  eq "$(grep -c "from the step's merged PRs (read them" "$FAKE/worker.log") $(sf phase) $(sf round) $(sf round_phase)" "1 running 1 deep"
ok "… the wave goes on: package b starts" grep -q -- '--name #104 ' "$FAKE/worker.log"
h1=$(sf round_head)
# its report is merged with nothing blocking: the summary goes on the open checkpoint
report
rm -f "$WORKERS_DIR/web-pkg-12-deep.lock"; sed -i 's/^phase=.*/phase=merging/' "$CANCCU_HOME/state/pkg-12-deep"; echo pr=60 >> "$CANCCU_HOME/state/pkg-12-deep"
json pv60.json '{"state": "MERGED", "title": "Step 4 Search: deep review", "body": "Package: deep-review"}'; route 'pr view 60 *' pv60.json
touch "$FAKE/comment-urls"
dpass; dpass
ok "the round's report, nothing blocking → summary on the checkpoint, needs-you" \
  eq "$(grep -c '^issue edit 95 -R example-org/web --add-label needs-you' "$FAKE/gh.log") $(grep -c '^issue comment 95 .*Cadence round 1.* of step 4 Search' "$FAKE/gh.log") $(sf round_phase)" "1 1 checkpoint"
ok "… a checkpoint line in the feed" grep -qP '\tpo\task\tcheckpoint\t.*cadence round 1: checkpoint #95 waits for checkpoint-ok$' "$CANCCU_HOME/events"
ok "… no health pass, the step still running" eq "$(grep -c -- '--key pkg-12-health' "$FAKE/worker.log") $(sf phase)" "0 running"
cpi 95 OPEN "4 Search" checkpoint-ok,needs-you | jq -s . > "$FAKE/cps.json"
json ev95.json "$(jq -n --arg t 2030-11-05T13:00:00Z '[{event: "labeled", label: {name: "checkpoint-ok"}, actor: {login: "octo"}, created_at: $t}]')"
route 'api --paginate repos/example-org/web/issues/95/events' ev95.json
dpass
ok "checkpoint-ok by octo ends the round: label and needs-you go, the checkpoint stays open" \
  eq "$(grep -c '^issue edit 95 -R example-org/web --remove-label checkpoint-ok --remove-label needs-you' "$FAKE/gh.log") $(grep -c '^issue close 95' "$FAKE/gh.log")" "1 0"
ok "… the comment, the log, cadence_at" \
  eq "$(grep -c '^issue comment 95 -R example-org/web --body Cadence round 1 OK.' "$FAKE/gh.log") $(dlog 'step 4 Search: cadence round 1 OK') $(sf cadence_at) [$(sf round_phase)]" "1 1 $NOW []"
ok "… tagged step-4-r1" eq "$(git -C "$E/origin.git" rev-parse step-4-r1 2>/dev/null)" "$(rg rev-parse origin/main)"
cpi 95 OPEN "4 Search" | jq -s . > "$FAKE/cps.json"
CANCCU_NOW=$((NOW + 13 * 86400)) dpass
ok "13 days after the round: no round" eq "$(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log")" 1
CANCCU_NOW=$((NOW + 14 * 86400)) dpass
ok "14 days after: round 2, from round 1's head" \
  eq "$(dlog 'cadence round 2 starts') $(grep -c "from the head $h1 of cadence round 1 (git diff $h1..<head>)" "$FAKE/worker.log")" "1 1"

cenv cadence-nocp 20
cpi 95 CLOSED "4 Search" | jq -s . > "$FAKE/cps.json"
dpass; dpass
ok "a round due with no open checkpoint: skipped, one warning, cadence_at kept" \
  eq "$(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log") $(dlog 'cadence round 1 is due, but the step has no open checkpoint; skipped until one is open') [$(sf cadence_at)]" "0 1 []"
cenv cadence-nodeep 14 STEP_DEEP_REVIEW=0
touch "$FAKE/comment-urls"
dpass
ok "without STEP_DEEP_REVIEW a round is its checkpoint only" \
  eq "$(dlog 'cadence round 1 starts') $(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log") $(grep -c '^issue comment 95 .*Cadence round 1.* of step 4 Search' "$FAKE/gh.log") $(grep -c 'Deep review:' "$FAKE/gh.log") $(sf round_phase)" "1 0 1 0 checkpoint"
cenv cadence-off 30 CADENCE_DAYS=0
dpass
ok "CADENCE_DAYS=0: a normal step, no round" eq "$(grep -c -- '--key pkg-12-deep' "$FAKE/worker.log") $(dlog 'cadence')" "0 0"

echo "canccu-deep tests: $npass passed, $nfail failed"
(( nfail == 0 ))
