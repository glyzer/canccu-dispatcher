#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-config.sh — no personal defaults: what the tools do while USER_LOGIN,
# REVIEWER_LOGIN or MODEL are unset (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# ---------------------------------------------------------------- the defaults

defaults=$( (CANCCU_ROOT=/nonexistent; . "$root/lib/canccu-config.default"; echo "[$USER_LOGIN] [$REVIEWER_LOGIN] [$MODEL]") 2>&1)
tname=defaults
ok "USER_LOGIN, REVIEWER_LOGIN and MODEL default to empty" eq "$defaults" "[] [] []"

# ---------------------------------------------------------------- USER_LOGIN unset

env_new no-user USER_LOGIN=
{ issue 3 ready; issue 5 in-progress; } | issues
printf '%s\n' "$(pr 50 5 "$HA")" | prs
state 5 phase=check "check_at=$NOW" pr=50
dispatch --once
ok "no USER_LOGIN: the dispatcher says which key is missing" grep -q 'USER_LOGIN is not set' "$E/out"
dispatch --once
ok "… once over two passes" eq "$(grep -c 'USER_LOGIN is not set' "$CANCCU_HOME/dispatch.log")" 1
ok "… starts nothing" eq "$(wc -l < "$FAKE/worker.log")" 0
ok "… writes nothing to GitHub" not grep -qE '^(issue (edit|comment|close)|pr (edit|merge|comment)|label create)' "$FAKE/gh.log"
ok "… the snapshot says so" grep -q 'USER_LOGIN is not set' <<<"$(jq -r .pass.error "$CANCCU_HOME/status.json")"
PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --dry-run > "$E/out" 2>&1; rc=$?
ok "no USER_LOGIN: --dry-run refuses, naming the key" eq "$rc $(grep -c 'USER_LOGIN is not set' "$E/out")" "1 1"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)
ok "no USER_LOGIN: canccu-status names the missing key" grep -q '^USER_LOGIN is not set' <<<"$out"
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-ship" 5 2>&1); rc=$?
ok "no USER_LOGIN: canccu-ship refuses, naming the key" eq "$rc $(grep -c 'USER_LOGIN is not set' <<<"$out")" "1 1"
ok "… and merges nothing" not grep -q '^pr merge' "$FAKE/gh.log"
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 50 2>&1); rc=$?
ok "no USER_LOGIN: canccu-review refuses, naming the key" eq "$rc $(grep -c 'USER_LOGIN is not set' <<<"$out")" "1 1"
ok "… and starts no reviewer" eq "$(wc -l < "$FAKE/worker.log")" 0

# ---------------------------------------------------------------- REVIEWER_LOGIN unset

env_new no-reviewer REVIEWER_LOGIN= PING_KINDS=all
{ issue 3 ready; issue 5 in-progress; issue 8 needs-you; } | issues
p=$(pr 50 5 "$HA"); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
state 5 phase=check "check_at=$NOW" pr=50
state 8 phase=needs-you
dispatch --once
ok "no REVIEWER_LOGIN: a worker still starts (it needs no reviewer)" started 3
ok "… no reviewer starts" not grep -q -- '--key review-50' "$FAKE/worker.log"
ok "… the dispatcher says which key is missing" grep -q 'REVIEWER_LOGIN is not set' "$CANCCU_HOME/dispatch.log"
ok "… nothing is posted as the reviewer (no review, no ping)" not grep -qP '^(issue|pr) comment\treviewer' "$FAKE/gh.env"
out=$(PATH="$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-review" 50 2>&1); rc=$?
ok "no REVIEWER_LOGIN: canccu-review refuses, naming the key" eq "$rc $(grep -c 'REVIEWER_LOGIN is not set' <<<"$out")" "1 1"
out=$(PATH="$fb:$PATH" "$root/bin/canccu-status" 2>&1)
ok "no REVIEWER_LOGIN: canccu-status names the missing key" grep -q 'REVIEWER_LOGIN is not set' <<<"$out"
ok "… and no reviewer login" grep -q '^model: the account default · reviews: REVIEWER_LOGIN is not set$' <<<"$out"

# ---------------------------------------------------------------- paths under $HOME, posted as ~/…

