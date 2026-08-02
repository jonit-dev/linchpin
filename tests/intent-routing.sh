#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'write a PRD for X' 5 "$fixture" "$fixture")" 'ROUTE-WRITE-PRD -> prd-creator'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'build X' 2 "$fixture" "$fixture")" 'ROUTE-BUILD-SMALL -> direct-edit-refusal'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'implement X' 3)" 'ROUTE-BUILD-LARGE -> prd-creator-confirm'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'execute these' 5 "$fixture" "$fixture")" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
nonconforming="$tmp_dir/nonconforming.md"
sed '/^prd_contract: v1$/d' "$fixture" > "$nonconforming"
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'run these' 5 "$nonconforming" "$fixture")" 'ROUTE-EXECUTE-UPGRADE -> prd-creator-upgrade'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'fix the typo' 5 "$fixture" "$fixture")" 'ROUTE-AMBIGUOUS -> ask-once'
pass 'intent wins over PRD state and all routing-table branches are exercised'
