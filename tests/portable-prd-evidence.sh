#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

grep -Fq 'Keep generated PRD evidence portable' "$repo_root/skills/prd-creator/SKILL.md" \
  || fail 'creator does not require portable PRD evidence'
grep -Fq 'absolute installed path may be used for the live check' "$repo_root/skills/prd-creator/SKILL.md" \
  || fail 'creator permits installed cache paths in PRDs'

pass 'creator PRD evidence is portable across installations'
