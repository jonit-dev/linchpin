#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'Usage: sh scripts/migration-swap.sh --dry-run'
}

if [ "${1:-}" != "--dry-run" ] || [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
user_root=${HOME:?HOME is required to inspect incumbent paths}
printf '%s\n' 'DRY-RUN only: no external path will be changed.'
printf 'plugin root: %s\n' "$repo_root"
printf 'backup destination required from owner: %s\n' "$repo_root/.migration-backup/"

for target in \
  "$user_root/.codex/skills/prd-creator" \
  "$user_root/.codex/skills/prd-executor" \
  "$user_root/.codex/skills/prd-swarm-coordinator" \
  "$user_root/.claude/skills/prd-creator" \
  "$user_root/.claude/skills/prd-executor" \
  "$user_root/.hermes/skills/autonomous-ai-agents/prd-swarm-coordinator"; do
  if [ -L "$target" ]; then
    printf 'FOUND symlink: %s -> %s\n' "$target" "$(readlink "$target")"
  elif [ -e "$target" ]; then
    printf 'FOUND path: %s\n' "$target"
  else
    printf 'ABSENT path: %s\n' "$target"
  fi
done

printf '%s\n' 'REQUIRED BEFORE A LIVE SWAP: owner-created backup, byte equality report, plugin registration, and fresh-task smoke evidence.'
