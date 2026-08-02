#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$repo_root/scripts/verify.sh" >/dev/null
copy="$tmp_dir/native-luna"
copy_repo "$copy"
printf '%s\n' 'agent_type: prd_luna_implementer' >> "$copy/skills/linchpin/SKILL.md"
output="$tmp_dir/native-output"
if env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$copy/scripts/verify.sh" >"$output" 2>&1; then
  cat "$output" >&2
  fail 'native Luna reference was accepted'
fi
grep -F 'skills/linchpin/SKILL.md:' "$output" >/dev/null || fail 'native failure did not name file:line'
printf '%s\n' 'OBSERVED-RED native Luna reference failed with file:line'
pass 'Luna native-spawn safety gate is active'
