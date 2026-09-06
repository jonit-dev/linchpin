#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

require_file() {
  if [ ! -f "$1" ]; then
    fail "missing required file: ${1#"$repo_root/"}"
  fi
}

require_file "$repo_root/references/prd-contract.md"
require_file "$repo_root/references/intake.md"
require_file "$repo_root/references/runtime.md"
require_file "$repo_root/skills/prd-creator/SKILL.md"
require_file "$repo_root/skills/prd-swarm-coordinator/SKILL.md"
require_file "$repo_root/skills/linchpin/SKILL.md"
require_file "$repo_root/scripts/linchpin.sh"
require_file "$repo_root/.codex-plugin/plugin.json"
require_file "$repo_root/.agents/plugins/marketplace.json"
require_file "$repo_root/.github/workflows/verify.yml"

if [ -e "$repo_root/skills/prd-executor" ]; then
  fail "retired executor skill still exists: skills/prd-executor"
fi

if command -v jq >/dev/null 2>&1 && [ -f "$repo_root/.agents/plugins/marketplace.json" ]; then
  if ! jq -e '
    (keys | sort) == ["interface", "name", "plugins"] and
    .name == "linchpin" and
    (.plugins | length) == 1 and
    .plugins[0].name == "linchpin" and
    .plugins[0].source.source == "url" and
    .plugins[0].source.url == "https://github.com/jonit-dev/linchpin.git" and
    .plugins[0].source.ref == "main" and
    .plugins[0].policy.installation == "AVAILABLE" and
    .plugins[0].policy.authentication == "ON_INSTALL" and
    .plugins[0].category == "Productivity"
  ' "$repo_root/.agents/plugins/marketplace.json" >/dev/null 2>&1; then
    fail 'GitHub marketplace manifest is invalid or does not point at linchpin'
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  fail 'jq is required; verifier has no JSON fallback'
elif ! jq empty "$repo_root/.codex-plugin/plugin.json" >/dev/null 2>&1; then
  fail 'plugin manifest is not valid JSON'
else
  if ! jq -e '
    (keys | sort) == ["author", "description", "interface", "keywords", "license", "name", "repository", "skills", "version"] and
    .name == "linchpin" and
    .skills == "./skills/" and
    .repository == "https://github.com/jonit-dev/linchpin" and
    .license == "MIT" and
    (.author.name | type == "string" and length > 0) and
    (.interface.displayName | type == "string" and length > 0) and
    (.interface.capabilities | type == "array" and length > 0) and
    (.interface.defaultPrompt | type == "array" and length > 0 and any(.[]; contains("one or more") or contains("one or many")))
  ' "$repo_root/.codex-plugin/plugin.json" >/dev/null 2>&1; then
    fail 'plugin manifest has an unverified schema or discovery prompt'
  fi
fi

skill_files=$(find "$repo_root/skills" -type f -name '*.md' -print)

# `agent_type` and `fork_turns` were the whole list, and they did not name the
# call one field manager actually made: `multi_agent_v1__spawn_agent` with
# `fork_context: true`, which launched three auditors that inherited the
# parent's `danger-full-access` context while their prompts said read-only.
# A rule enforced against two spellings of a mechanism is not enforced.
native_hits=$(printf '%s\n' "$skill_files" | while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  grep -nE 'agent_type|fork_turns|fork_context|spawn_agent|multi_agent_v[0-9]' "$skill" | sed "s#^#$skill:#"
done || true)
if [ -n "$native_hits" ]; then
  printf '%s\n' "$native_hits" >&2
  fail 'native subagent terms are present in a skill; every role runs as a subprocess with its own sandbox'
fi

# A Claude id pasted into a skill body is the same stale pin a codex slug is.
# Both providers, one rule: the alias tables in references/runtime.md are the
# only place a slug appears.
pin_hits=$(printf '%s\n' "$skill_files" | while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  grep -nE 'gpt-5[.]6-[[:alnum:].-]+|claude-(opus|sonnet|haiku|fable)-[0-9][[:alnum:].-]*' "$skill" | sed "s#^#$skill:#"
done || true)
if [ -n "$pin_hits" ]; then
  printf '%s\n' "$pin_hits" >&2
  fail 'model slug is hardcoded in a skill; references/runtime.md is the only pin source'
fi

