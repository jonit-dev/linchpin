#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

a="$tmp_dir/a.md"
b="$tmp_dir/b.md"
c="$tmp_dir/c.md"
cp "$fixture_dir/conforming-prd.md" "$a"
cp "$fixture_dir/conforming-prd.md" "$b"
cp "$fixture_dir/conforming-prd.md" "$c"
sed -i 's#src/alpha.md#src/charlie.md#g; s#src/shared.md#docs/charlie.md#g; s#scripts/linchpin.sh#docs/charlie-run.md#g' "$c"
mixed=$(sh "$repo_root/scripts/linchpin.sh" mode auto "$a" "$b" "$c")
assert_contains "$mixed" 'mode=sequential'
assert_contains "$mixed" 'mode=parallel'
printf '%s\n' "$mixed" | grep -F "$a,$b" >/dev/null || fail 'intersecting lanes were not grouped sequentially'
all_disjoint=$(sh "$repo_root/scripts/linchpin.sh" mode auto "$a" "$c")
if printf '%s\n' "$all_disjoint" | grep -q 'mode=sequential'; then
  fail 'disjoint lanes were made sequential'
fi
expect_failure 'forced parallel on intersecting Files (N)' sh "$repo_root/scripts/linchpin.sh" mode parallel "$a" "$b"
pass 'mode selection is per collision group and forced parallel fails loudly'
