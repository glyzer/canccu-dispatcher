#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-ci.sh — the repo's GitHub configuration: the workflows (CI, its oldstable job, the
# release, the review gate), the review-gate templates this repo runs as they ship, Dependabot,
# and the issue and PR templates (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"
cd "$root" || exit 1
tname=ci

W=.github/workflows TR=templates/repo/.github
workflows=$(ls "$W"/*.yml "$TR"/workflows/*.yml 2>/dev/null)
# jobs <workflow>: its job ids, one per line
jobs() { sed -n '/^jobs:/,$p' "$1" | sed -nE 's/^  ([A-Za-z0-9_-]+):$/\1/p'; }
# job <workflow> <id>: the job's block, from its id to the next job
job() { sed -n '/^jobs:/,$p' "$1" | awk -v id="  $2:" '$0 == id { on = 1; next } /^  [A-Za-z0-9_-]+:$/ { on = 0 } on'; }

# ---------------------------------------------------------------- every workflow

ok "the workflows: CI, release and the review gate, plus the template's" \
  eq "$(echo "$workflows" | tr '\n' ' ')" "$W/ci.yml $W/release.yml $W/review-gate.yml $TR/workflows/review-gate.yml "
unpinned="" notimeout="" noperm=""
for y in $workflows; do
  while IFS= read -r l; do unpinned+=" $y: $l"; done < <(grep -E '^\s*-?\s*uses:' "$y" | grep -vE 'uses: [^@ ]+@[0-9a-f]{40} # v[0-9]')
  ok "$y: no permission granted to the whole workflow" grep -qx 'permissions: {}' "$y"
  for j in $(jobs "$y"); do
    job "$y" "$j" | grep -qE '^    timeout-minutes: [0-9]+$' || notimeout+=" $y:$j"
    job "$y" "$j" | grep -qE '^    permissions:' || noperm+=" $y:$j"
  done
done
ok "every action is pinned by a full SHA, its version in a comment" eq "${unpinned# }" ""
ok "every job has a timeout" eq "${notimeout# }" ""
ok "every job names its own permissions" eq "${noperm# }" ""
ok "no workflow reads a secret: the workflow token only" eq "$(grep -l 'secrets\.' $workflows)" ""

# ---------------------------------------------------------------- CI

Y=$W/ci.yml
ok "CI: two jobs, CI and CI (oldstable)" eq "$(grep -E '^    name: ' <(sed -n '/^jobs:/,$p' "$Y") | tr '\n' '|')" \
  "    name: CI|    name: CI (oldstable)|"
for j in $(jobs "$Y"); do
  ok "CI: job $j only reads the repo" eq "$(job "$Y" "$j" | sed -n '/^    permissions:/,/^    [a-z]/p' | grep -E '^      ' | tr -d ' ')" "contents:read"
  ok "CI: job $j runs the local check" grep -qE '^ +[^#]*tests/run$' <(job "$Y" "$j")
done
old=$(job "$Y" "$(jobs "$Y" | sed -n 2p)")
ok "CI (oldstable): in a debian:12 container" grep -qE '^      image: debian:12$' <<<"$old"
for p in bash jq tmux python3 git shellcheck; do
  ok "CI (oldstable): the distribution's $p" grep -qE "apt-get install .*[ ]$p( |$)" <<<"$old"
done
ok "CI: the job CI ends within 12 minutes" grep -qE '^    timeout-minutes: ([1-9]|1[0-2])$' <(job "$Y" ci)
# jq 1.6 starts about 8 times slower than 1.7, and the dispatcher's tests call it thousands of
# times: the same tests take more than twice as long there
ok "CI (oldstable): each test file may take 20 minutes" grep -qE 'CANCCU_TEST_TIMEOUT=20m .*tests/run$' <<<"$old"
ok "CI (oldstable): the job ends within 30 minutes" grep -qx '    timeout-minutes: 30' <<<"$old"
ok "CI (oldstable): the tests run as a user, not as root" grep -qE 'runuser -u [a-z]+ -- .*tests/run$' <<<"$old"
ci=$(job "$Y" ci)
ok "CI: builds the tarball with the release script" grep -qF '.github/scripts/release build' <<<"$ci"
ok "CI: … and runs its install smoke test" grep -qF '.github/scripts/release-smoke' <<<"$ci"

# ---------------------------------------------------------------- release

Y=$W/release.yml
ok "release: runs on a v* tag only" eq "$(sed -n '/^on:/,/^[a-z]/p' "$Y" | grep -vE '^(on:|[a-z].*|)$' | tr -d ' ' | tr '\n' '|')" "push:|tags:[\"v*\"]|"
ok "release: checks the tag against VERSION and CHANGELOG.md" grep -qF '.github/scripts/release check "$GITHUB_REF_NAME"' "$Y"
ok "release: runs the suite" grep -qE '^ +run: .*tests/run$' "$Y"
ok "release: builds the tarball and SHA256SUMS" grep -qF '.github/scripts/release build' "$Y"
ok "release: the changelog section is the notes" grep -qF '.github/scripts/release notes' "$Y"
ok "release: publishes with gh and the workflow token" grep -qF 'GH_TOKEN: ${{ github.token }}' "$Y"
# its run lines with their continuations joined
joined() { sed -e :a -e '/\\$/N; s/\\\n *//; ta' "$1"; }
ok "release: gh release create with the tarball, SHA256SUMS and the notes" \
  grep -qE 'gh release create "\$GITHUB_REF_NAME" "dist/canccu-dispatcher-\$v\.tar\.gz" dist/SHA256SUMS .*--notes-file dist/notes\.md' <(joined "$Y")
ok "release: only the publishing job may write the repo's contents" \
  eq "$(grep -c 'contents: write' "$Y") $(job "$Y" publish | grep -c 'contents: write')" "1 1"
ok "release: it publishes only after the check, suite and build" grep -qE '^    needs: \[?build' <(job "$Y" publish)

# ---------------------------------------------------------------- the review gate

ok "the review-gate workflow equals the template" cmp -s "$W/review-gate.yml" "$TR/workflows/review-gate.yml"
ok "the review-gate script equals the template" cmp -s .github/scripts/review-gate "$TR/scripts/review-gate"
ok "… both scripts are executable" eval '[ -x .github/scripts/review-gate ] && [ -x "$TR/scripts/review-gate" ]'
ok "the template's self-test passes" eval '"$TR/scripts/review-gate" --self-test > "$T/st" 2>&1'
ok "… and runs every case" eq "$(grep -c '^ok ' "$T/st") $(grep -c '^FAIL' "$T/st")" "$(grep -c '^ok ' "$T/st") 0"
ok "the gate workflow runs the self-test" grep -qF '.github/scripts/review-gate --self-test' "$TR/workflows/review-gate.yml"
ok "the gate's job keeps the required-check name review-gate" grep -qx '    name: review-gate' "$TR/workflows/review-gate.yml"
ok "templates/LICENSE is 0BSD" grep -q 'Zero-Clause BSD' templates/LICENSE
ok "the templates carry the 0BSD SPDX line" eq "$(grep -l 'SPDX-License-Identifier: 0BSD' "$TR/workflows/review-gate.yml" "$TR/scripts/review-gate" | wc -l)" 2
ok "the templates point at this tool's docs, not another repo's files" \
  eq "$(grep -cE 'docs/ci\.md|AGENTS\.md|package run' "$TR/workflows/review-gate.yml" "$TR/scripts/review-gate" | grep -vc ':0$')" 0
ok "… they name canccu-dispatcher's templates/README.md" eq "$(grep -l 'canccu-dispatcher.*templates/README\.md' "$TR/workflows/review-gate.yml" "$TR/scripts/review-gate" | wc -l)" 2
ok "templates/README.md exists" test -s templates/README.md
ok "the gate takes this tool's verdicts: pass or changes, nothing else" \
  grep -qF "VERDICT_RE='^Review verdict: (pass|changes) ([0-9a-f]{40})\$'" "$TR/scripts/review-gate"
ok "canccu-init's checklist points at the templates" grep -qF 'templates/repo/.github' bin/canccu-init
ok "… and no longer says they do not ship" not grep -q 'does not ship them' bin/canccu-init README.md

# ---------------------------------------------------------------- Dependabot

D=.github/dependabot.yml
ok "Dependabot: the GitHub Actions only" eq "$(grep -E 'package-ecosystem:' "$D" | tr -d ' ' | tr '\n' ' ')" "-package-ecosystem:github-actions "
ok "Dependabot: this repo's workflows and the template's" grep -qF 'directories: ["/", "/templates/repo"]' "$D"
ok "Dependabot: one PR per action for both, so they stay equal" grep -qE '^ +group-by: dependency-name$' "$D"

# ---------------------------------------------------------------- issue and PR templates

for t in feature bug idea; do
  f=.github/ISSUE_TEMPLATE/$t.md
  ok "issue template $t: front matter first" eq "$(head -n1 "$f" 2>/dev/null)" "---"
  for s in '## Goal' '## Acceptance criteria' '## Out of scope' 'Risk: '; do
    ok "issue template $t: $s" grep -q "^$s" "$f"
  done
done
f=.github/pull_request_template.md
for l in 'Closes #' 'Package: ' 'Risk: ' 'Tier: ' 'Decisions made:' 'Next action: ' 'Verification run: ' 'Follow-up: ' 'Roadmap note: '; do
  ok "PR template: $l" grep -q "^$l" "$f"
done
ok "PR template: the lines in AGENTS.md's order" eq "$(grep -oE '^(Closes|Package|Risk|Tier|Decisions made|Next action|Verification run|Follow-up|Roadmap note)' "$f" | tr '\n' '|')" \
  "Closes|Package|Risk|Tier|Decisions made|Next action|Verification run|Follow-up|Roadmap note|"

echo "canccu-ci tests: $npass passed, $nfail failed"
(( nfail == 0 ))
