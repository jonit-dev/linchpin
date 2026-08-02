#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
sh "$repo_root/scripts/linchpin.sh" contract "$fixture" >/dev/null
broken="$tmp_dir/no-marker.md"
sed '/^prd_contract: v1$/d' "$fixture" > "$broken"
expect_failure 'removed prd_contract marker' sh "$repo_root/scripts/linchpin.sh" contract "$broken"
pass 'conforming marker and required sections are machine-checkable'
