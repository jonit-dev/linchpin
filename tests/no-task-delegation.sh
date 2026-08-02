#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$repo_root/scripts/verify.sh" >/dev/null
copy="$tmp_dir/native-task"
copy_repo "$copy"
printf '%s\n' 'Task({ native reviewer })' >> "$copy/skills/prd-creator/SKILL.md"
expect_failure 'Claude-native Task delegation in a skill' env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$copy/scripts/verify.sh"
pass 'retired executor and native Task delegation are absent from shipped skills'
