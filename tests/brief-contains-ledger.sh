#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
brief_file="$tmp_dir/brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture" > "$brief_file"
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$brief_file" >/dev/null
short_brief="$tmp_dir/short-brief.md"
sed '/| 2 | brief transfer/d' "$brief_file" > "$short_brief"
expect_failure 'brief with a deleted ledger row' sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$short_brief"
pass 'worker brief contains every ledger row, caller, and negative control'
