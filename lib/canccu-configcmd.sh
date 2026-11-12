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
  ps=$(canccu_profiles | tr '\n' ' '); ps=${ps% }
  if [ "$glob" = 0 ] && [ -z "$proj" ]; then
    case $ps in
      "") _cmd_die "no project in $(canccu_tilde "$CANCCU_ROOT")/projects (canccu-init <name> <owner/repo> creates one; --global shows the rest)" ;;
      *" "*) _cmd_die "name a project: --project <name> (Projects: $ps)" 2 ;;
      *) proj=$ps ;;
    esac
  fi
  if [ -n "$proj" ] && ! canccu_profiles | grep -qxF -- "$proj"; then
    _cmd_die "no project '$proj'. Projects: $ps"
  fi
  local vals; vals=$(cfg_values "$proj") || exit 1
  [ "$origin" = 0 ] || printf 'KEY\tVALUE\tDEFAULT\tORIGIN\tLOCKED\n'
  local line key v d o l
  # read with IFS=tab would merge the tabs around an empty value: the fields are cut by hand
  while IFS= read -r line; do
    key=${line%%$'\t'*} line=${line#*$'\t'}
    v=${line%%$'\t'*} line=${line#*$'\t'}
    d=${line%%$'\t'*} o=${line#*$'\t'}
    [ ${#want[@]} = 0 ] || printf '%s\n' "${want[@]}" | grep -qxF -- "$key" || continue
    if [ "$origin" = 0 ]; then printf '%s=%s\n' "$key" "$v"
    else
      [ "$(cfg_field "$key" 4)" = locked ] && l=locked || l=""
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$v" "$d" "$o" "$l"
    fi
  done <<<"$vals"
}
