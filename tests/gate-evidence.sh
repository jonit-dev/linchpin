#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
good="$fixture_dir/gate-observed-red.md"
sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$good" >/dev/null
expect_failure 'all-green report with no observed-red evidence' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$fixture_dir/gate-all-green.md"
pass 'every inherited gate requires observed-red evidence before PASS'
