#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

for skill in prd-creator prd-swarm-coordinator; do
  grep -Eq '^name: ' "$repo_root/skills/$skill/SKILL.md" || fail "$skill is not directly invocable"
done
copy="$tmp_dir/no-router"
copy_repo "$copy"
rmdir "$copy/skills/linchpin" 2>/dev/null || true
[ -f "$copy/skills/prd-creator/SKILL.md" ] || fail 'creator became dependent on router'
[ -f "$copy/skills/prd-swarm-coordinator/SKILL.md" ] || fail 'coordinator became dependent on router'
pass 'direct creator and coordinator invocation does not depend on the router'
