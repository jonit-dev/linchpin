#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

copy="$tmp_dir/pin-repair"
copy_repo "$copy"
third_tier="gpt-5.6-$(printf '%s' 'terra')"
printf '%s\n' "repair example: --model $third_tier" >> "$copy/skills/prd-swarm-coordinator/SKILL.md"
expect_failure 'repair path that changes model tier' env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$copy/scripts/verify.sh"
pass 'repair remains on the runtime worker tier and never escalates'
