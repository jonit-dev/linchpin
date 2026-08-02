#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

defaults=$(sh "$repo_root/scripts/linchpin.sh" config "$tmp_dir")
assert_contains "$defaults" 'execution=auto'
assert_contains "$defaults" 'delivery=pr'
assert_contains "$defaults" 'review=true'
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" route 'build X' 2)" 'direct-edit-refusal'
printf '%s\n' 'execution=sequential' 'delivery=branch' 'review=false' 'max_lanes=2' 'prd_floor=4' > "$tmp_dir/.linchpin.toml"
configured=$(sh "$repo_root/scripts/linchpin.sh" config "$tmp_dir")
assert_contains "$configured" 'execution=sequential'
assert_contains "$configured" 'delivery=branch'
assert_contains "$configured" 'review=false'
assert_contains "$configured" 'max_lanes=2'
assert_contains "$configured" 'prd_floor=4'
pass 'missing configuration uses defaults and score-2 input refuses the pipeline'
