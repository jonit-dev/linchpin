#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

for skill in prd-creator prd-swarm-coordinator; do
  grep -Fq 'do not read the full' "$repo_root/skills/$skill/SKILL.md" \
    || fail "$skill lacks the helper context boundary"
done

pass 'helper subcommands are used without loading the full helper source'
