# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# canccu-dispatcher config: the settings table (lib/canccu-settings.tsv) and what each setting
# holds. Sourced by bin/canccu-dispatcher after lib/canccu-projects.sh, never run.
# docs/reference/commands.md, "config show".
_cfg_lib=$(dirname "${BASH_SOURCE[0]}")

_cfg_rows() { grep -v '^#' "$_cfg_lib/canccu-settings.tsv" | grep .; }
# cfg_keys: the keys, in the table's order
cfg_keys() { _cfg_rows | cut -f1; }
# cfg_field <KEY> <n>: column n of the key's line; status 1 for an unknown key
cfg_field() {
  local l; l=$(_cfg_rows | awk -F'\t' -v k="$1" '$1 == k')
  [ -n "$l" ] || return 1
  cut -f"$2" <<<"$l"
}
# cfg_layers <project>: "<origin><TAB><path>" per file, in the order lib/canccu-config.sh loads
# them. An unknown host profile fails: the real load stops there too.
cfg_layers() {
  local hp f
  printf 'default\t%s\n' "$(realpath -m "$_cfg_lib/canccu-config.default")"
  hp=$(canccu_host_profile)
  if [ -n "$hp" ]; then
    f=$(canccu_host_conf "$hp") || { echo "canccu-dispatcher: no host profile '$hp' ($(canccu_host_where)). Profiles: $(canccu_host_profiles)" >&2; return 1; }
    printf 'host:%s\t%s\n' "$hp" "$f"
  fi
  [ ! -f "$CANCCU_ROOT/config" ] || printf 'global\t%s\n' "$CANCCU_ROOT/config"
  [ -n "$1" ] || return 0
  printf 'rules\t%s\n' "$CANCCU_ROOT/projects/$1/rules"
  printf 'project\t%s\n' "$CANCCU_ROOT/projects/$1/config"
}
# cfg_values <project>: "<KEY><TAB><value><TAB><default><TAB><origin>" per key. The origin is
# found by comparing values after each layer, not by searching the files: a file may set a key
# inside an if, or to the value it already had. The layers run in a subshell (they are shell
# code and may set anything); the names used here start with _cv_ so a layer cannot clobber them.
cfg_values() {
  local layers
  layers=$(cfg_layers "$1") || return 1
  ( set +u
    _cv_keys=() _cv_prev=() _cv_def=() _cv_org=()
    mapfile -t _cv_keys < <(cfg_keys)
    unset "${_cv_keys[@]}"
    # shellcheck disable=SC2034  # read by the layers, as lib/canccu-common.sh sets them
    if [ -n "$1" ]; then CANCCU_PROJECT=$1 CANCCU_HOME=$CANCCU_ROOT/projects/$1; else unset CANCCU_PROJECT CANCCU_HOME; fi
    while IFS=$'\t' read -r _cv_o _cv_f; do
      _cv_total=$TOTAL_CAP
      # shellcheck source=/dev/null
      [ ! -f "$_cv_f" ] || . "$_cv_f" </dev/null >/dev/null 2>&1
      # TOTAL_CAP is the global config's only (lib/canccu-config.sh puts it back the same way)
      case $_cv_o in rules|project) TOTAL_CAP=$_cv_total ;; esac
      for _cv_i in "${!_cv_keys[@]}"; do
        _cv_v=${!_cv_keys[_cv_i]-}
        if [ "$_cv_o" = default ]; then _cv_def[_cv_i]=$_cv_v _cv_org[_cv_i]=default
        elif [ "$_cv_v" != "${_cv_prev[_cv_i]}" ]; then _cv_org[_cv_i]=$_cv_o
        fi
        _cv_prev[_cv_i]=$_cv_v
      done
    done <<<"$layers"
    _cv_hp=$(canccu_host_profile)
    for _cv_i in "${!_cv_keys[@]}"; do
      _cv_v=${_cv_prev[_cv_i]} _cv_d=${_cv_def[_cv_i]} _cv_o=${_cv_org[_cv_i]}
      if [ "${_cv_keys[_cv_i]}" = HOST_PROFILE ]; then
        _cv_v=$_cv_hp; if [ -n "$_cv_v" ]; then _cv_o=global; else _cv_o=default; fi
      fi
      _cv_v=${_cv_v//[$'\t\n']/ } _cv_d=${_cv_d//[$'\t\n']/ }
      printf '%s\t%s\t%s\t%s\n' "${_cv_keys[_cv_i]}" "$_cv_v" "$_cv_d" "$_cv_o"
    done )
}
# _cfg_project <name or empty>: the project a command works on: the named one, else the only one.
# Ends the command as doctor does when there is none or the name is unknown.
_cfg_project() {
  local proj=$1 ps
  ps=$(canccu_profiles | tr '\n' ' '); ps=${ps% }
  if [ -z "$proj" ]; then
    case $ps in
      "") _cmd_die "no project in $(canccu_tilde "$CANCCU_ROOT")/projects (canccu-init <name> <owner/repo> creates one; --global shows the rest)" ;;
      *" "*) _cmd_die "name a project: --project <name> (Projects: $ps)" 2 ;;
      *) proj=$ps ;;
    esac
  fi
  canccu_profiles | grep -qxF -- "$proj" || _cmd_die "no project '$proj'. Projects: $ps"
  printf '%s\n' "$proj"
}
# cfg_show [--project <name>] [--global] [--origin] [KEY...]: config show. It reads the config
# files only: the token file and the gh login's dir are printed as paths, never opened. A usage
# error calls the caller's usage.
cfg_show() {
  local proj="" glob=0 origin=0 want=() k ps
  while [ $# -gt 0 ]; do
    case $1 in
      --project) [ $# -ge 2 ] && [ -n "$2" ] || usage; proj=$2; shift 2 ;;
      --global) glob=1; shift ;;
      --origin) origin=1; shift ;;
      -*) echo "canccu-dispatcher config show: unknown option $1" >&2; usage ;;
      *) want+=("$1"); shift ;;
    esac
  done
  [ "$glob" = 0 ] || [ -z "$proj" ] || usage
  for k in "${want[@]}"; do cfg_field "$k" 1 >/dev/null || _cmd_die "unknown setting $k" 2; done
  [ "$glob" = 1 ] || proj=$(_cfg_project "$proj") || exit
  local vals; vals=$(cfg_values "$proj") || exit 1
  [ "$origin" = 0 ] || printf 'KEY\tVALUE\tDEFAULT\tORIGIN\tLOCKED\n'
  local line key v d o l
  # read with IFS=tab would merge the tabs around an empty value: the fields are cut by hand
  while IFS= read -r line; do
    key=${line%%$'\t'*} line=${line#*$'\t'}
    v=${line%%$'\t'*} line=${line#*$'\t'}
    d=${line%%$'\t'*} o=${line#*$'\t'}
    # not printf | grep -q: under pipefail, grep's early exit fails the printf (SIGPIPE) at random
    [[ ${#want[@]} = 0 || " ${want[*]} " == *" $key "* ]] || continue
    if [ "$origin" = 0 ]; then printf '%s=%s\n' "$key" "$v"
    else
      [ "$(cfg_field "$key" 4)" = locked ] && l=locked || l=""
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$v" "$d" "$o" "$l"
    fi
  done <<<"$vals"
}

# cfg_check <KEY> <value>: status 0 when the value fits the key's type in the table, else 1 and
# the reason on stdout. config set writes one line per key: a newline would end it, and a tab
# would break the history's and config show's columns.
cfg_check() {
  local k=$1 v=$2 t a lo hi alts ws w
  t=$(cfg_field "$k" 2) || { echo "unknown setting $k"; return 1; }
  if [[ $v == *[$'\t\n']* ]]; then echo "$k must be one line without tabs"; return 1; fi
  alts=${t#*:}
  case $t in
    int:*|intopt:*)
      IFS=: read -r a lo hi <<<"$t"
      [[ $a == intopt && -z $v ]] && return 0
      # no leading zero: the dispatcher's arithmetic reads 08 as a bad octal number
      [[ $v =~ ^(0|[1-9][0-9]{0,8})$ ]] && (( v >= lo && v <= hi )) && return 0
      echo "$k must be a whole number from $lo to $hi$([ "$a" = intopt ] && echo ", or empty")" ;;
    enum:*)
      # a | in the value would match several alternatives at once
      [[ $v != *'|'* && "|$alts|" == *"|$v|"* ]] && return 0
      echo "$k must be one of: $(_cfg_list "$alts")" ;;
    words:*)
      # RESUME_ON is read with commas, PING_KINDS with spaces: both separate here
      IFS=$', ' read -ra ws <<<"$v"
      for w in "${ws[@]}"; do [[ $w != *'|'* && "|$alts|" == *"|$w|"* ]] || { echo "$k may only hold: $(_cfg_list "$alts")"; return 1; }; done
      return 0 ;;
    budget)
      # no leading zero, as for int: the worker's $((mins + 2)) reads 09 as a bad octal number
      [[ $v =~ ^\ *(0|[1-9][0-9]*)\ +(0|[1-9][0-9]*)\ +(0|[1-9][0-9]*)\ *$ ]] && return 0
      echo "$k must be three whole numbers: turns, USD, minutes (for example \"120 25 120\")" ;;
    regex)
      grep -E -- "$v" </dev/null >/dev/null 2>&1; [ $? = 2 ] || return 0
      echo "$k is not a pattern grep -E accepts" ;;
    date)
      # date -d alone accepts 2030-02-30 as March 2nd: the round trip must give the same text
      [ -z "$v" ] || { [[ $v =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -u -d "$v" +%F 2>/dev/null)" = "$v" ]; } && return 0
      echo "$k must be a date as YYYY-MM-DD, or empty" ;;
    name)
      local re='^[][A-Za-z0-9._:/-]*$'
      [[ $v =~ $re ]] && return 0
      echo "$k may only hold letters, digits and . _ : / [ ] -" ;;
    *) return 0 ;;
  esac
  return 1
}
# _cfg_list <a|b|…>: "a, b, …", an empty alternative as "empty"
_cfg_list() { awk -F'|' '{ for (i = 1; i <= NF; i++) printf "%s%s", (i > 1 ? ", " : ""), ($i == "" ? "empty" : $i) }' <<<"$1"; }

