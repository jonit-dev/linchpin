#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
parsed=$(sh "$repo_root/scripts/linchpin.sh" files "$fixture")
[ "$(printf '%s\n' "$parsed" | wc -l | tr -d ' ')" -eq 3 ] || fail 'expected three parsed file entries'
broken="$tmp_dir/malformed.md"
sed 's/\*\*Files (1):\*\*/**Files (2):**/' "$fixture" > "$broken"
expect_failure 'Files (N) count mismatch' sh "$repo_root/scripts/linchpin.sh" files "$broken"
imported="$tmp_dir/imported-entry.md"
sed 's/- `src\/alpha.md` - NEW:/- `src\/alpha.md` - IMPORT:/' "$fixture" > "$imported"
expect_failure 'legacy fourth file kind is rejected' sh "$repo_root/scripts/linchpin.sh" files "$imported"
pass 'all phase file lists parse and malformed counts fail closed'
