# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # its globals are used by the parts it sources
# Shared by the canccu-* scripts (canccu-dispatch and friends). Sourced, never run. docs/canccu-dispatch.md
# is the spec. Every GitHub read goes through ghj, every write (GitHub, git, the run engine)
# through mut, which only prints under --dry-run (CANCCU_DRY=1).

_canccu_lib=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=canccu-version.sh
. "$_canccu_lib/canccu-version.sh"
CANCCU_VERSION=$(canccu_version "$_canccu_lib/..")
# ---------------------------------------------------------------- the project (profile)
# shellcheck source=canccu-projects.sh
. "$_canccu_lib/canccu-projects.sh"
_canccu_die() { echo "$(basename "$0"): $*" >&2; exit 1; }
# The calling command's leading --project <name> (or --project=<name>) picks the project; it is
# taken off the command's arguments (a sourced file shifts its caller's). Else CANCCU_PROJECT,
# else default-project, else the only project; otherwise refuse with the list.
while :; do
  case ${1:-} in
    --project) [ $# -ge 2 ] || _canccu_die "--project needs a name"; CANCCU_PROJECT=$2; shift 2 ;;
    --project=*) CANCCU_PROJECT=${1#--project=}; shift ;;
    *) break ;;
  esac
done
_canccu_list=$(canccu_profiles | tr '\n' ' '); _canccu_list=${_canccu_list% }
if [ -z "${CANCCU_PROJECT:-}" ]; then
  CANCCU_PROJECT=$(canccu_default_profile)
  if [ -z "$CANCCU_PROJECT" ]; then
    [ -n "$_canccu_list" ] || _canccu_die "no project in ${CANCCU_ROOT/#$HOME/\~}/projects: canccu-init <name> <owner/repo> creates one"
    _canccu_die "several projects and no ${CANCCU_ROOT/#$HOME/\~}/default-project: pick one with --project <name> (or CANCCU_PROJECT). Projects: $_canccu_list"
  fi
fi
canccu_valid_name "$CANCCU_PROJECT" || _canccu_die "'$CANCCU_PROJECT' is no project name (a-z, 0-9, - and _). Projects: ${_canccu_list:-none}"
[ -f "$CANCCU_ROOT/projects/$CANCCU_PROJECT/config" ] ||
  _canccu_die "no project '$CANCCU_PROJECT' (${CANCCU_ROOT/#$HOME/\~}/projects/$CANCCU_PROJECT/config). Projects: ${_canccu_list:-none}"
CANCCU_HOME=$CANCCU_ROOT/projects/$CANCCU_PROJECT
[ -f "$CANCCU_HOME/rules" ] ||
  _canccu_die "project '$CANCCU_PROJECT' has no rules file (${CANCCU_HOME/#$HOME/\~}/rules); copy $(canccu_tilde "$(realpath -m "$_canccu_lib/..")")/profiles/default/rules there"
# GH_CONFIG_DIR is a project key (the project's own gh login): what the caller's environment
# held is put aside, and only the config files below can set it
_canccu_env_ghdir=${GH_CONFIG_DIR-} _canccu_env_ghdir_set=${GH_CONFIG_DIR+x} _canccu_env_owner=${CANCCU_GH_OWNER:-}
unset GH_CONFIG_DIR CANCCU_GH_OWNER
# the load order: the defaults, the host profile, ~/.canccu/config, the project's rules, its
# config. HOST_PROFILE is fixed before any of them: neither a profile nor a later file changes it.
_canccu_hp=$(canccu_host_profile) _canccu_hpf=""
if [ -n "$_canccu_hp" ]; then
  _canccu_hpf=$(canccu_host_conf "$_canccu_hp") ||
    _canccu_die "no host profile '$_canccu_hp' ($(canccu_host_where)). Profiles: $(canccu_host_profiles)"
