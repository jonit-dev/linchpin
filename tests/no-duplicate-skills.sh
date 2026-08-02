#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

scan="$tmp_dir/skill-sources"
mkdir -p "$scan/plugin/prd-creator" "$scan/codex/prd-creator" "$scan/claude/prd-swarm-coordinator"
touch "$scan/plugin/prd-creator/SKILL.md" "$scan/claude/prd-swarm-coordinator/SKILL.md"
count=$(find "$scan" -path '*/prd-creator/SKILL.md' -type f | wc -l | tr -d ' ')
[ "$count" -eq 1 ] || fail 'clean source set was counted as duplicate'
touch "$scan/codex/prd-creator/SKILL.md"
count=$(find "$scan" -path '*/prd-creator/SKILL.md' -type f | wc -l | tr -d ' ')
if [ "$count" -eq 1 ]; then
  fail 'restored duplicate was not detected'
fi
printf '%s\n' 'OBSERVED-RED restored incumbent duplicate was detected'
printf '%s\n' 'MANUAL-SWAP-GATE external source census remains owner-confirmed and read-only.'
pass 'duplicate detector catches a restored incumbent without changing external paths'
