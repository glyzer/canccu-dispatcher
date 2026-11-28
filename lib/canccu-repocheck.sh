# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# repo_check: what the target repo still lacks of docs/repo-contract.md, read with GET calls only
# (canccu-init --check, canccu-dispatcher doctor --project). Sourced by canccu-common.sh, for the
# project it loaded. It never fixes anything: the project's narrow token may not write settings.

RC_DOCS=https://github.com/glyzer/canccu-dispatcher/blob/main/docs

# _rc_get <gh args...>: one read through ghj; its output in RC_OUT, gh's error in RC_ERR. Not
# called in $(…), which would lose both.
_rc_get() {
  local f rc
  f=$(mktemp 2>/dev/null) || { RC_OUT="" RC_ERR="mktemp failed"; return 1; }
  RC_OUT=$(ghj "$@" 2>"$f"); rc=$?
  RC_ERR=$(<"$f"); rm -f "$f"
  return "$rc"
}
# _rc_code: the HTTP status of the last failed read, or nothing (no answer at all)
_rc_code() { grep -oE 'HTTP [0-9]{3}' <<<"$RC_ERR" | head -1 | cut -c6-; }
_rc_404() { [ "$(_rc_code)" = 404 ]; }
_rc() { printf '%s\t%s\n' "$1" "$2"; }
_rc_unknown() { _rc unknown "$1: unknown ($(oneline 80 "${RC_ERR:-no output}"))"; }
# _rc_blob <file>: its git blob sha, which the contents API gives as .sha; computed here, as git
# hash-object does, so it needs no repo and no git on the way
_rc_blob() { { printf 'blob %s\0' "$(stat -c %s "$1")"; cat "$1"; } | sha1sum | cut -d' ' -f1; }

# repo_check <tree>: one line per finding, "<state>\t<text>", state missing, unknown or note;
# nothing for a piece that is there. Only a missing line asks for a fix: unknown is what the
# narrow token cannot read (variables, protection), a note what a repo may well have chosen.
repo_check() {
  local tree=$1 d=$RC_DOCS am f p n rules="" ru="" prot="" pu="" pread=0 miss=""
  if ! _rc_get api "repos/$REPO" --jq .allow_auto_merge; then
    # a rate limit says 403 too, and is no answer about the repo
    if [[ $(_rc_code) =~ ^(401|403|404)$ ]] && ! grep -qi 'rate limit' <<<"$RC_ERR"; then
      _rc missing "the repo $REPO is not reachable with this project's gh login: $d/reference/projects.md#a-narrow-token-per-project"
    else _rc_unknown repo; fi
    return 0
  fi
  am=$RC_OUT

  if [ -z "$REVIEWER_LOGIN" ]; then
    _rc missing "REVIEWER_LOGIN is not set ($(login_where)): $d/getting-started.md"
  else
    if _rc_get api "repos/$REPO/collaborators/$REVIEWER_LOGIN/permission" --jq .permission; then
      [[ $RC_OUT =~ ^(write|admin)$ ]] || _rc missing "$REVIEWER_LOGIN has no write access to $REPO: add it as a collaborator and accept the invitation as the bot: $d/repo-contract.md"
    elif _rc_404; then
      _rc missing "$REVIEWER_LOGIN has no write access to $REPO: add it as a collaborator and accept the invitation as the bot: $d/repo-contract.md"
    else _rc_unknown bot; fi
    if _rc_get api "repos/$REPO/actions/variables/REVIEWER_LOGIN" --jq .value; then
      [ "$RC_OUT" = "$REVIEWER_LOGIN" ] || _rc missing "the repo variable REVIEWER_LOGIN is $RC_OUT, not $REVIEWER_LOGIN: $d/repo-contract.md"
    elif _rc_404; then _rc missing "the repo variable REVIEWER_LOGIN is not set: $d/repo-contract.md"
    else _rc_unknown variable; fi
  fi

  while IFS= read -r f; do
    p=.github/${f#"$tree/templates/repo/.github/"}
    if _rc_get api "repos/$REPO/contents/$p?ref=$BASE_BRANCH" --jq .sha; then
      [ "$RC_OUT" = "$(_rc_blob "$f")" ] || _rc note "$p differs from this version's template (changed by you, or older)"
    elif _rc_404; then _rc missing "$p is not on $BASE_BRANCH: copy it from templates/repo/.github/: $d/repo-contract.md"
    else _rc_unknown "review gate $p"; fi
  done < <(find "$tree/templates/repo/.github" -type f | sort)

  if _rc_get api "repos/$REPO/commits/$BASE_BRANCH/check-runs?check_name=CI" --jq .total_count; then
    [ "$RC_OUT" != 0 ] || _rc missing "no check named CI on the latest commit of $BASE_BRANCH: $d/repo-contract.md"
  elif _rc_404; then _rc missing "no check named CI on the latest commit of $BASE_BRANCH: $d/repo-contract.md"
  else _rc_unknown CI; fi

  # a check may be required by a ruleset or by the classic protection; the protection is read only
  # for a check the rules lack, as the narrow token often cannot read it
  if _rc_get api "repos/$REPO/rules/branches/$BASE_BRANCH" --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context'; then
    rules=$RC_OUT
  elif ! _rc_404; then ru=$RC_ERR; fi
  for n in $(printf '%s\n' CI $REVIEW_CHECKS | awk 'NF && !s[$0]++'); do
    grep -qxF -- "$n" <<<"$rules" && continue
    if (( ! pread )); then
      pread=1
      if _rc_get api "repos/$REPO/branches/$BASE_BRANCH/protection" --jq '.required_status_checks | ((.contexts // [])[]), ((.checks // [])[].context)'; then
        prot=$RC_OUT
      elif ! _rc_404; then pu=$RC_ERR; fi
    fi
    grep -qxF -- "$n" <<<"$prot" && continue
    if [ -n "$pu$ru" ]; then RC_ERR=${pu:-$ru}; _rc_unknown "required $n"
    else _rc missing "the check $n is not required on $BASE_BRANCH: add it to a ruleset: $d/repo-contract.md"; fi
  done

  [ "$am" != false ] || _rc note "auto-merge is off: the dispatcher merges directly"

  if _rc_get label list -R "$REPO" -L 300 --json name; then
    f=$(jqr '.[].name' <<<"$RC_OUT")
    for n in $CANCCU_LABELS; do grep -qxF -- "$n" <<<"$f" || miss+=", $n"; done
    [ -z "$miss" ] || _rc missing "labels missing: ${miss#, } (canccu-dispatch creates them on its next pass)"
  else _rc_unknown labels; fi
  return 0
}
