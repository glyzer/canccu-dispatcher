#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/canccu-mergemethod.sh — offline tests for merge_method_read: an answer that is not a known
# method word is never taken as the merge method (the harness: tests/lib/harness.sh).
# shellcheck source=lib/harness.sh
. "$(dirname "$0")/lib/harness.sh"

# an unexpected answer to the settings query (a gh error body, several lines, exit 0 or 1) is
# never taken as the method: no `--{` flag, the merge goes on as for `unknown`
for rc in 0 1; do
  review_env method-garbage-$rc 'Review verdict: pass' review
  mkdir -p "$E/sbin"
  cat > "$E/sbin/gh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "api graphql" ] && [[ "\$*" == *mergeQueue* ]]; then
  printf '{\n  "message": "Bad credentials",\n  "documentation_url": "x"\n}\n'; exit $rc
fi
exec "$fb/gh" "\$@"
SH
  chmod +x "$E/sbin/gh"
  PATH="$E/sbin:$fb:$PATH" CANCCU_WORKER="$fb/worker" "$root/bin/canccu-dispatch" --once > "$E/out" 2>&1
  ok "an error body from the settings query (exit $rc) → no method flag taken from it" hasnt gh.log "--{"
  ok "… the merge goes on as for unknown (auto, no method)" has gh.log "pr merge 50 -R example-org/web --auto --match-head-commit $HA"
  ok "… the text is logged once, on one line" eq "$(grep -c 'merge method answer' "$CANCCU_HOME/dispatch.log")" 1
done

echo "canccu-mergemethod tests: $npass passed, $nfail failed"
(( nfail == 0 ))
