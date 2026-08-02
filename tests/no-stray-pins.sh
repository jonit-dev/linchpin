#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$repo_root/scripts/verify.sh" >/dev/null
copy="$tmp_dir/stray-pin"
copy_repo "$copy"
worker_model=$(awk -F '|' '$2 ~ /Worker/ { value = $3; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' "$copy/references/runtime.md")
printf '%s\n' "worker command: --model $worker_model" >> "$copy/skills/linchpin/SKILL.md"
expect_failure 'model slug copied into a skill body' env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$copy/scripts/verify.sh"
pass 'runtime model pins have one source'