# every text the tool posts to GitHub shows a path under $HOME as ~/…: a needs-you that quotes a
# worker's report, a review that could not be posted (the token path), a ping, the digest
env_new home-paths "REVIEWER_TOKEN_FILE=/home/someone/.canccu/reviewer-token" PING_KINDS=all "DIGEST_HOUR_UTC=0"
{ issue 5 in-progress; issue 6 in-progress; } | issues
p=$(pr 50 6 "$HA"); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
state 5 phase=work "started=$NOW"
last 5 "crashed (exit 1)" "cannot read /home/someone/code/web/notes.txt; see /home/someone"
state 6 phase=review pr=50 review_sha=$HA "started=$NOW" rounds=0
last review-50 done "wrote the review"
RF=$CANCCU_HOME/reviews/50/$HA.md; mkdir -p "${RF%/*}"
printf '1. /home/someone/code/web/src/a.ts:3 off by one\n\nReview verdict: changes %s\n' "$HA" > "$RF"; touch -d "@$((NOW + 60))" "$RF"
HOME=/home/someone dispatch --once
ok "HOME=/home/someone: the needs-you comment quotes the report with ~/" has gh.log "cannot read ~/code/web/notes.txt; see ~"
ok "… the review-post failure names the token file as ~/" has gh.log "no reviewer token file (~/.canccu/reviewer-token)"
ok "… no posted text contains /home/" hasnt gh.log "/home/"
ok "… nor a posted body" eq "$(cat "$FAKE"/posted-* 2>/dev/null | grep -c /home/)" 0
# a posted review body: the token works, the reviewer cited an absolute path anyway
env_new home-review
{ issue 6 in-progress; } | issues
p=$(pr 50 6 "$HA"); printf '%s\n' "$p" | prs
json pr50.json "$(detail "$p" 2030-11-05T10:00:00Z)"; route 'pr view 50 *' pr50.json
json files50.json '[{"filename": "src/a.ts"}]'; route 'api --paginate repos/example-org/web/pulls/50/files*' files50.json
state 6 phase=review pr=50 review_sha=$HA "started=$NOW" rounds=0
last review-50 done "wrote the review"
RF=$CANCCU_HOME/reviews/50/$HA.md; mkdir -p "${RF%/*}"
printf '1. /home/someone/code/web/src/a.ts:3 off by one\n\nReview verdict: changes %s\n' "$HA" > "$RF"; touch -d "@$((NOW + 60))" "$RF"
HOME=/home/someone dispatch --once
# shellcheck disable=SC2088  # a literal ~ is what the posted text holds
ok "HOME=/home/someone: a posted review shows ~/" grep -qF '~/code/web/src/a.ts:3' "$FAKE/posted-50"
ok "… and no /home/" not grep -q /home/ "$FAKE/posted-50" "$FAKE/gh.log"
ok "canccu_tilde: only a whole leading \$HOME becomes ~" \
  eq "$(lib eval 'HOME=/home/someone; canccu_tilde /home/someone/x; echo; canccu_tilde /home/someoneelse/x; echo; canccu_tilde /home/someone')" $'~/x\n/home/someoneelse/x\n~'
ok "the reviewer prompt asks for paths relative to the repo root" grep -qF 'cite every file as a path relative to the repo root' <<<"$(lib review_prompt 50 5 x f high)"
ok "… the fix-check prompt too" grep -qF 'cite every file as a path relative to the repo root' <<<"$(lib fixcheck_prompt 50 5 a b f low "")"

# ---------------------------------------------------------------- messages point at this tool

tname=pointers
# install.sh is this repo's own installer; the old one's --canccu mode is another repo's
ok "no message points at another repo's installer, project or docs" \
  eq "$(grep -rnE '(echo|die|log|warn_once|exit|Text\().*(install\.sh --canccu|docs/canccu|profiles/ in the)' "$root/bin" "$root/libexec" "$root/lib" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')" ""
ok "… the install.sh the messages name is this repo's" test -x "$root/install.sh"

# ---------------------------------------------------------------- a changed config applies next pass

