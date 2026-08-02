#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
good="$fixture_dir/gate-observed-red.md"
sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$good" >/dev/null
sequential="$tmp_dir/sequential-report.md"
sed 's/Mode: parallel/Mode: sequential/' "$good" > "$sequential"
sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$sequential" >/dev/null
weakened="$tmp_dir/weakened.md"
sed '/| brief |/d' "$good" > "$weakened"
expect_failure 'parallel report with a weakened gate set' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$weakened"
expect_failure 'sequential report with a weakened gate set' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$weakened"
pass 'parallel and sequential lanes use the identical inherited gate set'
