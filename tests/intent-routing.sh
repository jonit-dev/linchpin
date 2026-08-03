#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'write a PRD for X' 5 "$fixture" "$fixture")" 'ROUTE-WRITE-PRD -> prd-creator'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'build X' 2 "$fixture" "$fixture")" 'ROUTE-BUILD-SMALL -> direct-edit-refusal'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'implement X' 3)" 'ROUTE-BUILD-LARGE -> prd-creator-confirm'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'execute these' 5 "$fixture" "$fixture")" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'execute these' "$fixture")" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
# "start/begin/launch these PRDs" is an execution intent. Reading it as a write
# intent is how an existing PRD gets rewritten instead of executed.
for execute_phrasing in 'start PRD 007 to 010' 'begin these PRDs' 'launch the swarm on these' 'resume these PRDs'; do
  assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route "$execute_phrasing" "$fixture" "$fixture")" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
done
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'write a new PRD for X')" 'ROUTE-WRITE-PRD -> prd-creator'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'draft a PRD for X')" 'ROUTE-WRITE-PRD -> prd-creator'
start_route=$(sh "$repo_root/scripts/linchpin.sh" route 'start PRD 007 to 010' "$fixture")
case "$start_route" in
  *ROUTE-WRITE-PRD*) fail 'an execution intent was routed to PRD authoring' ;;
esac

nonconforming="$tmp_dir/nonconforming.md"
sed '/^prd_contract: v1$/d' "$fixture" > "$nonconforming"
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'run these' 5 "$nonconforming" "$fixture")" 'ROUTE-EXECUTE-UPGRADE -> prd-creator-upgrade'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'fix the typo' 5 "$fixture" "$fixture")" 'ROUTE-AMBIGUOUS -> ask-once'
pass 'intent wins over PRD state and all routing-table branches are exercised'
