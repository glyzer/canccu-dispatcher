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
     m=\$(stat -c %Y "$CANCCU_HOME/config")  # sed -i resets the mtime: two passes in one second would match
     sed -i '/^if then\$/d' "$CANCCU_HOME/config"; touch -d "@\$(( m + 10 ))" "$CANCCU_HOME/config" ;;
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
ok "FIXCHECK_FULL_LINES is in the table, locked (#91)" grep -qxP 'FIXCHECK_FULL_LINES\tint:[0-9]+:[0-9]+\tproject\tlocked' "$TSV"
ok "… default 100" grep -qE '^FIXCHECK_FULL_LINES=100( |$)' "$root/lib/canccu-config.default"

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

# ---------------------------------------------------------------- cfg_check and cfg_actor

tname=cfg-check
chk() { bash -c '. "$1/lib/canccu-configcmd.sh"; cfg_check "$2" "$3"' _ "$root" "$1" "$2"; }
ok "every default value passes cfg_check for its key" eq "$(bash -c '. "$1/lib/canccu-configcmd.sh"; CANCCU_ROOT=/nonexistent
  . "$1/lib/canccu-config.default"; for k in $(cfg_keys); do cfg_check "$k" "${!k-}" || echo "($k)"; done' _ "$root")" ""
while IFS='|' read -r k v want; do
  out=$(chk "$k" "$v"); rc=$?
  ok "cfg_check $k=$v fails: $want" eq "$rc $out" "1 $want"
