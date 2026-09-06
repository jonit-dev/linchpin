#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Finding 2 of docs/codex-session-audit-2026-09-06.md. The router told the
# manager to carry a run-local auditor model and effort into bootstrap state,
# and nothing implemented the other end: `audit` had no model input, its JSON
# carried only policy and PRD metadata, and `preflight --bootstrap` read only
# `.audit.eligible` before falling back to the repository default. A manager
# could preflight Astra and then launch Sol by hand, or silently fall back.
#
# The fix under test: one validated `roles` object, written by `audit --out`
# and consumed by `preflight --bootstrap`, with the repository config untouched.

command -v jq >/dev/null 2>&1 || { printf 'SKIP run-local auditor carriage needs jq\n'; exit 0; }

linchpin="$repo_root/scripts/linchpin.sh"
cache="$fixture_dir/models-cache-multi-provider.json"
work="$tmp_dir/run-local"
mkdir -p "$work"
prd="$work/prd.md"
cat > "$prd" <<'PRD'
# Fixture PRD

**Complexity: 8 → HIGH mode**
PRD

default_auditor=$(awk -F '|' '$2 ~ /Auditor/ { value = $4; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' \
  "$repo_root/references/runtime.md")
[ -n "$default_auditor" ] || fail 'could not read the Auditor model out of the role pins table'

# ---------------------------------------------------------------------------
# `assign` resolves the sentence. It has to hand back the flags that carry the
# resolution forward, or "carry it in the bootstrap state" stays prose.
assigned=$(sh "$linchpin" assign 'use Sol high as auditor for this run' --config-dir "$work")
assert_contains "$assigned" 'ASSIGN role=auditor'
assert_contains "$assigned" 'scope=run-local'
assert_contains "$assigned" 'ASSIGN-RUN-LOCAL audit --auditor sol --auditor-effort high'
printf '%s\n' 'OBSERVED-RED assign emits the bootstrap flags for a run-local auditor'

# ---------------------------------------------------------------------------
# `audit --out` freezes the resolved roles, not just the policy decision.
out="$work/bootstrap.json"
sh "$linchpin" audit "$prd" --config-dir "$work" --auditor sol --auditor-effort high --out "$out" >/dev/null
[ "$(jq -r '.audit.eligible' "$out")" = yes ] || fail 'the HIGH fixture PRD was not audit-eligible'
[ "$(jq -r '.roles.auditor.effort' "$out")" = high ] ||
  fail 'bootstrap state did not freeze the run-local auditor effort'
[ "$(jq -r '.roles.auditor.scope' "$out")" = run-local ] ||
  fail 'bootstrap state did not mark the auditor assignment run-local'
[ "$(jq -r '.roles.auditor.model' "$out")" != "$default_auditor" ] ||
  fail 'bootstrap state froze the default auditor instead of the requested one'
[ "$(jq -r '.roles.auditor.mechanism' "$out")" != null ] ||
  fail 'bootstrap state froze no auditor mechanism'
for role in worker reviewer; do
  [ "$(jq -r --arg r "$role" '.roles[$r].model' "$out")" != null ] ||
    fail "bootstrap state froze no $role model"
done
printf '%s\n' 'OBSERVED-RED audit --out serializes every resolved role'

# The repository default is untouched: run-local means run-local.
[ ! -f "$work/.linchpin.toml" ] ||
  fail 'a run-local auditor assignment wrote the repository config'

# ---------------------------------------------------------------------------
# Preflight consumes the same object. This is the join the audit reproduced as
# broken: the frozen selection said Sol/high and preflight reported Astra.
preflight=$(env LINCHPIN_CONFIG_DIR="$work" sh "$linchpin" preflight "$cache" --bootstrap "$out")
assert_contains "$preflight" 'PREFLIGHT-PASS'
assert_contains "$preflight" 'effort=high'
case "$preflight" in
  *"auditor[provider=codex model=$default_auditor"*)
    fail 'preflight ignored the frozen run-local auditor and reported the default' ;;
esac
printf '%s\n' 'OBSERVED-RED preflight reports the auditor the bootstrap actually froze'

# A bootstrap whose roles disagree with themselves is refused rather than
# half-consumed: an unknown alias must not resolve to the default in silence.
jq '.roles.auditor.model = "gpt-nonexistent"' "$out" > "$work/bad.json"
if env LINCHPIN_CONFIG_DIR="$work" sh "$linchpin" preflight "$cache" --bootstrap "$work/bad.json" \
     >"$tmp_dir/bad-preflight" 2>&1; then
  cat "$tmp_dir/bad-preflight" >&2
  fail 'preflight accepted a bootstrap naming a model the provider does not have'
fi
printf '%s\n' 'OBSERVED-RED preflight refuses a frozen role it cannot verify'

pass 'a run-local auditor survives assign, bootstrap, and preflight as one object'
