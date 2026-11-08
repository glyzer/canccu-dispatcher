# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # STAGED is read by install.sh
# The installed tree, for install.sh and canccu-dispatcher (rollback, uninstall, doctor). Sourced
# after canccu-projects.sh and canccu-version.sh, never run. docs/install.md is the spec.
#
# PREFIX/lib/canccu-dispatcher/ (the base):
#   releases/<id>/   a copy of a tree, never changed while a process runs from it. <id>: the
#                    version; from a git checkout <version>+<commit>, with uncommitted changes
#                    <version>+<commit>.dirty.<hash>: the same id is always the same files, but
#                    for a tarball that reuses a version. Its .tree.sha256 names its files (the
#                    same tree installs once), its .installed the time it was installed or made
#                    current again (the order of releases), its .rolled-back that a rollback
#                    switched away from it (rollback passes it, pruning drops it first; making
#                    it current again clears it).
#   current          a symlink to releases/<id>, or to a checkout (--dev); switched by a rename
#   .install.lock    held by install.sh, rollback and uninstall: one at a time
#   .venv            the monitor venv's path (uninstall removes it)
# PREFIX/bin/<command> → PREFIX/lib/canccu-dispatcher/current/bin/<command>. Every command finds
# its lib through its real path, so a running dispatcher keeps the release it started from:
# switching current never changes a file under it.

CANCCU_KEEP_RELEASES=3
# STAGED: what canccu_stage did (new, replaced, same), for install.sh
STAGED=""

# canccu_on_path <dir> <PATH>: the dir is on that PATH, either path resolved (a PATH entry keeps
# the form the user wrote, through a symlinked HOME too)
canccu_on_path() {
  local d e want; want=$(realpath -m "$1")
  IFS=: read -ra d <<<"$2"
  for e in "${d[@]}"; do [ -n "$e" ] && [ "$(realpath -m "$e")" = "$want" ] && return 0; done
  return 1
}
# canccu_install_lock <base>: takes the base's install lock (fd 9) for the rest of the caller, or
# says who holds it and fails. Appended, never truncated: a re-install that changes nothing
# leaves even the lock's time alone.
canccu_install_lock() {
  exec 9>>"$1/.install.lock"
  flock -n 9 && return 0
  echo "an install, rollback or uninstall runs on $(canccu_tilde "$1"); try again" >&2
  return 1
}
# canccu_link_ours <link target> <base>: the target points into this base, compared resolved up
# to the base (a symlinked HOME writes one prefix in two forms), not past it (current may point
# out of it: --dev)
canccu_link_ours() {
  [[ $1 == */lib/canccu-dispatcher/* ]] &&
    [ "$(realpath -m "${1%%/lib/canccu-dispatcher/*}")/lib/canccu-dispatcher" = "$(realpath -m "$2")" ]
}
# canccu_link_cmd <link target> <base> <command>: the target is this base's current/bin/<command>
canccu_link_cmd() { canccu_link_ours "$1" "$2" && [ "${1#*/lib/canccu-dispatcher/}" = "current/bin/$3" ]; }
# canccu_default_venv: the monitor venv's place when neither --venv nor CANCCU_VENV names one
# (bin/canccu-monitor holds the same default: it sources no lib)
canccu_default_venv() { realpath -m "${CANCCU_VENV:-$HOME/.local/share/canccu/venv}"; }
# canccu_release_intact <release dir> [hash]: its files are the ones it was installed with (and,
# given a hash, the ones of that tree): recomputed, never taken from its own record
canccu_release_intact() {
  local h; h=$(cat "$1/.tree.sha256" 2>/dev/null)
  [ -n "$h" ] && [ -f "$1/.installed" ] || return 1
  [ -z "${2:-}" ] || [ "$h" = "$2" ] || return 1
  [ "$(canccu_tree_files "$1" | canccu_tree_hash "$1")" = "$h" ]
}
# canccu_rolled <base> <id>: a rollback switched away from that release
canccu_rolled() { [ -e "$1/releases/$2/.rolled-back" ]; }
canccu_base() { printf '%s\n' "$1/lib/canccu-dispatcher"; }
# canccu_release_id <tree> <tree hash>
canccu_release_id() {
  local v c; v=$(canccu_version "$1"); c=$(canccu_commit "$1")
  case $c in
    "") printf '%s\n' "$v" ;;
    *", dirty") printf '%s+%s.dirty.%s\n' "$v" "${c%%,*}" "${2:0:8}" ;;
    *) printf '%s+%s\n' "$v" "$c" ;;
  esac
}
canccu_valid_release() { [[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]]; }

