# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Part of lib/canccu-common.sh (sourced by lib/canccu-notify.sh, never run): the images of the
# notifications (docs/reference/notify.md): once per passed head, the SVG files its PR changes,
# read from GitHub, rendered here and sent into the unit's topic.

# notify_photos <unit> <caption> <png...>: the images into the unit's newest open topic, else a
# new one; prints the first message id
notify_photos() {
  local k=$1 cap=$2 key th=- re=- m rc
  shift 2
  key=$(awk -F '\t' -v u="$k" '$3 == u && $5 == "open" { x = $1 } END { print x }' "$(notify_dir)/topics" 2>/dev/null)
  if [ -n "$key" ]; then
    if [[ $key == t* ]]; then th=${key#t}; else re=$(nt_get topics "$key" 6); re=${re:--}; fi
  elif [[ $TELEGRAM_CHAT_ID == -* ]] && m=$(tg_topic "#$k images"); then
    th=$m key=t$m; nt_add topics "$key	-	$k	-	open	-"
  fi
  m=$(tg_photos "$th" "$re" "$cap" "$@"); rc=$?
  # a timed-out upload may have landed: it counts as sent, as for a message
  if (( rc == 2 )); then log "telegram: sending the images for #$k timed out; they may have landed, so they are not sent again"; echo "?"; return 0; fi
  (( rc == 0 )) || { echo "$m"; return "$rc"; }
  [ -n "$key" ] || { key=m$m; nt_add topics "$key	-	$k	-	open	$m"; }
  nt_add msgs "$m	$key"
  log "telegram: sent $# image(s) for #$k"
  echo "$m"
}

# notify_svgs <unit> <pr> <sha>: the SVG files the PR changes, read from GitHub at that head and
# rendered here. Never a link from the PR body: that is worker text, and fetching it would send
# the host to any URL. 1 on a gh error (tried again next pass).
notify_svgs() {
  local files p d i=0 out=() svgs=() err
  files=$(pr_files_raw "$2") || return 1
  mapfile -t svgs < <(cut -f1 <<<"$files" | grep -iE '^[A-Za-z0-9._/-]+\.svg$' | head -n 10)
  (( ${#svgs[@]} )) || return 0
  command -v rsvg-convert >/dev/null || { warn_once notify-svg "telegram: rsvg-convert is not installed: the SVGs a PR changes are not sent"; return 0; }
  d=$(mktemp -d) || return 1
  for p in "${svgs[@]}"; do
    i=$((i + 1))
    # a file the PR deletes is not there at the head (404): nothing to show; any other error is
    # transient, so the head is not recorded as done and the next pass tries again
    if ! err=$(ghj api "repos/$REPO/contents/$p?ref=$3" -H 'Accept: application/vnd.github.raw' 2>&1 > "$d/$i.svg"); then
      [[ $err == *"(HTTP 404)"* ]] && continue
      rm -rf "$d"; return 1
    fi
    timeout 30 rsvg-convert -o "$d/$i.png" "$d/$i.svg" >/dev/null 2>&1 && [ -s "$d/$i.png" ] && out+=("$d/$i.png")
  done
  local rc=0
  (( ${#out[@]} )) && { notify_photos "$1" "PR #$2 changes ${#out[@]} SVG file(s), rendered at ${3:0:7}"$'\n'"$(pr_url "$2")" "${out[@]}" >/dev/null || rc=1; }
  rm -rf "$d"; return "$rc"
}
# notify_images: once per passed head, the SVGs its PR changes. Only under NOTIFY_CONTENT=full:
# otherwise only a first line, a last line and a link leave the host (contracts §4).
notify_images() {
  local k pr sha
  [ "${NOTIFY_CONTENT:-full}" = full ] || return 0
  for k in $(managed); do
    pr=$(st_get "$k" pr); sha=$(st_get "$k" pass_sha)
    [ -n "$pr" ] && [ -n "$sha" ] || continue
    [ "$(nt_get images "$pr" 2)" = "$sha" ] && continue
    notify_svgs "$k" "$pr" "$sha" || continue
    if [ -n "$(nt_get images "$pr" 1)" ]; then nt_put images "$pr" 2 "$sha"; else nt_add images "$pr	$sha"; fi
  done
}
