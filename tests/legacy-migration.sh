#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

helper="$repo_root/scripts/linchpin.sh"
legacy="$tmp_dir/legacy-prd.md"
cp "$fixture_dir/legacy-prd.md" "$legacy"
original_checksum=$(cksum < "$legacy")

# A legacy artifact is non-conforming before migration.
expect_failure 'legacy PRD before migration' sh "$helper" contract "$legacy"

migrated_out=$(sh "$helper" migrate "$legacy")
assert_contains "$migrated_out" "ORIGINAL-PRESERVED $legacy"
assert_contains "$migrated_out" 'MIGRATED'
[ "$(cksum < "$legacy")" = "$original_checksum" ] || fail 'migrate modified the original PRD'

migrated="$tmp_dir/legacy-prd.v1.md"
[ -f "$migrated" ] || fail 'migrate did not write the v1 artifact'
sh "$helper" contract "$migrated" >/dev/null || fail 'migrated artifact is not conforming'
assert_contains "$(sh "$helper" files "$migrated")" 'src/alpha.md'
assert_contains "$(sh "$helper" route 'start these' "$migrated")" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'

# Re-running is idempotent and never overwrites a migration by accident.
assert_contains "$(sh "$helper" migrate "$migrated")" "ALREADY-CONFORMING $migrated"
expect_failure 'migrate refuses to clobber an existing target' sh "$helper" migrate "$legacy"

# Observed red: a legacy artifact with no negative controls cannot be stamped
# conforming by the migration path.
gapped="$tmp_dir/gapped.md"
awk '/^## 5[.] Negative Controls$/ { skip = 1 } /^## 6[.] Acceptance/ { skip = 0 } !skip { print }' \
  "$fixture_dir/legacy-prd.md" > "$gapped"
expect_failure 'legacy PRD without negative controls' sh "$helper" migrate "$gapped"
if grep -Fq 'prd_contract: v1' "$tmp_dir/gapped.v1.md"; then
  fail 'incomplete migration claimed the contract marker'
fi
grep -Fq 'MIGRATION-TODO' "$tmp_dir/gapped.v1.md" || fail 'incomplete migration named no remaining work'

pass 'legacy migration preserves the original, produces a v1 artifact, and withholds the marker when gaps remain'
