#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$repo_root/scripts/verify.sh" >/dev/null
copy="$tmp_dir/stray-pin"
copy_repo "$copy"
printf '%s\n' 'worker command: --model gpt-5.6-luna' >> "$copy/skills/linchpin/SKILL.md"
expect_failure 'model slug copied into a skill body' env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$copy/scripts/verify.sh"
pass 'runtime model pins have one source'
