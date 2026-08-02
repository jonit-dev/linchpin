#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

baseline="${SOURCE_BASELINE:-3323e59}"
creator_source=""
creator_baseline_import=""
for path in skills/prd-creator/SKILL.md skills/prd-executor/SKILL.md skills/prd-swarm-coordinator/SKILL.md; do
  case "$path" in
    skills/prd-creator/*) source_path="$HOME/.claude/$path"; source_key=prd-creator ;;
    skills/prd-executor/*) source_path="$HOME/.claude/$path"; source_key=prd-executor ;;
    skills/prd-swarm-coordinator/*) source_path="$HOME/.hermes/skills/autonomous-ai-agents/prd-swarm-coordinator/SKILL.md"; source_key=prd-swarm-coordinator ;;
  esac

  baseline_import="$tmp_dir/$source_key-baseline.md"
  git -C "$repo_root" show "$baseline:$path" > "$baseline_import" || fail "baseline import is missing: $path"

  if [ -f "$source_path" ]; then
    selected_source="$source_path"
    printf 'SOURCE-PROVENANCE live incumbent: %s\n' "$source_path"
  else
    selected_source="$tmp_dir/$source_key-source-snapshot.md"
    git -C "$repo_root" show "$baseline:$path" > "$selected_source" || fail "incumbent source is missing: $source_path; committed snapshot is missing: $baseline:$path"
    cmp -s "$selected_source" "$baseline_import" || fail "committed snapshot differs from baseline import: $path"
    printf 'SOURCE-PROVENANCE committed snapshot fallback: %s:%s\n' "$baseline" "$path"
  fi

  cmp -s "$baseline_import" "$selected_source" || fail "baseline import differs from selected source: $path"
  if [ "$path" = "skills/prd-creator/SKILL.md" ]; then
    creator_source="$selected_source"
    creator_baseline_import="$baseline_import"
  fi
done

[ -n "$creator_source" ] || fail 'prd-creator source was not selected'
[ -n "$creator_baseline_import" ] || fail 'prd-creator baseline import was not selected'
cp "$creator_baseline_import" "$tmp_dir/altered.md"
printf 'x' >> "$tmp_dir/altered.md"
if cmp -s "$tmp_dir/altered.md" "$creator_source"; then
  fail 'altered import comparison did not go red'
fi
printf '%s\n' 'OBSERVED-RED altered import comparison failed as expected'
pass 'incumbent imports match the scaffold commit; later edits remain auditable'