delegation_hits=$(printf '%s\n' "$skill_files" | while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  grep -nE 'prd-executor|Task[[:space:]]*[(]|subagent_type[[:space:]]*:' "$skill" | sed "s#^#$skill:#"
done || true)
if [ -n "$delegation_hits" ]; then
  printf '%s\n' "$delegation_hits" >&2
  fail 'retired or Claude-native delegation remains in skills'
fi

for shipped_doc in "$repo_root"/references/*.md $repo_root/README.md $repo_root/docs/migration-swap.md; do
  [ -f "$shipped_doc" ] || continue
  legacy_doc_hits=$(grep -nE 'prd-executor|Task[[:space:]]*[(]|subagent_type[[:space:]]*:' "$shipped_doc" || true)
  if [ -n "$legacy_doc_hits" ]; then
    printf '%s\n' "$legacy_doc_hits" >&2
    fail "retired delegation remains in shipped documentation: ${shipped_doc#"$repo_root/"}"
  fi
done

for required in \
  'skills/prd-creator/SKILL.md:references/prd-contract.md' \
  'skills/prd-creator/SKILL.md:references/intake.md' \
  'skills/prd-creator/SKILL.md:references/runtime.md' \
  'skills/prd-swarm-coordinator/SKILL.md:references/prd-contract.md' \
  'skills/prd-swarm-coordinator/SKILL.md:references/intake.md' \
  'skills/prd-swarm-coordinator/SKILL.md:references/runtime.md' \
  'skills/linchpin/SKILL.md:references/intake.md' \
  'skills/linchpin/SKILL.md:references/runtime.md' \
  '.github/workflows/verify.yml:scripts/verify.sh'; do
  skill_path=${required%%:*}
  citation=${required#*:}
  if ! grep -Fq "$citation" "$repo_root/$skill_path"; then
    fail "$skill_path does not cite $citation"
  fi
done

reference_hits=$(find "$repo_root" -type f -name '*.md' -not -path "$repo_root/.git/*" -exec grep -hoE 'references/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*[.]md' {} + 2>/dev/null | sort -u || true)
for reference in $reference_hits; do
  if [ ! -f "$repo_root/$reference" ]; then
    fail "dangling reference: $reference"
  fi
done

if ! grep -Eq '^## Contracted PRD output' "$repo_root/skills/prd-creator/SKILL.md"; then
  fail 'creator contract output section is missing'
fi
if ! grep -Eq '^## Inherited lane gates' "$repo_root/skills/prd-swarm-coordinator/SKILL.md"; then
  fail 'coordinator inherited-gates section is missing'
fi
if ! grep -Eq '^## Per-group mode selection' "$repo_root/skills/prd-swarm-coordinator/SKILL.md"; then
  fail 'coordinator mode-selection section is missing'
fi
if ! grep -Eq '^## Intent routing table' "$repo_root/references/intake.md"; then
  fail 'intake routing table is missing'
fi
if ! grep -Eq '^## Provider mechanisms' "$repo_root/references/runtime.md"; then
  fail 'runtime provider mechanisms section is missing'
fi
for required_mechanism in \
  'codex exec --sandbox danger-full-access' \
  'codex exec --sandbox read-only' \
  'claude -p --permission-mode bypassPermissions' \
  'claude -p --permission-mode plan --disallowed-tools "Edit Write NotebookEdit"'; do
  if ! grep -Fq "$required_mechanism" "$repo_root/references/runtime.md"; then
    fail "runtime provider mechanisms section does not declare: $required_mechanism"
  fi
done
if ! grep -Fq 'ROUTE-ASSIGN-MODELS' "$repo_root/references/intake.md"; then
  fail 'intake routing table has no model-assignment route'
fi
if ! grep -Fq '.linchpin-models.toml' "$repo_root/references/intake.md"; then
  fail 'intake does not document the repo-local alias table'
fi

model_cache="${LINCHPIN_MODELS_CACHE:-}"
if ! sh "$repo_root/scripts/linchpin.sh" preflight "$model_cache"; then
  fail 'runtime model preflight failed; no fallback is allowed'
fi

if [ "$failures" -ne 0 ]; then
  printf 'VERIFY-FAIL failures=%s\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'VERIFY-PASS contract references, runtime safety, manifest, delegation, and model preflight'
