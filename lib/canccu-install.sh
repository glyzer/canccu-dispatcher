# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034  # STAGED is read by install.sh
# The installed tree, for install.sh and canccu-dispatcher (rollback, uninstall, doctor). Sourced
# after canccu-projects.sh and canccu-version.sh, never run. docs/install.md is the spec.
#
# PREFIX/lib/canccu-dispatcher/ (the base):
#   releases/<id>/   a copy of a tree, never changed while a process runs from it. <id>: the
#                    version; from a git checkout <version>+<commit>, +<commit>.dirty with
#                    uncommitted changes. Its .tree.sha256 names its files (the same tree installs
#                    once), its .installed the time it was installed (the order of releases).
#   current          a symlink to releases/<id>, or to a checkout (--dev); switched by a rename
#   .install.lock    held by install.sh, rollback and uninstall: one at a time
#   .venv            the monitor venv's path (uninstall removes it)
# PREFIX/bin/<command> → PREFIX/lib/canccu-dispatcher/current/bin/<command>. Every command finds
# its lib through its real path, so a running dispatcher keeps the release it started from:
# switching current never changes a file under it.

CANCCU_KEEP_RELEASES=3
# STAGED: what canccu_stage did (new, replaced, same), for install.sh
STAGED=""

canccu_base() { printf '%s\n' "$1/lib/canccu-dispatcher"; }
# canccu_release_id <tree>
canccu_release_id() {
  local v c; v=$(canccu_version "$1"); c=$(canccu_commit "$1")
  case $c in
    "") printf '%s\n' "$v" ;;
    *", dirty") printf '%s+%s.dirty\n' "$v" "${c%%,*}" ;;
    *) printf '%s+%s\n' "$v" "$c" ;;
  esac
}
canccu_valid_release() { [[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]]; }