# loopenv <name> [config...]: step "3 Events" at its budget ($5.50 spent, STEP_BUDGET=5): its
# planner is held. INTERVAL=7 marks the loop's sleep; the fake sleep runs $E/between <n> after
# pass n and stops the dispatcher once it fails.
loopenv() {
  env_new "$@" STEP_BUDGET=5 INTERVAL=7
  jq -nc '[{number: 12, title: "3 Events", open_issues: 0, closed_issues: 0, due_on: null}]' > "$FAKE/ms.json"
  json c90.json '{"comments": []}'; route 'issue view 90 *' c90.json; route 'api -X PATCH *' empty.json
  { issue 90 epic "" "3 Events"; issue 101 ready "" "3 Events"; } | issues
  mkdir -p "$CANCCU_HOME/steps" "$E/sbin"
  printf 'phase=idle\nstarted_at=%s\nwave=0\n' "$((NOW - 3600))" > "$CANCCU_HOME/steps/12"
  printf 'plan-12\n' > "$CANCCU_HOME/steps/12.keys"
  printf '%s\tweb\tplan-12\t5.50\n' "$((NOW - 100))" > "$WORKERS_DIR/spend.log"
  cat > "$E/sbin/sleep" <<SH
#!/usr/bin/env bash
[ "\$1" = 7 ] || exec $(command -v sleep) "\$@"
n=\$(( \$(cat "$E/sleeps" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$E/sleeps"
"$E/between" "\$n" || kill "\$PPID"
SH
  chmod +x "$E/sbin/sleep"
}
loop() { PATH="$E/sbin:$fb:$PATH" CANCCU_WORKER="$fb/worker" timeout 60 "$root/bin/canccu-dispatch" > "$E/out" 2>&1; }
plans() { grep -c -- '--key plan-12' "$FAKE/worker.log"; }

for where in config root rules; do
  loopenv "reload-$where"
  case $where in
    config) f=$CANCCU_HOME/config ;; root) f=$CANCCU_ROOT/config ;; rules) f=$CANCCU_HOME/rules ;;
  esac
  # the project's config sets STEP_BUDGET=5 and is read last: the other two files raise it there
  [ "$where" = config ] || sed -i '/^STEP_BUDGET=/d' "$CANCCU_HOME/config"
  [ "$where" = root ] && echo STEP_BUDGET=5 > "$f"
  [ "$where" = rules ] && echo STEP_BUDGET=5 >> "$f"
  printf '#!/usr/bin/env bash\n[ "$1" = 1 ] || exit 1\nprintf "STEP_BUDGET=50\\n" >> "%s"; touch -d "@$(( $(stat -c %%Y "%s") + 10 ))" "%s"\n' "$f" "$f" "$f" > "$E/between"
  chmod +x "$E/between"
  loop
  ok "STEP_BUDGET raised in the $where file between two passes of one dispatcher: the held planner starts in the second" \
    eq "$(plans) $(cat "$E/sleeps")" "1 2"
  ok "… the log says the config was read again, once" eq "$(grep -c 'config read again' "$CANCCU_HOME/dispatch.log")" 1
done

loopenv reload-none
printf '#!/usr/bin/env bash\n[ "$1" -lt 2 ]\n' > "$E/between"; chmod +x "$E/between"
loop
ok "no file changed: the config is not read again" eq "$(grep -c 'config read again' "$CANCCU_HOME/dispatch.log") $(plans) $(cat "$E/sleeps")" "0 0 2"

loopenv reload-syntax
cat > "$E/between" <<SH
#!/usr/bin/env bash
case \$1 in
  1) printf 'STEP_BUDGET=50\nif then\n' >> "$CANCCU_HOME/config"; touch -d "@\$(( \$(stat -c %Y "$CANCCU_HOME/config") + 10 ))" "$CANCCU_HOME/config" ;;
  2) grep -c -- '--key plan-12' "$FAKE/worker.log" > "$E/plans-2"
     sed -i '/^if then\$/d' "$CANCCU_HOME/config"; touch -d "@\$(( \$(stat -c %Y "$CANCCU_HOME/config") + 10 ))" "$CANCCU_HOME/config" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$E/between"
loop
ok "a syntax error in the config: one warning, the old values stay, the pass still runs" \
  eq "$(grep -c 'config: syntax error; the dispatcher keeps the values it has' "$CANCCU_HOME/dispatch.log") $(cat "$E/plans-2") $(grep -c 'the pass ended early' "$CANCCU_HOME/dispatch.log")" "1 0 0"
ok "… once corrected, the new values apply" eq "$(plans) $(cat "$E/sleeps")" "1 3"

loopenv reload-repo
cat > "$E/between" <<SH
#!/usr/bin/env bash
[ "\$1" = 1 ] && { echo REPO=example-org/other >> "$CANCCU_HOME/config"; touch -d "@\$(( \$(stat -c %Y "$CANCCU_HOME/config") + 10 ))" "$CANCCU_HOME/config"; }
[ "\$1" = 2 ] && { echo STEP_BUDGET=50 >> "$CANCCU_HOME/config"; touch -d "@\$(( \$(stat -c %Y "$CANCCU_HOME/config") + 20 ))" "$CANCCU_HOME/config"; }
[ "\$1" -lt 3 ]
SH
chmod +x "$E/between"
loop
ok "REPO changed in the config: the restart warning is logged once" \
  eq "$(grep -c 'REPO changed in the config: restart the dispatcher to apply it' "$CANCCU_HOME/dispatch.log")" 1
ok "… the old REPO stays: no call on the new one, and the other values apply" \
  eq "$(grep -c 'example-org/other' "$FAKE/gh.log") $(plans)" "0 1"

# ---------------------------------------------------------------- the settings table

tname=settings-table
TSV=$root/lib/canccu-settings.tsv
ok "the table has one line per key the defaults assign, in their order" \
  eq "$(grep -v '^#' "$TSV" | cut -f1)" "$(grep -oE '^[A-Z_]+=' "$root/lib/canccu-config.default" | tr -d =)"