# cfg_actor: who called: leader or run by the CANCCU_ACTOR marker (libexec/canccu-worker exports
# run), the product owner (po) otherwise. Not a security boundary: a process can unset it.
cfg_actor() { case ${CANCCU_ACTOR-} in leader|run) echo "$CANCCU_ACTOR" ;; *) echo po ;; esac; }

# _cfg_held <file> <KEY> <project>: the value the file sets for the key; status 1 when it has no
# line for it. Sourced, as the dispatcher reads it, so quotes and escapes come out as it sees them.
_cfg_held() {
  [ -f "$1" ] && grep -qE "^[[:space:]]*$2=" "$1" || return 1
  ( set +u; unset "$2"
    # shellcheck disable=SC2034  # read by the file, as lib/canccu-common.sh sets them
    [ -z "$3" ] || CANCCU_PROJECT=$3 CANCCU_HOME=$CANCCU_ROOT/projects/$3
    # shellcheck source=/dev/null
    . "$1" </dev/null >/dev/null 2>&1; printf '%s\n' "${!2-}" )
}
# _cfg_history <dir> <actor> <set|unset|refused> <KEY> <old> <new> <why>: one line in
# <dir>/config.history; tabs and newlines in a field become spaces, so a line stays seven columns
_cfg_history() {
  local d=$1 x l; shift
  l=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for x in "$@"; do l+=$'\t'${x//[$'\t\n']/ }; done
  ( umask 077; printf '%s\n' "$l" >> "$d/config.history" )
}
# cfg_set <set|unset> [--project <name> | --global] KEY[=VALUE] [--why <text>]: config set and
# config unset (docs/reference/commands.md). Only the key's own lines change; the file is
# rewritten in a temporary file, checked with bash -n and moved over the old one, so the
# dispatcher, which only reads, never sees half a file. A usage error calls the caller's usage.
cfg_set() {
  local op=$1 proj="" glob=0 why=- arg="" n=0 k v="" f tgt dir old held=1 actor tmp w q nowp
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --project) [ $# -ge 2 ] && [ -n "$2" ] || usage; proj=$2; shift 2 ;;
      --global) glob=1; shift ;;
      --why) [ $# -ge 2 ] || usage; why=${2:--}; shift 2 ;;
      -*) echo "canccu-dispatcher config $op: unknown option $1" >&2; usage ;;
      *) arg=$1 n=$((n + 1)); shift ;;
    esac
  done
  [ "$n" = 1 ] && { [ "$glob" = 0 ] || [ -z "$proj" ]; } || usage
  if [ "$op" = set ]; then [[ $arg == *=* ]] || usage; k=${arg%%=*} v=${arg#*=}; else k=$arg; fi
  if [ "$glob" = 0 ]; then proj=$(_cfg_project "$proj") || exit; nowp=$proj
  else
    # the "now:" line of a --global write: the only project's value, as config show gives it
    [ "$(canccu_profiles | grep -c .)" != 1 ] || nowp=$(canccu_profiles)
  fi
  f=$(cfg_field "$k" 3) || _cmd_die "unknown setting $k" 2
  [ "$f" != fixed ] || _cmd_die "$k is not changed with this command: edit the config file by hand and restart the dispatcher" 2
  case $glob:$f in
    1:*) tgt=$CANCCU_ROOT/config ;;
    0:rules) tgt=$CANCCU_ROOT/projects/$proj/rules ;;
    0:project) tgt=$CANCCU_ROOT/projects/$proj/config ;;
    *) tgt="" ;;
  esac
  dir=${tgt%/*}; dir=${dir:-$CANCCU_ROOT}
  actor=$(cfg_actor)
  if [ "$(cfg_field "$k" 4)" = locked ] && [ "$actor" != po ]; then
    old=$(_cfg_held "$tgt" "$k" "$proj") || old=-
    _cfg_history "$dir" "$actor" refused "$k" "$old" "$([ "$op" = set ] && printf '%s' "$v" || echo -)" "$why"
    _cmd_die "refused: $k is locked; only the product owner changes it" 3
  fi
  if [ "$op" = set ]; then w=$(cfg_check "$k" "$v") || _cmd_die "$w" 2; fi
  [ -n "$tgt" ] || _cmd_die "$k is global: use --global" 2
  [ -f "$tgt" ] || [ "$glob" = 1 ] || _cmd_die "no $(canccu_tilde "$tgt")"
  {
    flock 9 || _cmd_die "cannot lock $(canccu_tilde "$tgt").lock"
    old=$(_cfg_held "$tgt" "$k" "$proj") || held=0
    if [ "$op" = set ] && [ "$held" = 1 ] && [ "$old" = "$v" ]; then echo "$k is already $v in $(canccu_tilde "$tgt")"; return 0; fi
    if [ "$op" = unset ] && [ "$held" = 0 ]; then echo "$k is not set in $(canccu_tilde "$tgt")"; return 0; fi
    # single quotes: a setting never expands a variable (the ones that need $HOME are fixed)
    q="'${v//\'/\'\\\'\'}'"
    # a symlinked file stays a link: the new file goes where it points
    w=$tgt; [ ! -L "$tgt" ] || w=$(readlink -f -- "$tgt")
    tmp=$(mktemp "${w%/*}/.${w##*/}.XXXXXX") || _cmd_die "cannot write in $(canccu_tilde "${w%/*}")"
    { [ ! -f "$w" ] || cat -- "$w"; } | CFG_LINE="$k=$q" awk -v k="$k" -v set="$([ "$op" = set ] && echo 1 || echo 0)" '
      $0 ~ "^[[:space:]]*" k "=" { if (set && !put) print ENVIRON["CFG_LINE"]; put = 1; next }
      { print }
      END { if (set && !put) print ENVIRON["CFG_LINE"] }' > "$tmp"
    if ! bash -n "$tmp" 2>/dev/null; then rm -f "$tmp"; _cmd_die "$(canccu_tilde "$tgt") would not be valid shell; nothing changed"; fi
    [ ! -f "$w" ] || chmod --reference="$w" "$tmp"
    mv -f -- "$tmp" "$w" || { rm -f "$tmp"; _cmd_die "cannot replace $(canccu_tilde "$tgt")"; }
    [ "$held" = 1 ] || old=-
    _cfg_history "$dir" "$actor" "$op" "$k" "$old" "$([ "$op" = set ] && printf '%s' "$v" || echo -)" "$why"
  } 9>>"$tgt.lock"
  if [ "$op" = set ]; then echo "$k=$v written to $(canccu_tilde "$tgt"); it applies at the dispatcher's next pass"
  else echo "$k removed from $(canccu_tilde "$tgt"); it applies at the dispatcher's next pass"
  fi
  # a later layer may still win: the line says what the commands read now
  cfg_values "$nowp" | awk -F'\t' -v k="$k" '$1 == k { print "now: " $2 " (from " $4 ")" }'
}