done <<'CHK'
CAP|0|CAP must be a whole number from 1 to 20
CAP|x|CAP must be a whole number from 1 to 20
CAP|08|CAP must be a whole number from 1 to 20
DIGEST_ISSUE|x|DIGEST_ISSUE must be a whole number from 1 to 9999999, or empty
PING|maybe|PING must be one of: on, off
FIX_EFFORT|huge|FIX_EFFORT must be one of: low, medium, high, xhigh, max, empty
BUDGET_WORK|10 2|BUDGET_WORK must be three whole numbers: turns, USD, minutes (for example "120 25 120")
BUDGET_WORK|120 25 090|BUDGET_WORK must be three whole numbers: turns, USD, minutes (for example "120 25 120")
GATED_PATHS|(|GATED_PATHS is not a pattern grep -E accepts
RESUME_ON|answer,nope|RESUME_ON may only hold: answer, plan, fix, ci, needs-work, merge, limited, blocked, user, all
AUTO_MERGE_UNTIL|2026-13-01|AUTO_MERGE_UNTIL must be a date as YYYY-MM-DD, or empty
MODEL|a b|MODEL may only hold letters, digits and . _ : / [ ] -
CHK
# alternatives joined by | are none of them: the table's separator is refused in a value
while read -r k v want; do
  out=$(chk "$k" "$v"); rc=$?
  ok "cfg_check $k=$v fails" eq "$rc $out" "1 $want"
done <<'CHK'
PING on|off PING must be one of: on, off
FIX_EFFORT low|high FIX_EFFORT must be one of: low, medium, high, xhigh, max, empty
FIX_EFFORT max| FIX_EFFORT must be one of: low, medium, high, xhigh, max, empty
RESUME_ON answer|plan RESUME_ON may only hold: answer, plan, fix, ci, needs-work, merge, limited, blocked, user, all
CHK
out=$(chk WORKER_EXTRA $'a\tb'); rc=$?
ok "cfg_check: a tab fails for every type" eq "$rc $out" "1 WORKER_EXTRA must be one line without tabs"
out=$(chk CAP $'2\n3'); rc=$?
ok "… a newline too" eq "$rc $out" "1 CAP must be one line without tabs"
while IFS='|' read -r k v; do
  ok "cfg_check $k=$v passes" eq "$(chk "$k" "$v"; echo "rc=$?")" "rc=0"
done <<'CHK'
CAP|20
DIGEST_ISSUE|
PING|off
FIX_EFFORT|
BUDGET_WORK|120 25 120
GATED_PATHS|^x/
RESUME_ON|answer,plan
PING_KINDS|accept plan
AUTO_MERGE_UNTIL|2030-02-28
MODEL|claude-opus-5-5[1m]
WORKER_EXTRA|it's fine
CHK
act() { (CANCCU_ACTOR=$1; [ "$1" = - ] && unset CANCCU_ACTOR; . "$root/lib/canccu-configcmd.sh"; cfg_actor); }
ok "cfg_actor: leader, run, and po for anything else" eq "$(act leader) $(act run) $(act -) $(act '') $(act Leader)" "leader run po po po"

# ---------------------------------------------------------------- config set and unset

cs() { out=$("$root/bin/canccu-dispatcher" config "$@" 2>&1); rc=$?; }
hist() { cat "$CANCCU_ROOT/projects/web/config.history" 2>/dev/null; }
cfgenv set-place - "WORKER_EXTRA=''" $'CAP=3\n# CAP=3\nMODEL=x'
P=$CANCCU_ROOT/projects/web; chmod 640 "$P/config"
cs set CAP=2
ok "config set CAP=2: the new line in the old one's place, the comment kept, the rest unchanged" eq "$(cat "$P/config")" "REPO=example-org/web
CLONE=$E/code/web
CAP='2'
# CAP=3
MODEL=x"
ok "… the mode unchanged" eq "$(stat -c %a "$P/config")" 640
ok "… it says where, when, and what the value is now" eq "$rc
$out" "0
CAP=2 written to $P/config; it applies at the dispatcher's next pass
now: 2 (from project)"
ok "… no temporary file left" eq "$(find "$P" -maxdepth 1 -name '.*' | wc -l)" 0
cs set STALL_MIN=15
ok "config set STALL_MIN=15 with no such line: the last line" eq "$(tail -1 "$P/config")" "STALL_MIN='15'"
cs set "WORKER_EXTRA=it's fine"
ok "config set WORKER_EXTRA=\"it's fine\": the rules file gives it back" eq "$rc $(. "$P/rules"; printf %s "$WORKER_EXTRA")" "0 it's fine"
cs set 'GATED_PATHS=^x/'
ok "GATED_PATHS goes to the project's rules" grep -qxF "GATED_PATHS='^x/'" "$P/rules"
ok "… not to its config" not grep -q GATED_PATHS "$P/config"
cs set --global CAP=2
ok "--global CAP=2: a new \$CANCCU_ROOT/config, mode 600" eq "$rc $(cat "$CANCCU_ROOT/config") $(stat -c %a "$CANCCU_ROOT/config")" "0 CAP='2' 600"
ok "… its history in \$CANCCU_ROOT/config.history" eq "$(cut -f3-6 "$CANCCU_ROOT/config.history")" "set	CAP	-	2"
ok "… the project's config still says 2" grep -qxF "CAP='2'" "$P/config"
cs set TOTAL_CAP=2
ok "TOTAL_CAP without --global: status 2, is global" eq "$rc $out" "2 canccu-dispatcher: TOTAL_CAP is global: use --global"
cs set REPO=a/b
ok "REPO: status 2, not changed with this command" eq "$rc $out" "2 canccu-dispatcher: REPO is not changed with this command: edit the config file by hand and restart the dispatcher"
cs set NOPE=1
ok "an unknown key: status 2" eq "$rc $out" "2 canccu-dispatcher: unknown setting NOPE"
cp "$P/config" "$E/before"; n=$(hist | wc -l)
cs set CAP=0
ok "a value out of range: status 2, the check's line, nothing written" eq "$rc $out $(cmp -s "$P/config" "$E/before"; echo $?) $(hist | wc -l)" "2 canccu-dispatcher: CAP must be a whole number from 1 to 20 0 $n"
HOME=$CANCCU_ROOT cs set CAP=4
ok "the path is shown with ~ for \$HOME" eq "$(head -1 <<<"$out")" "CAP=4 written to ~/projects/web/config; it applies at the dispatcher's next pass"

cfgenv set-locked - "GATED_PATHS='^\.github/'"
P=$CANCCU_ROOT/projects/web; cp "$P/rules" "$E/before"
for a in leader run; do
  out=$(CANCCU_ACTOR=$a "$root/bin/canccu-dispatcher" config set 'GATED_PATHS=^x/' 2>&1); rc=$?
  ok "CANCCU_ACTOR=$a config set GATED_PATHS: status 3, refused, the file unchanged" \
    eq "$rc $out $(cmp -s "$P/rules" "$E/before"; echo $?)" "3 canccu-dispatcher: refused: GATED_PATHS is locked; only the product owner changes it 0"
  ok "… one history line: $a refused" eq "$(hist | tail -1 | cut -f2-6)" "$a	refused	GATED_PATHS	^\.github/	^x/"
done
ok "… two lines in all" eq "$(hist | wc -l)" 2
out=$(CANCCU_ACTOR=run "$root/bin/canccu-dispatcher" config unset GATED_PATHS 2>&1); rc=$?
ok "a run's unset of a locked key is refused too" eq "$rc $(hist | tail -1 | cut -f2-6)" "3 run	refused	GATED_PATHS	^\.github/	-"
cs set 'GATED_PATHS=^x/'
ok "without CANCCU_ACTOR the product owner writes it" eq "$rc $(grep -c "^GATED_PATHS='^x/'$" "$P/rules") $(hist | tail -1 | cut -f2,3)" "0 1 po	set"
out=$(CANCCU_ACTOR=leader "$root/bin/canccu-dispatcher" config set CAP=2 2>&1); rc=$?
ok "CANCCU_ACTOR=leader config set CAP=2 (open): written, the history says leader" eq "$rc $(grep -c "^CAP='2'$" "$P/config") $(hist | tail -1 | cut -f2,3)" "0 1 leader	set"

cfgenv set-history - "" CAP=3
P=$CANCCU_ROOT/projects/web
cs set CAP=2 --why "less load"
ok "the history line: seven columns, UTC time, actor, set, key, old, new, why" \
  eq "$(hist | awk -F'\t' '{print NF}') $(hist | cut -f1 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') $(hist | cut -f2-7)" \
  "7 1 po	set	CAP	3	2	less load"
ok "… config.history has mode 600" eq "$(stat -c %a "$P/config.history")" 600
cs set CAP=2
ok "a second identical set: is already, no history line" eq "$rc $out $(hist | wc -l)" "0 CAP is already 2 in $P/config 1"
cs set STALL_MIN=12 --why $'a\tb\nc'
ok "no old value: -; tabs and newlines in --why become spaces" eq "$(hist | tail -1 | cut -f3-7)" "set	STALL_MIN	-	12	a b c"
cs set MODEL=m
ok "no --why: -" eq "$(hist | tail -1 | cut -f7)" "-"
printf '# CAP=3\n' >> "$P/config"
cs unset CAP
ok "config unset CAP: the line goes, the comment stays" eq "$rc $(grep -c '^CAP=' "$P/config") $(grep -c '^# CAP=3$' "$P/config")" "0 0 1"
ok "… it says so and what the value is now" eq "$out" "CAP removed from $P/config; it applies at the dispatcher's next pass
now: 3 (from default)"
ok "… a history line with unset" eq "$(hist | tail -1 | cut -f3-7)" "unset	CAP	2	-	-"
n=$(hist | wc -l); cs unset CAP
ok "a second unset: is not set, no history line" eq "$rc $out $(hist | wc -l)" "0 CAP is not set in $P/config $n"

cfgenv set-later - "" CAP=1
cs set --global CAP=2
ok "config set --global CAP=2 under a project's CAP=1: the output ends with now: 1 (from project)" eq "$(tail -1 <<<"$out")" "now: 1 (from project)"

cfgenv set-invalid - "" 'if then'
P=$CANCCU_ROOT/projects/web; cp "$P/config" "$E/before"
cs set CAP=2
ok "a target that would not be valid shell: status 1, nothing changed" \
  eq "$rc $out $(cmp -s "$P/config" "$E/before"; echo $?) $(find "$P" -maxdepth 1 -name '.*' | wc -l)" \
  "1 canccu-dispatcher: $P/config would not be valid shell; nothing changed 0 0"

cs; ok "config alone: the usage, status 2" eq "$rc $(grep -c 'config set' <<<"$out")" "2 1"
cs nope; ok "config nope: the usage, status 2" eq "$rc $(grep -c 'config unset' <<<"$out")" "2 1"

# ---------------------------------------------------------------- config set between two passes

loopenv reload-set
cat > "$E/between" <<SH
#!/usr/bin/env bash
[ "\$1" = 1 ] || exit 1
jq -r .caps.cap "$CANCCU_HOME/status.json" > "$E/cap-1"
"$root/bin/canccu-dispatcher" config set CAP=1 > "$E/set.out" 2>&1
touch -d "@\$(( \$(stat -c %Y "$CANCCU_HOME/config") + 10 ))" "$CANCCU_HOME/config"
SH
chmod +x "$E/between"
loop
ok "config set CAP=1 between two passes of one dispatcher: the second pass runs with CAP=1" \
  eq "$(cat "$E/cap-1") $(jq -r .caps.cap "$CANCCU_HOME/status.json") $(cat "$E/sleeps")" "3 1 2"

echo "canccu-config tests: $npass passed, $nfail failed"
(( nfail == 0 ))
