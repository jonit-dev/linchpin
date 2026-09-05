#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$repo_root/scripts/verify.sh" >/dev/null
copy="$tmp_dir/stray-pin"
copy_repo "$copy"
worker_model=$(awk -F '|' '$2 ~ /Worker/ { value = $4; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' "$copy/references/runtime.md")
[ -n "$worker_model" ] || fail 'could not read the Worker model out of the role pins table'
printf '%s\n' "worker command: --model $worker_model" >> "$copy/skills/linchpin/SKILL.md"
expect_failure 'codex model slug copied into a skill body' env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$copy/scripts/verify.sh"

# A Claude id is the same stale pin, and the verifier that only knew one vendor
# would have let the whole second provider through unguarded.
claude_copy="$tmp_dir/stray-pin-claude"
copy_repo "$claude_copy"
claude_model=$(awk -F '|' '$2 ~ /`opus-5`/ { value = $4; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' "$claude_copy/references/runtime.md")
[ "$claude_model" = 'claude-opus-5' ] || fail "could not read the opus-5 slug out of the alias table: '$claude_model'"
printf '%s\n' "worker command: --model $claude_model" >> "$claude_copy/skills/prd-swarm-coordinator/SKILL.md"
expect_failure 'claude model slug copied into a skill body' env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$claude_copy/scripts/verify.sh"
pin_report=$(env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$claude_copy/scripts/verify.sh" 2>&1 || true)
assert_contains "$pin_report" 'skills/prd-swarm-coordinator/SKILL.md:'

pass 'runtime model pins have one source, for both providers'
