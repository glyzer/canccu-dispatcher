# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by it, never run; bin/canccu-dispatcher's doctor reads docker_objs): the containers a run leaves (#238). A
# run's tag (run_tag) reaches it as CANCCU_RUN and COMPOSE_PROJECT_NAME (libexec/canccu-worker), so
# what it starts carries the tag as the label canccu.run or as its Compose project's name. They
# outlive the run, a test database the next run of the unit reuses, and go with their volumes
# once the unit ends: at its merge or close (unit_containers_rm), else at the next pass's sweep.
# Containers without a tag are never touched: the repo's own stack, the user's.

# docker_objs <container|volume|network> [all]: one "<id>\t<name>\t<state>\t<created>\t<tag>" line
# per object that has a tag of a run (all: every object, an empty tag for the rest); nothing when
# docker is missing or its daemon unreachable. One listing, filtered here: a filter per tag would
# cost a docker call per tag and pass.
docker_objs() {
  local f='{{.Label "canccu.run"}}\t{{.Label "com.docker.compose.project"}}'
  command -v docker >/dev/null || return 0
  case $1 in
    container) guard 30 docker ps -a --format "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.CreatedAt}}\t$f" ;;
    volume)    guard 30 docker volume ls --format "{{.Name}}\t{{.Name}}\t-\t-\t$f" ;;
    network)   guard 30 docker network ls --format "{{.ID}}\t{{.Name}}\t-\t-\t$f" ;;
  esac 2>/dev/null | awk -F '\t' -v OFS='\t' -v all="${2:-}" '{
      t = $5; if (t == "" && $6 ~ /^canccu_/) t = $6
      if (t != "" || all != "") print $1, $2, $3, $4, t }'
}

# run_tag_old <key>: the tag the run had before #317 (the project's "_" a "-"), for objects a unit
# open at the upgrade still has. Nothing when the project has no "_", or another project's name gives
# the same old tag: those objects may be that project's.
run_tag_old() {
  local p=${CANCCU_HOME##*/} o
  [[ $p == *_* ]] || return 0
  for o in "${CANCCU_HOME%/*}"/*/; do
    o=${o%/}; o=${o##*/}
    [ "$o" != "$p" ] && [ "${o//_/-}" = "${p//_/-}" ] && return 0
  done
  CANCCU_HOME=${CANCCU_HOME%/*}/${p//_/-} run_tag "$1"
}
# run_tags <key>: the run's tag, and its old one when it has one
run_tags() { run_tag "$1"; run_tag_old "$1"; }

# unit_tags <K>: the tags of the unit's runs: its worker, its answerer, its PR's reviewer
unit_tags() {
  local pr; pr=$(st_get "$1" pr)
  run_tags "$1"; run_tags "answer-$1"
  [ -n "$pr" ] && run_tags "review-$pr"
  return 0
}

# run_containers_rm <who> <tag...>: remove the containers, networks and volumes of those tags (a
# container first: a network or volume in use cannot go), and log what went, as "<who>: …"
run_containers_rm() {
  local who=$1 kind id name st cr t ids gone=""; shift
  local -A want=()
  for t; do want[$t]=1; done
  (( ${#want[@]} )) || return 0
  for kind in container network volume; do
    ids=()
    while IFS=$'\t' read -r id name st cr t; do
      [ -n "${want[$t]-}" ] || continue
      ids+=("$id"); gone+=" $kind $name"
    done < <(docker_objs "$kind")
    (( ${#ids[@]} )) || continue
    case $kind in
      container) mut docker rm -f -v "${ids[@]}" ;;
      *) mut docker "$kind" rm "${ids[@]}" ;;
    esac
  done
  [ -n "$gone" ] && log "$who: removed$gone"
  return 0
}

# unit_containers_rm <K>: the unit ended (merged, closed): what its runs started goes
unit_containers_rm() {
  # shellcheck disable=SC2046  # tags: one word each
  run_containers_rm "#$1" $(unit_tags "$1")
}

# containers_sweep: the tags of this project that nothing holds any more go: no unit with a state
# file names them, no live run has them, and no planner's worktree is there (a dropped unit, one
# the dispatcher was down for). A tag of this project is the prefix and a key with no "_": web's
# prefix canccu_web_ starts web_x's tags too. The old tags (run_tag_old) are the unit's to remove.
containers_sweep() {
  local pre l f k t id name st cr
  local -A keep=() seen=()
  pre="$(run_tag x)"; pre=${pre%x}
  for k in $(managed); do for t in $(unit_tags "$k"); do keep[$t]=1; done; done
  for l in "$WORKERS_DIR"/*.lock; do
    [ -e "$l" ] && lock_alive "$l" && keep[$(run_tag "$(lock_get "$l" key)")]=1
  done
  for f in "$WORKERS_DIR/worktrees/$REPO_NAME"/plan-*; do [ -d "$f" ] && keep[$(run_tag "${f##*/}")]=1; done
  for k in container network volume; do
    while IFS=$'\t' read -r id name st cr t; do
      [[ $t == "$pre"* && ${t#"$pre"} != *_* ]] && [ -z "${keep[$t]-}" ] && seen[$t]=1
    done < <(docker_objs "$k")
  done
  (( ${#seen[@]} )) || return 0
  run_containers_rm "sweep (no unit or run holds them)" "${!seen[@]}"
}
