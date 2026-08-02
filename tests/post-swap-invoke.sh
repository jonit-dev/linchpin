#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

for skill in linchpin prd-creator prd-swarm-coordinator; do
  [ -f "$repo_root/skills/$skill/SKILL.md" ] || fail "plugin skill missing: $skill"
done
output=$(sh "$repo_root/scripts/migration-swap.sh" --dry-run)
assert_contains "$output" 'DRY-RUN only'
assert_contains "$output" 'REQUIRED BEFORE A LIVE SWAP'
printf '%s\n' 'MANUAL-SWAP-GATE live post-swap Codex invocation awaits owner backup/equality/registration evidence.'
pass 'post-swap invocation contract is documented without claiming live resolution'