fi
# shellcheck source=canccu-config.default
. "$_canccu_lib/canccu-config.default"
# shellcheck source=/dev/null
[ -n "$_canccu_hpf" ] && . "$_canccu_hpf"
# shellcheck source=/dev/null
[ -f "$CANCCU_ROOT/config" ] && . "$CANCCU_ROOT/config"
_canccu_total=$TOTAL_CAP   # global only: a project cannot raise it
# shellcheck source=/dev/null
. "$CANCCU_HOME/rules"
# shellcheck source=/dev/null
. "$CANCCU_HOME/config"
TOTAL_CAP=$_canccu_total HOST_PROFILE=$_canccu_hp
[ -n "$REPO" ] && [ -n "$CLONE" ] || _canccu_die "project '$CANCCU_PROJECT': REPO and CLONE must be set in ${CANCCU_HOME/#$HOME/\~}/config"

# ---------------------------------------------------------------- the project's gh credential
# docs/canccu-dispatch.md, "A narrow token per project". CANCCU_GH_DIR: the gh config dir this
# project's gh and git calls use, logged in with its own fine-grained token: GH_CONFIG_DIR from
# its config, else ~/.canccu/projects/<name>/gh when that dir exists. It is exported, so every
# gh call of this process and of every run it starts (through the engine and tmux_env) uses it,
# and git reaches GitHub through gh's credential helper for it. Empty: no config dir, today's
# default gh login (canccu-status warns).
# canccu_git_via_gh: git's GitHub credential is gh's for GH_CONFIG_DIR, whatever helper the
# user's git config names (the empty value resets that list), and an ssh remote of github.com
# goes over https, so a push uses the project's token too. Through git's environment config
# (GIT_CONFIG_COUNT/KEY_n/VALUE_n, after what is there), never a config file. The entries are
# known by key and value (CANCCU_GIT_KV): canccu_git_strip takes them out again, so they are
# added once and never outlive the project that set them.
CANCCU_GIT_KV='credential.https://github.com.helper=
credential.https://github.com.helper=!gh auth git-credential
url.https://github.com/.insteadOf=git@github.com:
url.https://github.com/.insteadOf=ssh://git@github.com/'
canccu_git_strip() {
  local n=${GIT_CONFIG_COUNT:-0} i k v keys=() vals=()
  [[ $n =~ ^[0-9]+$ ]] || n=0
  for ((i = 0; i < n; i++)); do
    k=GIT_CONFIG_KEY_$i v=GIT_CONFIG_VALUE_$i
    grep -qxF -- "${!k:-}=${!v:-}" <<<"$CANCCU_GIT_KV" || { keys+=("${!k:-}"); vals+=("${!v:-}"); }
    unset "$k" "$v"
  done
  for ((i = 0; i < ${#keys[@]}; i++)); do export "GIT_CONFIG_KEY_$i=${keys[i]}" "GIT_CONFIG_VALUE_$i=${vals[i]}"; done
  if (( ${#keys[@]} )); then export GIT_CONFIG_COUNT=${#keys[@]}; else unset GIT_CONFIG_COUNT; fi
}
canccu_git_via_gh() {
  local n kv
  canccu_git_strip; n=${GIT_CONFIG_COUNT:-0}
  while IFS= read -r kv; do
    export "GIT_CONFIG_KEY_$n=${kv%%=*}" "GIT_CONFIG_VALUE_$n=${kv#*=}"; n=$((n + 1))
  done <<<"$CANCCU_GIT_KV"
  export GIT_CONFIG_COUNT=$n
}
# CANCCU_GH_OWNER marks GH_CONFIG_DIR and the git entries as a canccu project's: it travels with
# them (tmux_env, canccu-up), so a project that inherits another one's drops them, wherever
# that dir lives.
CANCCU_GH_DIR=${GH_CONFIG_DIR:-}
[ -z "$CANCCU_GH_DIR" ] && [ -d "$CANCCU_HOME/gh" ] && CANCCU_GH_DIR=$CANCCU_HOME/gh
if [ -n "$CANCCU_GH_DIR" ]; then
  export GH_CONFIG_DIR=$CANCCU_GH_DIR CANCCU_GH_OWNER=$CANCCU_PROJECT
  # a token in the environment would win over the config dir (the reviewer's is set per call)
  unset GH_TOKEN GITHUB_TOKEN
  canccu_git_via_gh
else
  unset GH_CONFIG_DIR
  # today's default login. What a canccu project set (marked by its owner, or a dir under
  # projects/: a tmux server another project's dispatcher started) is never this project's:
  # its dir and its git entries go; a GH_CONFIG_DIR of the user's own stays.
  if [ -n "$_canccu_env_owner" ] || [[ $_canccu_env_ghdir == "$CANCCU_ROOT"/projects/* ]]; then canccu_git_strip
  elif [ -n "$_canccu_env_ghdir_set" ]; then export GH_CONFIG_DIR=$_canccu_env_ghdir; fi
fi
# the engine resolves the repo by folder name under CODE_ROOT
TMUX_SESSION=$(canccu_session "$CANCCU_PROJECT")
export CANCCU_HOME WORKERS_DIR="$CANCCU_HOME/workers" TMUX_SESSION CODE_ROOT
CODE_ROOT=$(dirname "$CLONE")
# shellcheck source=canccu-engine.sh
. "$_canccu_lib/canccu-engine.sh"

CANCCU_WORKER=${CANCCU_WORKER:-$_canccu_lib/../libexec/canccu-worker}
CANCCU_DRY=${CANCCU_DRY:-0}
CANCCU_MARK='<!-- canccu-dispatch -->'
REPO_NAME=$(basename "$CLONE")
DRY_STARTED=0

now() { echo "${CANCCU_NOW:-$(date +%s)}"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# iso_epoch <ISO time>: its epoch; nothing for an empty or unreadable time (date -d "" is today)
iso_epoch() { [ -n "$1" ] && date -u -d "$1" +%s 2>/dev/null; return 0; }
# newest_of <epoch...>: the largest of the non-empty ones; nothing when all are empty
newest_of() { printf '%s\n' "$@" | grep -E '^[0-9]+$' | sort -n | tail -1; }
jqr() { guard 20 jq -r "$@"; }
ghj() { guard 30 gh "$@"; }

# log <text>: a line with the time, to stdout and dispatch.log. On a terminal (and without
# NO_COLOR) the leading #<n> has the issue's colour, and needs-you lines are red, waiting lines
# yellow, merges green; the file always gets the plain line.
log() {
  local line; line="$(date -d "@$(now)" '+%F %T') $*"
  if colour_on; then colour_line "$line"; else echo "$line"; fi
  (( CANCCU_DRY )) || echo "$line" >> "$CANCCU_HOME/dispatch.log"
}
# colour_on: stdout takes colour (CANCCU_FORCE_COLOR=1 is for the tests only)
colour_on() { [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || (( ${CANCCU_FORCE_COLOR:-0} )); }; }
colour_line() {
  local ts=${1:0:19} rest=${1:20} head="" tone="" c on off=$'\e[0m'
  case $rest in
    *needs-you*|*" failed"*) tone=31 ;;
    *"awaiting accept"*|*paused*|*back-off*|*"usage limit"*) tone=33 ;;
    *" merged "*|*"auto-merge enabled"*) tone=32 ;;
  esac
  if [[ $rest =~ ^#([0-9]+)(.*)$ ]]; then
    c=$(color_code "${BASH_REMATCH[1]}"); rest=${BASH_REMATCH[2]}
    if [ -n "$c" ]; then head=$'\e[38;5;'"${c}m#${BASH_REMATCH[1]}$off"; else head="#${BASH_REMATCH[1]}"; fi
  fi
  if [ -n "$tone" ]; then on=$'\e['"${tone}m"; printf '%s %s%s%s%s\n' "$ts" "$head" "$on" "$rest" "$off"
  else printf '%s %s%s\n' "$ts" "$head" "$rest"; fi
}

# mut <cmd...>: a write. Prints it instead under --dry-run. In the dispatcher (CANCCU_MUT_TO_LOG=1)
# the command's own output (gh's URLs, "Deleted branch …") goes to dispatch.log only, each line
# prefixed "  │ ", never to its pane: the pane shows the dispatcher's own log lines.
mut() {
  if (( CANCCU_DRY )); then echo "  would: $*"; return 0; fi
  (( ${CANCCU_MUT_TO_LOG:-0} )) || { guard 60 "$@"; return; }
  mut_out "$@"
}

# mut_out <cmd...>: mut, also keeping the command's output (stdout and stderr together) in MUT_OUT,
# for a caller that reads its error; mut in the dispatcher is this. Not run in $(…). The output
# goes where mut_show puts it. Under --dry-run MUT_OUT is empty.
mut_out() {
  MUT_OUT=""
  if (( CANCCU_DRY )); then echo "  would: $*"; return 0; fi
  local rc; MUT_OUT=$(guard 60 "$@" 2>&1); rc=$?
  mut_show "$MUT_OUT"
  return $rc
}
# mut_show <output>: a write's captured output: in the dispatcher to dispatch.log, each line
# prefixed "  │ "; else to stderr (stdout and stderr were captured together)
mut_show() {
  [ -n "$1" ] || return 0
  if (( ${CANCCU_MUT_TO_LOG:-0} )); then sed 's/^/  │ /' <<<"$1" >> "$CANCCU_HOME/dispatch.log"; else echo "$1" >&2; fi
}

# oneline <max> <text>: newlines and tabs to spaces, cut to max chars. The engine reads its
# words with `read`, so a prompt must be one line.
oneline() {
  local s; s=$(tr '\n\r\t' '   ' <<<"$2" | tr -s ' '); s=${s# }; s=${s% }
  (( ${#s} > $1 )) && s="${s:0:$1}…"
  printf '%s' "$s"
}

# quote <max> <text>: a markdown blockquote of the text, cut to max chars
quote() {
  local s=$2; (( ${#s} > $1 )) && s="${s:0:$1}…"
  sed 's/^/> /' <<<"$s"
}

# home_tilde_stream / home_tilde <text>: $HOME shown as ~. Everything the tool posts to GitHub
# goes through one of these: a public comment never names the host's home directory.
home_tilde_stream() {
  local h=${HOME%/} e
  [ -n "$h" ] || { cat; return; }
  e=$(printf '%s' "$h" | sed 's/[][\\/.^$*+?(){}|#]/\\&/g')
  # a sentence's full stop ends the path too; "$HOME.bak" or "${HOME}2" are other paths
  sed -E "s#${e}(/|[^A-Za-z0-9_.-]|\\.([^A-Za-z0-9_-]|\$)|\$)#~\\1#g"
}
home_tilde() { printf '%s' "$1" | home_tilde_stream; }

slug() {
  tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/ /g' |
    awk '{ for (i = 1; i <= NF && i <= 4; i++) printf "%s%s", (i > 1 ? "-" : ""), $i }'
}

# ---------------------------------------------------------------- state (~/.canccu/state/<n>)

# Under --dry-run, writes go to DRY_ST in memory, so the rest of the pass sees them.
declare -A DRY_ST=()
st_file() { echo "$CANCCU_HOME/state/$1"; }
# kv_get <file> <dry key> <key>, kv_set <file> <dry key> key=value...: one key=value file (a unit's
# state/<K>, a step's steps/<m>); under --dry-run in DRY_ST under "<dry key>.<key>"
# The last value wins (kv_set may append). Pure bash: a pass reads state files many times.
kv_get() {
  if [ -n "${DRY_ST[$2.$3]+x}" ]; then printf '%s\n' "${DRY_ST[$2.$3]}"; return; fi
  local l v f=0
  [ -r "$1" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l == "$3="* ]] && { v=${l#"$3="}; f=1; }
  done < "$1"
  (( f )) && printf '%s\n' "$v"
  return 0
}
# kv_lock <file>: the lock of a key=value file, hidden beside it (the state dirs list units by
# their visible files)
kv_lock() { echo "${1%/*}/.${1##*/}.lock"; }
# kv_set writes every key in one go, under the file's lock, through a temp file of its own: the
# dispatcher's pass and canccu-ship, -stop, -run or -review writing the same file at once never
# lose a key
kv_set() {
  local f=$1 d=$2 kv; shift 2
  if (( CANCCU_DRY )); then
    DRY_ST[$d.]=1
    for kv; do DRY_ST[$d.${kv%%=*}]=${kv#*=}; done
    return 0
  fi
  mkdir -p "${f%/*}" || return 1
  ( flock -w 30 9 || { echo "kv_set: $f stayed locked" >&2; exit 1; }
    tmp=$(mktemp "${f%/*}/.${f##*/}.XXXXXX") || exit 1
    { [ -f "$f" ] && awk -v keys="${*%%=*}" 'BEGIN { n = split(keys, a, " "); for (i = 1; i <= n; i++) drop[a[i]] = 1 }
        { k = $0; sub(/=.*/, "", k) } !(k in drop)' "$f"
      awk '{ k = $0; sub(/=.*/, "", k); v[k] = $0; if (!(k in seen)) { seen[k] = 1; o[++n] = k } }
        END { for (i = 1; i <= n; i++) print v[o[i]] }' < <(printf '%s\n' "$@")
    } > "$tmp" && mv -f -- "$tmp" "$f" || { rm -f "$tmp"; exit 1; }
  ) 9>>"$(kv_lock "$f")"
}
# st_get <K> <key>, st_set <K> key=value...: a unit's state (K: an issue number or a package key);
# values are single-line
st_get() { kv_get "$(st_file "$1")" "$1" "$2"; }
st_set() { local k=$1; shift; kv_set "$(st_file "$k")" "$k" "$@"; }
# st_rm takes the file's lock too, and keeps the lock file: a writer waiting on it never runs
# beside one that would lock a new one
st_rm() {
  local f; f=$(st_file "$1")
  (( CANCCU_DRY )) && return 0
  ( flock -w 30 9 && rm -f "$f" ) 9>>"$(kv_lock "$f")"
}
# step_get <m> <key>, step_set <m> key=value...: a step's state, steps/<milestone number>
step_file() { echo "$CANCCU_HOME/steps/$1"; }
step_get() { kv_get "$(step_file "$1")" "@s$1" "$2"; }
step_set() { local m=$1; shift; kv_set "$(step_file "$m")" "@s$m" "$@"; }
# managed: every unit with a state file; issue numbers in order, package keys first
managed() {
  local f
  { for f in "$CANCCU_HOME"/state/*; do [ -f "$f" ] && echo "${f##*/}"; done
    for f in "${!DRY_ST[@]}"; do [[ $f == *. && $f != @* ]] && echo "${f%.}"; done; } | sort -u | sort -s -n
}
is_managed() { [ -f "$(st_file "$1")" ] || [ -n "${DRY_ST[$1.]+x}" ]; }

# the usage-limit back-off is global: every project runs on the same Claude account
backoff_until() { local b; b=$(cat "$CANCCU_ROOT/backoff" 2>/dev/null); [[ $b =~ ^[0-9]+$ ]] && echo "$b" || echo 0; }
backing_off() { (( $(backoff_until) > $(now) )); }
paused() { [ -e "$CANCCU_HOME/paused" ]; }

# ---------------------------------------------------------------- colour per issue

# 6 well-separated ANSI 256 colours: blue, orange, purple, teal, pink, olive. Red, yellow and
# green are left out: they mean needs-you, waiting and merged.
CANCCU_PALETTE=(33 208 135 37 205 142)
# issue_live <n>: a run of the issue is live: its worker, its answerer or its PR's reviewer
issue_live() {
  local pr
  if run_alive "$1" || run_alive "answer-$1"; then return 0; fi
  pr=$(st_get "$1" pr); [ -n "$pr" ] && run_alive "review-$pr"
}
# issue_color <n>: the issue's palette index (0-5) from state/<n>, or nothing
issue_color() { local c; c=$(st_get "$1" color); [[ $c =~ ^[0-5]$ ]] && echo "$c"; return 0; }
# claim_color <n>: a run starts, or the issue becomes managed: an issue without a colour gets the
# lowest index no other managed issue holds. When all 6 are held, the holder that has waited
# longest (no live run, the oldest state file) gives its up (color=-, until its next run claims
# one); when every holder runs (only with CAP above 6), the index is shared. The state file goes
# on close, and the colour with it.
claim_color() {
  local n=$1 c m i victim="" vt=0 t
  local -A held=()
  [ -n "$(issue_color "$n")" ] && return 0
  for m in $(managed); do
    [ "$m" = "$n" ] && continue
    c=$(issue_color "$m"); [ -n "$c" ] && held[$c]=$m
  done
  for i in 0 1 2 3 4 5; do
    [ -n "${held[$i]+x}" ] || { st_set "$n" color="$i"; return 0; }
  done
  for i in 0 1 2 3 4 5; do
    m=${held[$i]}; issue_live "$m" && continue
    t=$(stat -c %Y "$(st_file "$m")" 2>/dev/null || echo 0)
    if [ -z "$victim" ] || (( t < vt )); then victim=$i vt=$t; fi
  done
  if [ -n "$victim" ]; then st_set "${held[$victim]}" color=-
  else victim=$n; [[ $n =~ ^[0-9]+$ ]] || victim=$(cksum <<<"$n" | cut -d' ' -f1)
    victim=$(( victim % 6 )); warn_once colours "more than 6 issues run at once: some share a colour"; fi
  st_set "$n" color="$victim"
}
# color_code <n>: the issue's ANSI 256 colour number, or nothing
color_code() { local c; c=$(issue_color "$1"); [ -n "$c" ] && echo "${CANCCU_PALETTE[c]}"; return 0; }
# paint_window <window name> <n>: the run's tmux window (only that one) gets the issue's colour.
# Never another window, a session option or the user's config; any tmux error is ignored.
paint_window() {
  local c w
  (( CANCCU_DRY )) && return 0
  [ -z "${NO_COLOR:-}" ] || return 0
  c=$(color_code "$2"); [ -n "$c" ] || return 0
  w=$(window_by_name "$1"); [ -n "$w" ] || return 0
  tmux set-option -w -t "$w" window-status-style "fg=colour$c" >/dev/null 2>&1
  tmux set-option -w -t "$w" window-status-current-style "fg=colour$c,bold" >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------- spend and progress

# spend_today: "<USD> <runs without a cost>" for this project's runs that ended today (UTC), from
# the engine's spend.log ("<epoch> <repo> <key> <cost or ?>", one line per finished run). The USD
# are the exact costs claude reported; a run it reported none for (stopped at a budget, stalled,
# crashed) is counted apart, so the sum is a lower bound then. A live run has no cost yet.
spend_today() {
  local d0; d0=$(date -u -d "$(date -u -d "@$(now)" +%F)" +%s)
  awk -F '\t' -v a="$d0" -v b="$((d0 + 86400))" -v r="$REPO_NAME" \
    '$1 >= a && $1 < b && $2 == r { if ($4 ~ /^[0-9]+(\.[0-9]+)?$/) s += $4; else u++ }
     END { printf "%.2f %d\n", s, u }' "$WORKERS_DIR/spend.log" 2>/dev/null || echo "0.00 0"
}
# run_progress <key>: "<turns> <turn cap> <minute cap>" of the run's latest attempt, from its log
# (the engine's "=== … · budget <t>t/$<usd>/<m>m" header and the [tN] lines after it); nothing
# without a header
run_progress() {
  awk 'match($0, /^=== .* · budget [0-9]+t\/\$[0-9.]+\/[0-9]+m/) {
         b = $0; sub(/^.* · budget /, "", b); split(b, x, /[^0-9.]+/); tc = x[1]; mc = x[3]; t = 0; next }
       match($0, /^\[t[0-9]+\]/) { t = substr($0, 3, RLENGTH - 3) + 0 }
       END { if (tc != "") print t, tc, mc }' "$WORKERS_DIR/$REPO_NAME-$1.log" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- the parts
# shellcheck source=canccu-usage.sh
. "$_canccu_lib/canccu-usage.sh"
# shellcheck source=canccu-units.sh
. "$_canccu_lib/canccu-units.sh"
# shellcheck source=canccu-runs.sh
. "$_canccu_lib/canccu-runs.sh"
# shellcheck source=canccu-share.sh
. "$_canccu_lib/canccu-share.sh"
# shellcheck source=canccu-answer.sh
. "$_canccu_lib/canccu-answer.sh"
# shellcheck source=canccu-github.sh
. "$_canccu_lib/canccu-github.sh"
# shellcheck source=canccu-queue.sh
. "$_canccu_lib/canccu-queue.sh"
# shellcheck source=canccu-actions.sh
. "$_canccu_lib/canccu-actions.sh"
# shellcheck source=canccu-ping.sh
. "$_canccu_lib/canccu-ping.sh"
# shellcheck source=canccu-steps.sh
. "$_canccu_lib/canccu-steps.sh"
# shellcheck source=canccu-planner.sh
. "$_canccu_lib/canccu-planner.sh"
# shellcheck source=canccu-packages.sh
. "$_canccu_lib/canccu-packages.sh"
