# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash disable=SC2034,SC2154  # globals are shared with the other lib/canccu-*.sh parts
# Sourced by canccu-common.sh; never run: starting work packages and the health pass. A package
# runs through the pipeline like an issue, keyed by its unit key (lib/canccu-units.sh).
# docs/canccu-dispatch.md, "Work packages per step".

# package_prompt <K>: the worker prompt of a package (one issue: branch <n>-<slug>)
package_prompt() {
  local k=$1 nm br list closes plan m
  nm=$(st_get "$k" pkg) br=$(unit_branch "$k")
  list=$(members_of "$k" | sed 's/^/#/' | paste -sd, | sed 's/,/, /g')
  closes=$(members_of "$k" | sed 's/^/`Closes #/; s/$/`/' | paste -sd, | sed 's/,/, /g')
  if is_pkg "$k"; then plan="docs/plans/$br.md"; else plan="docs/plans/issue-$k.md"; fi
  echo "You are working on $REPO work package \"$nm\" in this worktree: issues $list, in that order. Follow AGENTS.md and the \`<n>\` / \`execute\` / \`finish\` flow in CLAUDE.md for each issue, with these overrides: do all the issues of the package on one branch, $br, created from origin/main in this worktree, and open one PR for the whole package; continue without waiting on fix and feature tiers (put each feature plan in the PR description); if an issue needs the plan tier, write $plan for the package, open a draft PR whose body has a \`Plan for #<n>\` line for each issue instead of the \`Closes\` lines (merging the plan must not close them) and stop. Never split an issue into several, never create issues, and never work on an issue outside the package. You may use the superpowers skills subagent-driven-development and dispatching-parallel-agents to work on the package's issues in parallel, but skip their review steps (no spec or code-quality reviewer subagents, no requesting-code-review): an independent reviewer reviews the PR afterwards. Use test-driven-development, systematic-debugging and verification-before-completion. Do NOT use brainstorming, using-git-worktrees, finishing-a-development-branch, requesting-code-review or writing-skills. Code comments follow the comment rule in AGENTS.md. When you notice work outside the package, do not do it: add a line \`Follow-up: <what>\` to the PR body; when the plan of the steps itself should change, add \`Roadmap note: <what>\`. The PR body has one \`Closes #<n>\` line for each issue ($closes), a line \`Package: $nm\`, a line \`Risk: <low|normal|high> — <why>\` (the plan rated it $(st_get "$k" risk): $(st_get "$k" risk_reason); raise it if the work turned out riskier, never lower it), a \`Tier: fix|feature|plan\` line and \`Decisions made:\`.$([ "$(st_get "$k" plan_ok)" = 1 ] && echo " $(plan_merged_text "$plan")") $(common_rules)"
}
# common_rules: the end of every package and health prompt
common_rules() {
  echo "Before marking the PR ready, run the checks of every module you touched. While working, run only the tests of the files you change; run the full suite once, just before pushing; never paste whole test logs into the conversation. Do not review your own work; run the checks only. If you must stop with a question, write it on its own line starting \`Question:\` and stop. If an issue is still blocked (an open blocker), build nothing, open no PR and stop with the status \`blocked\` and what it waits on. When resumed with review findings, fix them, rerun the checks, push once. To bring in main, run \`git merge origin/main\` and push normally; never rebase or force-push a PR branch (the squash-merge flattens it). Do NOT enable auto-merge, never merge, and never add or remove the \`accepted\` label: stop when the PR is ready and CI is green.${WORKER_EXTRA:+ $WORKER_EXTRA} Stop and say why on: a question, a destructive migration, a breaking contract change, a blocked command, or CI red after two fix rounds. End with a 5-line report: status, PR URL, what changed, verification, next action."
}

# start_package <m> <name> <issues "a b"> <risk> <reason>: claim the package's issues and start its worker
start_package() {
  local m=$1 nm=$2 is=$3 k br c=0 i n budget rc p="" pl=()
  # every issue is checked against GitHub here, whatever the plan says: only the dispatcher's
  # rule (eligible_issue) lets an issue be built
  for i in $is; do eligible_issue "$m" "$i" || { log "step $(step_title "$m"): package $nm not started: #$i is not an eligible issue of the step"; return 2; }; done
  k=$(package_key "$m" "$nm" "$is")
  if is_pkg "$k"; then br=$k; else br="$k-$(slug "$(jqr --argjson n "$k" '.[] | select(.number == $n) | .title' <<<"$ISSUES")")"; fi
  for i in $is; do is_exclusive "$i" && c=1; done
  # plan-ok on its issues: their plan PR merged (plan_back); the build executes that plan
  for i in $is; do has_label "$i" plan-ok && p=1 pl=(--remove-label plan-ok); done
  st_set "$k" plan_ok=$p pkg="$nm" step="$m" wave="$(step_get "$m" wave)" members="$is" branch="$br" risk="$4" risk_reason="$(oneline 200 "$5")" exclusive=$c
  n=$(unit_size "$k"); budget=$(pkg_budget "$BUDGET_WORK" "$n")
  run_worker "$k" "$(package_prompt "$k")" "$budget" || { rc=$?; st_rm "$k"; (( rc == SLOT_REFUSED )) && return "$rc"; return 1; }
  took_slot
  edit_members "$k" --add-label in-progress --remove-label ready --add-assignee "$USER_LOGIN" "${pl[@]}"
  new_cycle "$k"; step_key "$m" "$k"
  log "#$k started: package $nm (${is// /, }; $4 risk) of step $(step_title "$m")"
}

