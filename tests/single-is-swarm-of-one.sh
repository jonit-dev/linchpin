#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

one="$tmp_dir/one.md"
two="$tmp_dir/two.md"
cp "$fixture_dir/conforming-prd.md" "$one"
cp "$fixture_dir/conforming-prd.md" "$two"
one_brief="$tmp_dir/one-brief.md"
two_brief="$tmp_dir/two-brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$one" > "$one_brief"
sh "$repo_root/scripts/linchpin.sh" brief "$two" > "$two_brief"
sed -E 's#^Source PRD:.*$#Source PRD: <lane>#' "$one_brief" > "$tmp_dir/one-shape"
sed -E 's#^Source PRD:.*$#Source PRD: <lane>#' "$two_brief" > "$tmp_dir/two-shape"
cmp -s "$tmp_dir/one-shape" "$tmp_dir/two-shape" || fail 'single lane brief shape differs from a batch lane'
sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$one_brief" >/dev/null
short="$tmp_dir/short.md"
sed '/| 2 | brief transfer/d' "$one_brief" > "$short"
expect_failure 'single-lane brief shortcut with omitted ledger row' sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$short"
pass 'one PRD uses the same brief and gate shape as any batch lane'
