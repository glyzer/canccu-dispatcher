# SPDX-License-Identifier: AGPL-3.0-or-later
# lib/canccu-plan.jq — validates a planner's package plan (schema 1). Run by plan_validate:
#   jq -n --argjson plan P --argjson input I --argjson m M --argjson w W -f lib/canccu-plan.jq
# → {errors: [strings], left_out: [issue numbers]}. The schema is in docs/canccu-dispatch.md,
# "Work packages per step". Issues the plan leaves out are no error: they join the next wave.

def strs: type == "array" and all(.[]; type == "string");
def known: [$input.issues[]?.number];
# the earlier waves' unfinished packages the dispatcher carries into this plan: a package may
# depend on one (it waits for its merge); they are outside the graph (they never depend on these)
def carried: [$input.carried[]?.name];
# an earlier package of the step merged since (while the planner ran): met
def merged: [$input.merged[]?.name];

($plan.packages) as $ps
| (if ($ps | type) == "array" then $ps else [] end) as $pk
| [ $pk[] | select(type == "object") ] as $obj
| [ $obj[] | .name | select(type == "string") ] as $names
# the dependency graph among named packages, without self and unknown edges
| ( [ $obj[] | select(.name | type == "string") | .name as $x
      | { key: $x, value: [ (.depends_on // []) | if strs then .[] else empty end
                            | select(. != $x and IN($names[])) ] } ]
    | from_entries ) as $g
# drop packages none of whose dependencies is left, until nothing changes: what stays is on or
# behind a cycle; walking dependencies inside it from its first package finds one cycle
| ( ($g | keys)
    | until(. as $l | [ $l[] | select(. as $n | $g[$n] | any(.[]; IN($l[]))) ] == $l;
            . as $l | [ $l[] | select(. as $n | $g[$n] | any(.[]; IN($l[]))) ]) ) as $cyc
| ( if ($cyc | length) == 0 then null
    else { path: [$cyc[0]], at: $cyc[0] }
      | until(. as $s | $s.path[:-1] | index($s.at) != null;
              .at = ($g[.at] | map(select(IN($cyc[]))) | first) | .path += [.at])
      | .path as $p | ($p | index($p[-1])) as $i | $p[$i:] | join(" → ") end ) as $cycle
| { errors: (
      [ (if $plan | type != "object" then "the plan is not an object" else empty end),
        (if $plan.schema != 1 then "schema is not 1" else empty end),
        (if $plan.step != $m then "step is not \($m)" else empty end),
        (if $plan.wave != $w then "wave is not \($w)" else empty end),
        (if ($ps | type) != "array" or ($ps | length) == 0 then "packages is empty or not a list" else empty end) ]
    + [ $pk | to_entries[] | .key as $i | .value
        | if type != "object" then "package \($i + 1): not an object"
          elif (.name | type) != "string" or (.name | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)
               or (.name | length) > 30 or .name == "health"
          then "package \($i + 1): bad name \(.name | tojson)" else empty end ]
    + [ $names | group_by(.) | .[] | select(length > 1) | "duplicate package name \(.[0])" ]
    + [ $names | unique[] | select(IN($input.earlier[]?.name)) | "package name \(.) was used by an earlier package" ]
    + [ $obj[] | (.name // "?") as $x
        | (if (.issues | type) != "array" or (.issues | length) == 0 then "\($x): no issues"
           elif any(.issues[]; type != "number") then "\($x): issues must be numbers" else empty end),
          (if (.risk | IN("low", "normal", "high")) | not then "\($x): risk missing or not low|normal|high" else empty end),
          (if (.risk_reason | type) != "string" or (.risk_reason | test("\\S") | not) then "\($x): risk_reason missing" else empty end),
          (if (.areas | strs) | not then "\($x): areas is not a list of strings" else empty end),
          (if ((.depends_on // []) | strs) | not then "\($x): depends_on is not a list of names" else empty end) ]
    + [ [ $obj[] | (.name // "?") as $x | (.issues // [] | if type == "array" then .[] else empty end) | numbers | {n: ., x: $x} ]
        | group_by(.n) | .[] | select(length > 1)
        | "issue #\(.[0].n) is in more than one package (\(map(.x) | join(", ")))" ]
    + [ [ $obj[] | .issues // [] | if type == "array" then .[] else empty end | numbers ] | unique[]
        | select(IN(known[]) | not) | "issue #\(.) is unknown (not an open, unblocked ready issue of this step)" ]
    + [ $obj[] | (.name // "?") as $x | (.depends_on // []) | if strs then .[] else empty end
        | if . == $x then "\($x) depends on itself"
          elif (IN($names[]) or IN(carried[]) or IN(merged[]) | not) then "\($x) depends on unknown package \(.)" else empty end ]
    + [ if $cycle then "dependency cycle: \($cycle)" else empty end ] ),
    left_out: [ known[] | select(IN([ $obj[] | .issues // [] | if type == "array" then .[] else empty end ][]) | not) ] }