# start_packages <m>: the wave's packages whose dependencies are merged, in plan order, while
# slots are free (also while the next wave is planned: a dependant whose waiting dependency merged
# meanwhile starts at once); the one-at-a-time lock holds for packages too
start_packages() {
  local m=$1 nm is rk dep busy i ex rc held=0
  case $(step_get "$m" phase) in running|planning) ;; *) return 0 ;; esac
  [ "$(step_get "$m" ny_kind)" != stop ] || return 0
  step_blocked_to_start "$m" && return 0
  busy=$(exclusive_busy)
  while IFS=$'\t' read -r nm is rk dep; do
    [ -n "$nm" ] || continue
    [ "$(package_status "$m" "$nm")" = pending ] || continue
    ex=0; for i in $is; do is_exclusive "$i" && ex=1; done
    (( ex )) && [ -n "$busy" ] && continue
    # once one finds no shared slot, it and every other startable package wait for one
    if (( held )); then want_held "$m/$nm"; continue; fi
    take_slot "$m/$nm" || { held=1; continue; }
    start_package "$m" "$nm" "$is" "$rk" "$(jqr --arg n "$nm" '.packages[] | select(.name == $n) | .risk_reason' "$(step_get "$m" plan)")"; rc=$?
    case $rc in
      0) ;;
      2) continue ;;
      "$SLOT_REFUSED") held=1; continue ;;   # the engine noted its wait
      *) break ;;
    esac
    (( ex )) && busy=$nm
  done < <(plan_packages "$m")
  return 0
}

# health_prompt <m> <K>: the health pass of a finished step
health_prompt() {
  local m=$1 prs
  prs=$(awk -F '\t' '$6 != "" { printf "#%s, ", $6 }' "$CANCCU_HOME/steps/$m.packages" 2>/dev/null); prs=${prs%, }
  echo "You run the HEALTH PASS for $REPO step \"$(step_title "$m")\" in this worktree. Every issue of the step is closed; its PRs were ${prs:-none recorded} (read them with gh pr view <n> -R $REPO and gh pr diff <n> -R $REPO). Work only on the files those PRs touched and the code right around them. The checklist, and nothing else: 1. files over the size limit in AGENTS.md are split up; 2. dead code for dropped features and old names is removed; 3. comments follow the comment rule in AGENTS.md; 4. duplicated logic is merged. Change no behaviour. Create the branch $2 from origin/main in this worktree and open one PR with the lines \`Package: health\`, \`Step: $(step_title "$m")\` and \`Risk: <normal|high> — <why>\` (high if you touched $HIGH_RISK_TEXT), and no \`Closes\` line. If nothing on the checklist needs changing, open no PR and end with the line \`Health: nothing to do\`. Use test-driven-development, systematic-debugging and verification-before-completion; do NOT use brainstorming, using-git-worktrees, finishing-a-development-branch, requesting-code-review, subagent-driven-development, dispatching-parallel-agents or writing-skills. $(common_rules)"
}

# start_health <m>: the step's one health pass
start_health() {
  local m=$1 k="pkg-$1-health"
  [ "$(step_get "$m" ny_kind)" != stop ] || return 1
  step_blocked_to_start "$m" && return 1
  take_slot "$k" || return 1
  st_set "$k" pkg=health step="$m" health=1 members= branch="$k" risk=normal risk_reason="the health pass" exclusive=0
  if ! run_worker "$k" "$(health_prompt "$m" "$k")" "$BUDGET_HEALTH"; then st_rm "$k"; return 1; fi
  took_slot; new_cycle "$k"; step_key "$m" "$k"
  step_set "$m" phase=health health=running
  log "#$k started: the health pass of step $(step_title "$m")"
}

# health_nothing <K>: the health worker found nothing to change (no PR, "Health: nothing to do")
health_nothing() {
  local k=$1 m; m=$(st_get "$k" step)
  step_set "$m" health=skipped
  st_set "$k" skipped=1
  log "#$k: nothing to do; the checkpoint follows"
}
