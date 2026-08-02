#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

one="$tmp_dir/one.md"
two="$tmp_dir/two.md"
cp "$fixture_dir/conforming-prd.md" "$one"
cp "$fixture_dir/conforming-prd.md" "$two"
one_brief="$tmp_dir/one-brief.md"
many_one_brief="$tmp_dir/many-one-brief.md"
many_two_brief="$tmp_dir/many-two-brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$one" lane-1 parallel branch > "$one_brief"
sh "$repo_root/scripts/linchpin.sh" brief "$one" lane-1 parallel branch > "$many_one_brief"
sh "$repo_root/scripts/linchpin.sh" brief "$two" lane-2 parallel branch > "$many_two_brief"
sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$one_brief" >/dev/null
sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$many_one_brief" >/dev/null
sh "$repo_root/scripts/linchpin.sh" brief-check "$two" "$many_two_brief" >/dev/null
for brief_file in "$one_brief" "$many_one_brief" "$many_two_brief"; do
  sed -E 's#^(Source PRD: ).*$#\1<lane>#; s#^(Lane identity: ).*$#\1<lane>#' "$brief_file" > "$brief_file.shape"
done
cmp -s "$one_brief.shape" "$many_one_brief.shape" || fail 'single lane brief shape differs from a many-lane brief'
cmp -s "$many_one_brief.shape" "$many_two_brief.shape" || fail 'many-lane brief shapes differ'
short="$tmp_dir/short.md"
sed '/| 2 | brief transfer/d' "$one_brief" > "$short"
expect_failure 'single-lane brief shortcut with omitted ledger row' sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$short"
sed '/| brief |/d' "$one_brief" > "$tmp_dir/no-negative-row.md"
expect_failure 'many-lane brief with omitted negative-control row' sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$tmp_dir/no-negative-row.md"
sed '/- \[ \] The complete ledger appears/d' "$one_brief" > "$tmp_dir/no-acceptance-line.md"
expect_failure 'many-lane brief with omitted acceptance line' sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$tmp_dir/no-acceptance-line.md"
sed '/negative-control result before declaring/d' "$one_brief" > "$tmp_dir/no-checkpoint-line.md"
expect_failure 'many-lane brief with omitted checkpoint line' sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$tmp_dir/no-checkpoint-line.md"
sed '/^Lane mode:/d' "$one_brief" > "$tmp_dir/no-metadata.md"
expect_failure 'single-lane brief with malformed metadata' sh "$repo_root/scripts/linchpin.sh" brief-check "$one" "$tmp_dir/no-metadata.md"
pass 'one PRD uses the same brief and gate shape as any batch lane'
