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

# A PRD the user points at executes as written. A missing marker is advisory,
# never an admission gate: routing it to authoring is how a user's document got
# rewritten instead of run.
nonconforming="$tmp_dir/nonconforming.md"
sed '/^prd_contract: v1$/d' "$fixture" > "$nonconforming"
nonconforming_route=$(sh "$repo_root/scripts/linchpin.sh" route 'run these' 5 "$nonconforming" "$fixture")
assert_contains "$nonconforming_route" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
assert_contains "$nonconforming_route" "ADVISORY $nonconforming"
case "$nonconforming_route" in
  *prd-creator*) fail 'a user-supplied PRD was routed to authoring instead of execution' ;;
esac

# The one real execution blocker is a path that is not there.
missing_route=$(sh "$repo_root/scripts/linchpin.sh" route 'start these' "$tmp_dir/not-a-file.md")
assert_contains "$missing_route" 'ROUTE-EXECUTE-NONE -> ask-once'
assert_contains "$missing_route" 'MISSING-PRD-PATH'

# ...and it blocks itself, not the batch beside it. A real paste carries a bare
# directory and one path that moved; the survivors still run.
partial_route=$(sh "$repo_root/scripts/linchpin.sh" route 'execute' . "$fixture" "$tmp_dir/not-a-file.md")
assert_contains "$partial_route" 'MISSING-PRD-PATH'
assert_contains "$partial_route" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
assert_contains "$partial_route" 'is a directory, not a PRD'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'fix the typo' 5 "$fixture" "$fixture")" 'ROUTE-AMBIGUOUS -> ask-once'
pass 'intent wins over PRD state and all routing-table branches are exercised'