# canccu_tree_files <tree>: its files, NUL-separated, relative: a checkout's tracked files (as
# they are now: a stray local file never ships), else every file but .git, caches and a
# release's own markers
canccu_tree_files() {
  if canccu_is_checkout "$1"; then
    git -C "$1" ls-files -c -z |
      while IFS= read -r -d '' f; do { [ -e "$1/$f" ] || [ -L "$1/$f" ]; } && printf '%s\0' "$f"; done
  else
    (cd "$1" && find . \( -name .git -o -name __pycache__ \) -prune -o \( -type f -o -type l \) \
      ! -name '*.pyc' ! -path ./.installed ! -path ./.tree.sha256 ! -path ./.rolled-back -printf '%P\0')
  fi
}
# canccu_tree_hash <dir> < NUL list: one hash of the listed files' names, modes and contents
canccu_tree_hash() {
  local l; l=$(sort -z | tr '\0' '\n')
  ( cd "$1" && tr '\n' '\0' <<<"$l" | xargs -0 -r stat -c '%a %n' && tr '\n' '\0' <<<"$l" | xargs -0 -r sha256sum ) |
    sha256sum | cut -d' ' -f1
}

# canccu_current <base>: where current points (as the link says); canccu_current_id <base>: the
# release it is, nothing for a checkout (--dev) or none
canccu_current() { readlink "$1/current" 2>/dev/null; }
canccu_current_id() { local c; c=$(canccu_current "$1"); [[ $c == releases/* ]] && printf '%s\n' "${c#releases/}"; return 0; }
# canccu_releases <base>: the complete releases, oldest first (by their .installed time)
canccu_releases() {
  local d
  for d in "$1"/releases/*/; do
    d=${d%/}; [ -f "$d/.tree.sha256" ] && [ -f "$d/.installed" ] || continue
    printf '%s %s\n' "$(cat "$d/.installed")" "${d##*/}"
  done | sort -n | cut -d' ' -f2
}

# canccu_in_use <base>: "<release id> <pid>" for each process that runs from a release: through
# its argv (python3 <release>/lib/…), its cwd or a file it holds open (bash keeps the script it
# runs open: a dispatcher started through current still holds its release's path). Only the
# releases' paths count: processes of other users and the tree of another prefix are not seen.
canccu_in_use() {
  local rb f l x id
  rb=$(realpath -m "$1")/releases/
  {
    find /proc/[0-9]*/fd/ /proc/[0-9]*/cwd /proc/[0-9]*/exe -maxdepth 1 -lname "$rb*" -printf '%p %l\n' 2>/dev/null
    for f in $(grep -lsaF "$rb" /proc/[0-9]*/cmdline); do
      # a process may end between the grep and this read (the grep itself does)
      { tr '\0' '\n' < "$f"; } 2>/dev/null | grep -F "$rb" | sed "s|^|$f |"
    done
  } | { declare -A mine=()
  while read -r f l; do
    x=${f#/proc/}; x=${x%%/*}
    # the caller and its own subshells hold its script open too (fd 255): never "in use" by it.
    # Walked once per pid: one holds many matching fds.
    [ -n "${mine[$x]+x}" ] || { if _canccu_mine "$x"; then mine[$x]=1; else mine[$x]=0; fi; }
    (( mine[$x] )) && continue
    # gone since the scan (or during the walk above, which then cannot reach $$): runs nothing
    [ -d "/proc/$x" ] || continue
    l=${l#*"$rb"}; id=${l%%/*}
    # this scan's own find and grep name the dir in their argv, with no release after it
    canccu_valid_release "$id" && [ -d "$rb$id" ] && printf '%s %s\n' "$id" "$x"
  done; } | sort -u
}

# _canccu_mine <pid>: the pid is this shell or a descendant of it (its PPid chain reaches $$)
_canccu_mine() {
  local p=$1 n=0
  while [[ $p =~ ^[0-9]+$ ]] && (( p > 1 && n++ < 64 )); do
    [ "$p" = "$$" ] && return 0
    p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)
  done
  return 1
}

# canccu_stage <tree> <base> <id> <tree hash>: the tree as release <id>. A release of that id with
# the same files is kept (STAGED=same). One with other files (a tarball reusing a version) is
# replaced only while it is not current and no process runs from it: replacing it is two renames,
# and current must never point at a missing or half-swapped dir. Copied beside it first and
# renamed into place: no process ever sees half a release.
canccu_stage() {
  local src=$1 base=$2 id=$3 want=$4 rel users tmp old
  rel=$base/releases/$id
  if [ -d "$rel" ]; then
    # its files as they are now, not as recorded: a release edited by hand installs again
    canccu_release_intact "$rel" "$want" && { STAGED=same; return 0; }
    if [ "$(canccu_current_id "$base")" = "$id" ]; then
      echo "install.sh: release $id is current and installed with other files; nothing changed. Give this tree a new VERSION, or make another release current first (install one, or canccu-dispatcher rollback), then install this one again." >&2
      return 1
    fi
    users=$(canccu_in_use "$base" | awk -v r="$id" '$1 == r { printf " %s", $2 }')
    if [ -n "$users" ]; then
      echo "install.sh: release $id is installed with other files, and processes run from it (pid$users); nothing changed. Give this tree a new VERSION, or stop them first." >&2
      return 1
    fi
  fi
  tmp=$base/releases/.new-$id.$$ old=$base/releases/.old-$id.$$
  rm -rf "$tmp" && mkdir -p "$tmp" || return 1
  canccu_tree_files "$src" | (cd "$src" && xargs -0 -r cp -a --parents -t "$tmp") &&
    [ "$(canccu_tree_files "$tmp" | canccu_tree_hash "$tmp")" = "$want" ] ||
    { rm -rf "$tmp"; echo "install.sh: could not copy the tree to $(canccu_tilde "$tmp"); nothing changed" >&2; return 1; }
  echo "$want" > "$tmp/.tree.sha256" && date +%s%N > "$tmp/.installed" || { rm -rf "$tmp"; return 1; }
  if [ -d "$rel" ]; then
    mv -T "$rel" "$old" && mv -T "$tmp" "$rel" && rm -rf "$old" && STAGED=replaced && return 0
  else
    mv -T "$tmp" "$rel" && STAGED=new && return 0
  fi
  rm -rf "$tmp"; echo "install.sh: could not move the release into $(canccu_tilde "$rel")" >&2; return 1
}

# canccu_switch <base> <target>: current points at target (releases/<id>, or a checkout's
# absolute path), in one rename: a command started meanwhile runs the old or the new, never none
canccu_switch() {
  [ "$(canccu_current "$1")" = "$2" ] && return 0
  if [ -e "$1/current" ] && [ ! -L "$1/current" ]; then
    echo "$(canccu_tilde "$1")/current is not a link; nothing switched" >&2; return 1
  fi
  ln -sfn "$2" "$1/.current.$$" && mv -Tf "$1/.current.$$" "$1/current" && return 0
  rm -f "$1/.current.$$"; return 1
}

# canccu_link <prefix> <base> <tree> <replace 0|1>: PREFIX/bin/<command> for each of the tree's
# commands, through current. A link elsewhere (an install of another kind) is named and kept
# unless replace; a file of that name is never touched. A link of ours to a command the tree no
# longer has goes.
canccu_link() {
  local prefix=$1 base=$2 tree=$3 replace=$4 c l t want
  for c in "$tree"/bin/*; do
    c=${c##*/} l=$prefix/bin/${c##*/} want=$base/current/bin/${c##*/}
    if [ -L "$l" ]; then
      t=$(readlink "$l")
      canccu_link_cmd "$t" "$base" "$c" && continue
      if ! canccu_link_ours "$t" "$base" && (( ! replace )); then
        echo "kept $(canccu_tilde "$l") → $t (a link into another install; --replace-links replaces it)"; continue
      fi
    elif [ -e "$l" ]; then
      echo "kept $(canccu_tilde "$l"): a file, not a link (never replaced; remove it to use this install)"; continue
    fi
    ln -s "$want" "$l.canccu-new" && mv -Tf "$l.canccu-new" "$l" && echo "linked $(canccu_tilde "$l")" ||
      { rm -f "$l.canccu-new"; echo "could not link $(canccu_tilde "$l")" >&2; }
  done
  for l in "$prefix"/bin/canccu-*; do
    [ -L "$l" ] && canccu_link_cmd "$(readlink "$l")" "$base" "${l##*/}" && [ ! -e "$tree/bin/${l##*/}" ] &&
      rm -f "$l" && echo "removed $(canccu_tilde "$l") (this release has no such command)"
  done
  return 0
}

# canccu_prune <base> <in use>: removes the releases beyond the newest CANCCU_KEEP_RELEASES (the
# ones rolled away from count last: a bad release goes before a good one), never current's and
# never one a process runs from (canccu_in_use's lines, read once by the caller); and what an
# interrupted install left behind
canccu_prune() {
  local base=$1 cur busy id keep=()
  cur=$(canccu_current_id "$base"); busy=$(cut -d' ' -f1 <<<"$2" | sort -u)
  mapfile -t keep < <({ for id in $(canccu_releases "$base" | tac); do canccu_rolled "$base" "$id" || echo "$id"; done
                        for id in $(canccu_releases "$base" | tac); do canccu_rolled "$base" "$id" && echo "$id"; done; } |
                      head -n "$CANCCU_KEEP_RELEASES")
  for id in $(canccu_releases "$base"); do
    [ "$id" = "$cur" ] && continue
    printf '%s\n' "${keep[@]}" | grep -qxF -- "$id" && continue
    if grep -qxF -- "$id" <<<"$busy"; then echo "kept release $id: a process runs from it"; continue; fi
    rm -rf "${base:?}/releases/$id" && echo "removed release $id"
  done
  rm -rf "$base"/releases/.new-* "$base"/releases/.old-*
  return 0
}

# canccu_venv <requirements> <venv> <recorded venv>: the monitor's packages, pinned, in a venv of
# their own, no sudo: with uv when there is one (it needs no ensurepip), else python3 -m venv and
# pip. Rebuilt only when the requirements change (their hash is kept in the venv). Built only
# where the installer owns the dir: missing or empty, holding its marker, holding the trace of a
# build of its own that failed (.canccu-building: written before a build, removed when it
# succeeds), or the venv this base recorded. Anywhere else the marker would make uninstall remove the dir with
# all in it. Fails with a warning (2: skipped, 1: the build failed): the dispatcher does not need
# the monitor.
canccu_venv() {
  local req=$1 venv=$2 want
  want=$(sha256sum < "$req" | cut -d' ' -f1)
  [ -x "$venv/bin/python" ] && [ "$(cat "$venv/.requirements.sha256" 2>/dev/null)" = "$want" ] && return 0
  if [ -e "$venv" ] && [ ! -f "$venv/.requirements.sha256" ] && [ ! -f "$venv/.canccu-building" ] && [ "$venv" != "$3" ] &&
     { [ ! -d "$venv" ] || [ -n "$(ls -A "$venv" 2>/dev/null)" ]; }; then
    echo "install.sh: $(canccu_tilde "$venv") holds other files: not a venv this installer built, so it builds none there (--venv names another dir); everything else is installed" >&2
    return 2
  fi
  mkdir -p "$venv" && rm -f "$venv/.requirements.sha256" && : > "$venv/.canccu-building" ||
    { echo "install.sh: cannot create the monitor's venv in $(canccu_tilde "$venv"); everything else is installed" >&2; return 1; }
  if command -v uv >/dev/null 2>&1; then
    uv venv -q --allow-existing --python "$(command -v python3)" "$venv" >/dev/null 2>&1 &&
      uv pip install -q --python "$venv/bin/python" -r "$req" >/dev/null 2>&1
  else
    python3 -m venv "$venv" >/dev/null 2>&1 &&
      "$venv/bin/python" -m pip install -q --disable-pip-version-check -r "$req" >/dev/null 2>&1
  fi && echo "$want" > "$venv/.requirements.sha256" && rm -f "$venv/.canccu-building" &&
    echo "built the monitor's venv in $(canccu_tilde "$venv")" && return 0
  echo "install.sh: could not build the monitor's venv in $(canccu_tilde "$venv") (it needs uv, or python3 -m venv with pip: the python3-venv package); everything else is installed" >&2
  return 1
}

# canccu_state_config <tree> <host profile>: the state dir's two exceptions. A missing config is
# written with every default commented out (a later default then takes effect); a host profile
# is added to a config without one. Nothing else of the state dir is ever touched.
canccu_state_config() {
  local f=$CANCCU_ROOT/config have
  if [ ! -e "$f" ]; then
    mkdir -p "$CANCCU_ROOT" && sed -E 's/^([A-Z_]+=)/# \1/' "$1/lib/canccu-config.default" > "$f" &&
      echo "wrote $(canccu_tilde "$f") (every default commented out)"
  fi
  [ -n "$2" ] || return 0
  have=$(canccu_config_host_profile "$f")
  # an empty value (HOST_PROFILE= copied from the defaults) is no profile: the line added after
  # it wins
  if [ -z "$have" ]; then
    printf 'HOST_PROFILE=%s\n' "$2" >> "$f" && echo "set HOST_PROFILE=$2 in $(canccu_tilde "$f")"
  elif [ "$have" != "$2" ]; then
    echo "$(canccu_tilde "$f") keeps HOST_PROFILE=$have (not changed to $2: edit it by hand)"
  fi
}