ok "… every line has four columns" eq "$(grep -v '^#' "$TSV" | awk -F'\t' 'NF != 4' | wc -l)" 0
types='^(int|intopt):[0-9]+:[0-9]+$|^(enum|words):[^|]*(\|[^|]*)*$|^(budget|regex|date|name|text)$'
ok "… a type of the list" eq "$(grep -v '^#' "$TSV" | cut -f2 | grep -cvE "$types")" 0
ok "… a file of the list" eq "$(grep -v '^#' "$TSV" | cut -f3 | grep -cvxE 'project|rules|global|fixed')" 0
ok "… locked or open" eq "$(grep -v '^#' "$TSV" | cut -f4 | grep -cvxE 'locked|open')" 0

# ---------------------------------------------------------------- config show

# cfgenv <name> <global config or -> <rules> [project config]: a root with project web
cfgenv() {
  tname=$1; E=$T/$1; unset CANCCU_PROJECT CANCCU_HOME CANCCU_HOST_PROFILE
  export CANCCU_ROOT=$E/root; mkdir -p "$CANCCU_ROOT/projects/web"
  [ "$2" = - ] || printf '%s\n' "$2" > "$CANCCU_ROOT/config"
  printf '%s\n' "$3" > "$CANCCU_ROOT/projects/web/rules"
  printf '%s\n' "REPO=example-org/web" "CLONE=$E/code/web" "${4:-}" > "$CANCCU_ROOT/projects/web/config"
}
show() { out=$("${CFG_BIN:-$root/bin/canccu-dispatcher}" config show "$@" 2>&1); rc=$?; }
H=$'KEY\tVALUE\tDEFAULT\tORIGIN\tLOCKED'

cfgenv show-origin CAP=2 "GATED_PATHS='^x/'" CAP=1
show --origin CAP GATED_PATHS STALL_MIN
ok "config show --origin: the header, then value, default, origin and locked, in the table's order" eq "$rc
$out" "0
$H
CAP	1	3	project	
STALL_MIN	10	10	default	
GATED_PATHS	^x/	^\.github/	rules	locked"
show CAP REPO
ok "config show: KEY=value lines" eq "$out" "REPO=example-org/web
CAP=1"
show --project web
ok "config show: every setting" eq "$rc $(grep -c . <<<"$out")" "0 $(grep -vc '^#' "$TSV")"

cfgenv total-cap "TOTAL_CAP=4" "" "TOTAL_CAP=9"
show --origin TOTAL_CAP
ok "TOTAL_CAP in a project config does not show: the global layer's value and origin" eq "$out" "$H
TOTAL_CAP	4	3	global	"

cfgenv host HOST_PROFILE=max ""
# the shipped max.conf pins today's defaults (no value differs): a copy sets one that does
src_copy "$E/src"; sed -i 's/^CAP=3$/CAP=4/' "$E/src/hosts/max.conf"
CFG_BIN=$E/src/bin/canccu-dispatcher show --origin CAP HOST_PROFILE
ok "HOST_PROFILE=max: a key max.conf sets comes from host:max; HOST_PROFILE from global" eq "$out" "$H
HOST_PROFILE	max		global	
CAP	4	3	host:max	"

cfgenv unknown - ""
show NOPE
ok "config show NOPE: status 2, unknown setting" eq "$rc $out" "2 canccu-dispatcher: unknown setting NOPE"
mkdir -p "$CANCCU_ROOT/projects/tools"; printf 'REPO=example-user/tools\n' > "$CANCCU_ROOT/projects/tools/config"
show CAP
ok "two projects and no --project: status 2, name a project" eq "$rc $out" "2 canccu-dispatcher: name a project: --project <name> (Projects: tools web)"
show --project nope CAP
ok "an unknown project ends as doctor does" eq "$rc $out" "1 canccu-dispatcher: no project 'nope'. Projects: tools web"
rm -rf "$CANCCU_ROOT/projects"
show --global --origin CAP REPO
ok "--global: no project needed, the first three layers only" eq "$rc $out" "0 $H
REPO			default	
CAP	3	3	default	"

cfgenv canary - "" "REVIEWER_TOKEN_FILE=$T/canary/token" "GH_CONFIG_DIR=$T/canary/gh"
mkdir -p "$T/canary/gh"; echo SECRET-CANARY > "$T/canary/token"; echo SECRET-CANARY > "$T/canary/gh/hosts.yml"
show --origin
ok "config show --origin prints the token file's path, never its content" eq "$(grep -c SECRET-CANARY <<<"$out") $(grep -c "^REVIEWER_TOKEN_FILE	$T/canary/token	" <<<"$out")" "0 1"

echo "canccu-config tests: $npass passed, $nfail failed"
(( nfail == 0 ))
