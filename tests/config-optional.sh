#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

defaults=$(sh "$repo_root/scripts/linchpin.sh" config "$tmp_dir")
assert_contains "$defaults" 'execution=auto'
assert_contains "$defaults" 'delivery=pr'
assert_contains "$defaults" 'review=true'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'build X' 2)" 'direct-edit-refusal'
config_dir="$tmp_dir/config-target"
mkdir -p "$config_dir"
printf '%s\n' 'execution=sequential' 'delivery=branch' 'review=false' 'max_lanes=2' 'prd_floor=4' > "$config_dir/.linchpin.toml"
configured=$(sh "$repo_root/scripts/linchpin.sh" config "$config_dir")
assert_contains "$configured" 'execution=sequential'
assert_contains "$configured" 'delivery=branch'
assert_contains "$configured" 'review=false'
assert_contains "$configured" 'max_lanes=2'
assert_contains "$configured" 'prd_floor=4'
assert_contains "$(LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" route 'build X' 3)" 'direct-edit-refusal'
assert_contains "$(LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" route 'build X' 4)" 'prd-creator-confirm'

printf '%s\n' 'execution=auto' 'delivery=branch' 'review=false' 'max_lanes=2' 'prd_floor=1' > "$config_dir/.linchpin.toml"
assert_contains "$(LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" route 'build X' 2)" 'direct-edit-refusal'
assert_contains "$(LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" route 'build X' 3)" 'prd-creator-confirm'

lanes=
for n in 1 2 3 4 5; do
  lane_prd="$tmp_dir/lane-$n.md"
  sed "s#src/alpha.md#src/lane-$n-alpha.md#g; s#src/shared.md#src/lane-$n-shared.md#g; s#scripts/linchpin.sh#src/lane-$n-runner.md#g" "$fixture_dir/conforming-prd.md" > "$lane_prd"
  lanes="$lanes $lane_prd"
done
bounded=$(LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" mode auto $lanes)
[ "$(printf '%s\n' "$bounded" | grep -Ec 'active=[^ -]')" -eq 2 ] || fail 'max_lanes=2 did not cap active mode groups'
[ "$(printf '%s\n' "$bounded" | grep -Ec 'queued=[^ -]')" -eq 3 ] || fail 'max_lanes=2 did not queue excess mode groups'
scheduled=$(LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" schedule auto ok lane-a lane-b lane-c lane-d lane-e)
assert_contains "$scheduled" 'active=lane-a,lane-b'
assert_contains "$scheduled" 'queued=lane-c,lane-d,lane-e'
pass 'missing configuration uses defaults; prd_floor and max_lanes are enforced'
