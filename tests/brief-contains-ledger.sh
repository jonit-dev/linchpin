#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
brief_file="$tmp_dir/brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-brief parallel branch > "$brief_file"
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$brief_file" >/dev/null
default_brief="$tmp_dir/default-brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture" > "$default_brief"
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$default_brief" >/dev/null
grep -F 'Lane identity: lane-1' "$default_brief" >/dev/null || fail 'default brief path omitted lane metadata'
grep -F 'Runtime invocation: worker=' "$default_brief" >/dev/null || fail 'default brief path omitted runtime metadata'
short_brief="$tmp_dir/short-brief.md"
sed '/| 2 | brief transfer/d' "$brief_file" > "$short_brief"
expect_failure 'brief with a deleted ledger row' sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$short_brief"
pass 'worker brief contains every ledger row, caller, and negative control'
