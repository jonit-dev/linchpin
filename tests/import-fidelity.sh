#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

baseline="${SOURCE_BASELINE:-3323e59}"
for path in skills/prd-creator/SKILL.md skills/prd-executor/SKILL.md skills/prd-swarm-coordinator/SKILL.md; do
  case "$path" in
    skills/prd-creator/*|skills/prd-executor/*) source_path="$HOME/.claude/$path" ;;
    skills/prd-swarm-coordinator/*) source_path="$HOME/.hermes/skills/autonomous-ai-agents/prd-swarm-coordinator/SKILL.md" ;;
  esac
  [ -f "$source_path" ] || fail "incumbent source is missing: $source_path"
  git -C "$repo_root" show "$baseline:$path" > "$tmp_dir/import.md" || fail "baseline import is missing: $path"
  cmp -s "$tmp_dir/import.md" "$source_path" || fail "baseline import differs from incumbent: $path"
done

git -C "$repo_root" show "$baseline:skills/prd-creator/SKILL.md" > "$tmp_dir/altered.md"
printf 'x' >> "$tmp_dir/altered.md"
if cmp -s "$tmp_dir/altered.md" "$HOME/.claude/skills/prd-creator/SKILL.md"; then
  fail 'altered import comparison did not go red'
fi
printf '%s\n' 'OBSERVED-RED altered import comparison failed as expected'
pass 'incumbent imports match the scaffold commit; later edits remain auditable'
