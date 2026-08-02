#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
parsed=$(sh "$repo_root/scripts/linchpin.sh" files "$fixture")
[ "$(printf '%s\n' "$parsed" | wc -l | tr -d ' ')" -eq 3 ] || fail 'expected three parsed file entries'
broken="$tmp_dir/malformed.md"
sed 's/\*\*Files (1):\*\*/**Files (2):**/' "$fixture" > "$broken"
expect_failure 'Files (N) count mismatch' sh "$repo_root/scripts/linchpin.sh" files "$broken"
pass 'all phase file lists parse and malformed counts fail closed'