# canccu_tree_files <tree>: its files, NUL-separated, relative: a checkout's tracked and new files
# (as they are now, not ignored), else every file but .git, caches and a release's own markers
canccu_tree_files() {
  if [ -n "$(canccu_commit "$1")" ]; then
    git -C "$1" ls-files -co --exclude-standard -z |
      while IFS= read -r -d '' f; do { [ -e "$1/$f" ] || [ -L "$1/$f" ]; } && printf '%s\0' "$f"; done
  else
    (cd "$1" && find . \( -name .git -o -name __pycache__ \) -prune -o \( -type f -o -type l \) \
      ! -name '*.pyc' ! -path ./.installed ! -path ./.tree.sha256 -printf '%P\0')
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
  } | while read -r f l; do
    x=${f#/proc/}; x=${x%%/*}
    [ "$x" = "$$" ] || [ "$x" = "$BASHPID" ] && continue
    l=${l#*"$rb"}; id=${l%%/*}
    # this scan's own find and grep name the dir in their argv, with no release after it
    canccu_valid_release "$id" && [ -d "$rb$id" ] && printf '%s %s\n' "$id" "$x"
  done | sort -u
}

# canccu_stage <tree> <base> <id>: the tree as release <id>. A release of that id with the same
# files is kept (STAGED=same); one with other files is replaced only while no process runs from
# it. Copied beside it first and renamed into place: no process ever sees half a release.
canccu_stage() {
  local src=$1 base=$2 id=$3 rel want users tmp old
  rel=$base/releases/$id
  want=$(canccu_tree_files "$src" | canccu_tree_hash "$src")
  if [ -d "$rel" ]; then
    [ "$(cat "$rel/.tree.sha256" 2>/dev/null)" = "$want" ] && [ -f "$rel/.installed" ] && { STAGED=same; return 0; }
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
      [ "$t" = "$want" ] && continue
      if [[ $t != "$base"/* ]] && (( ! replace )); then
        echo "kept $(canccu_tilde "$l") → $t (a link into another install; --replace-links replaces it)"; continue
      fi
    elif [ -e "$l" ]; then
      echo "kept $(canccu_tilde "$l"): a file, not a link (never replaced; remove it to use this install)"; continue
    fi
    ln -s "$want" "$l.canccu-new" && mv -Tf "$l.canccu-new" "$l" && echo "linked $(canccu_tilde "$l")" ||
      { rm -f "$l.canccu-new"; echo "could not link $(canccu_tilde "$l")" >&2; }
  done
  for l in "$prefix"/bin/canccu-*; do
    [ -L "$l" ] && [ "$(readlink "$l")" = "$base/current/bin/${l##*/}" ] && [ ! -e "$tree/bin/${l##*/}" ] &&
      rm -f "$l" && echo "removed $(canccu_tilde "$l") (this release has no such command)"
  done
  return 0
}

# canccu_prune <base>: removes the releases beyond the newest CANCCU_KEEP_RELEASES, never
# current's and never one a process runs from; and what an interrupted install left behind
canccu_prune() {
  local base=$1 cur busy id keep=()
  cur=$(canccu_current_id "$base"); busy=$(canccu_in_use "$base" | cut -d' ' -f1 | sort -u)
  mapfile -t keep < <(canccu_releases "$base" | tail -n "$CANCCU_KEEP_RELEASES")
  for id in $(canccu_releases "$base"); do
    [ "$id" = "$cur" ] && continue
    printf '%s\n' "${keep[@]}" | grep -qxF -- "$id" && continue
    if grep -qxF -- "$id" <<<"$busy"; then echo "kept release $id: a process runs from it"; continue; fi
    rm -rf "${base:?}/releases/$id" && echo "removed release $id"
  done
  rm -rf "$base"/releases/.new-* "$base"/releases/.old-*
  return 0
}

# canccu_venv <requirements> <venv>: the monitor's packages, pinned, in a venv of their own, no
# sudo: with uv when there is one (it needs no ensurepip), else python3 -m venv and pip. Rebuilt
# only when the requirements change (their hash is kept in the venv). Fails with a warning: the
# dispatcher does not need the monitor.
canccu_venv() {
  local req=$1 venv=$2 want
  want=$(sha256sum < "$req" | cut -d' ' -f1)
  [ -x "$venv/bin/python" ] && [ "$(cat "$venv/.requirements.sha256" 2>/dev/null)" = "$want" ] && return 0
  mkdir -p "${venv%/*}" && rm -f "$venv/.requirements.sha256"
  if command -v uv >/dev/null 2>&1; then
    uv venv -q --allow-existing --python "$(command -v python3)" "$venv" >/dev/null 2>&1 &&
      uv pip install -q --python "$venv/bin/python" -r "$req" >/dev/null 2>&1
  else
    python3 -m venv "$venv" >/dev/null 2>&1 &&
      "$venv/bin/python" -m pip install -q --disable-pip-version-check -r "$req" >/dev/null 2>&1
  fi && echo "$want" > "$venv/.requirements.sha256" && echo "built the monitor's venv in $(canccu_tilde "$venv")" && return 0
  echo "install.sh: could not build the monitor's venv in $(canccu_tilde "$venv") (it needs uv, or python3 -m venv with pip: the python3-venv package); everything else is installed" >&2
  return 1
}

# canccu_state_config <tree> <host profile>: the state dir's two exceptions. A missing config is
# written with every default commented out (a later default then takes effect); a host profile
# is added to a config without the key. Nothing else of the state dir is ever touched.
canccu_state_config() {
  local f=$CANCCU_ROOT/config have
  if [ ! -e "$f" ]; then
    mkdir -p "$CANCCU_ROOT" && sed -E 's/^([A-Z_]+=)/# \1/' "$1/lib/canccu-config.default" > "$f" &&
      echo "wrote $(canccu_tilde "$f") (every default commented out)"
  fi
  [ -n "$2" ] || return 0
  have=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?HOST_PROFILE=//p' "$f" | tail -n1)
  if [ -z "$(grep -E '^[[:space:]]*(export[[:space:]]+)?HOST_PROFILE=' "$f")" ]; then
    printf 'HOST_PROFILE=%s\n' "$2" >> "$f" && echo "set HOST_PROFILE=$2 in $(canccu_tilde "$f")"
  elif [ "$have" != "$2" ]; then
    echo "$(canccu_tilde "$f") keeps HOST_PROFILE=$have (not changed to $2: edit it by hand)"
  fi
}
