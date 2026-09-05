#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# `references/intake.md` promised that natural-language overrides are written to
# `.linchpin.toml` before scheduling, and nothing parsed one: the manager was
# left improvising the mapping from a sentence to two config keys. This is that
# mapping, and it is a command rather than a habit.
cache="$fixture_dir/models-cache-multi-provider.json"
fake_claude="$fixture_dir/fake-claude.sh"
config_dir="$tmp_dir/assign-repo"
mkdir -p "$config_dir"

assign() {
  env LINCHPIN_MODELS_CACHE="$cache" LINCHPIN_CLAUDE_BIN="$fake_claude" \
    sh "$repo_root/scripts/linchpin.sh" assign "$@"
}

# The sentence from the goal statement, end to end.
sentence='use Linchpin with Astra medium as reviewer and Opus 5 medium as executor'
resolved=$(assign "$sentence" --config-dir "$config_dir")
assert_contains "$resolved" 'ASSIGN role=reviewer alias=astra effort=medium provider=codex model=gpt-6-astra'
assert_contains "$resolved" 'ASSIGN role=worker alias=opus-5 effort=medium provider=claude model=claude-opus-5'

# Without --write it only prints. A caller that runs assign to find out must not
# have changed the repository by asking.
[ ! -f "$config_dir/.linchpin.toml" ] || fail 'assign wrote a config file without --write'

# --write is the round trip: the keys the sentence named, resolvable by every
# other command that reads the file.
assign "$sentence" --config-dir "$config_dir" --write >/dev/null
written=$(cat "$config_dir/.linchpin.toml")
for expected_key in 'worker = "opus-5"' 'worker_effort = "medium"' \
                    'reviewer = "astra"' 'reviewer_effort = "medium"'; do
  assert_contains "$written" "$expected_key"
done
config_back=$(sh "$repo_root/scripts/linchpin.sh" config "$config_dir")
assert_contains "$config_back" 'worker=opus-5'
assert_contains "$config_back" 'reviewer=astra'

# Every other key survives, and a key the sentence names is replaced rather than
# duplicated.
rm -f "$config_dir/.linchpin.toml"
printf '%s\n' '# keep me' 'max_lanes = 2' 'worker = "luna"' 'delivery = "branch"' \
  > "$config_dir/.linchpin.toml"
assign 'run the reviewer as Sonnet 5 high and the executor as terra high' \
  --config-dir "$config_dir" --write >/dev/null
preserved=$(cat "$config_dir/.linchpin.toml")
assert_contains "$preserved" '# keep me'
assert_contains "$preserved" 'max_lanes = 2'
assert_contains "$preserved" 'delivery = "branch"'
assert_contains "$preserved" 'worker = "terra"'
assert_contains "$preserved" 'reviewer = "sonnet-5"'
[ "$(grep -c '^worker = ' "$config_dir/.linchpin.toml")" -eq 1 ] ||
  fail 'assign --write duplicated a key instead of replacing it'

# A sentence that re-efforts a role without naming a model is an assignment too,
# and it keeps the alias the repository already chose. An empty alias field is
# where a naive record separator silently shifts every later field.
rm -f "$config_dir/.linchpin.toml"
printf '%s\n' 'worker = "luna"' > "$config_dir/.linchpin.toml"
effort_only=$(assign 'run the executor at high effort' --config-dir "$config_dir" --write)
assert_contains "$effort_only" 'ASSIGN role=worker alias=luna effort=high provider=codex model=gpt-5.6-luna'
assert_contains "$(cat "$config_dir/.linchpin.toml")" 'worker_effort = "high"'
assert_contains "$(cat "$config_dir/.linchpin.toml")" 'worker = "luna"'

# Role synonyms. Each of these names the same two roles.
rm -f "$config_dir/.linchpin.toml"
for worker_word in executor worker implementer builder; do
  synonym=$(assign "put haiku 4.5 low on the $worker_word" --config-dir "$config_dir")
  assert_contains "$synonym" 'ASSIGN role=worker alias=haiku-4.5 effort=low provider=claude model=claude-haiku-4-5'
done
for reviewer_word in reviewer review critic; do
  synonym=$(assign "the $reviewer_word should be sol high" --config-dir "$config_dir")
  assert_contains "$synonym" 'ASSIGN role=reviewer alias=sol effort=high provider=codex model=gpt-5.6-sol'
done

# A dotted name is one term with the alias that carries the dot, and case is not
# a different model.
dotted=$(assign 'use FABLE 5.1 as the executor at xhigh' --config-dir "$config_dir")
assert_contains "$dotted" 'alias=fable-5.1'
assert_contains "$dotted" 'effort=xhigh'
assert_contains "$dotted" 'model=claude-fable-5-1'

# Text naming no assignment is not an error: a caller runs assign on every
# request so the conversational and file paths converge.
none=$(assign 'execute docs/PRDs/PRD-007.md and open a PR' --config-dir "$config_dir")
assert_contains "$none" 'ASSIGN-NONE'

# A model in no alias table is a normal request. It is verified live and then
# minted as a repo-local alias, so it is still referred to by alias downstream.
rm -f "$config_dir/.linchpin.toml" "$config_dir/.linchpin-models.toml"
minted=$(env LINCHPIN_MODELS_CACHE="$cache" LINCHPIN_CLAUDE_BIN="$fake_claude" \
  LINCHPIN_FAKE_CLAUDE_MODELS='claude-opus-5 claude-glass-9' \
  sh "$repo_root/scripts/linchpin.sh" assign 'set the reviewer to claude-glass-9 medium' \
    --config-dir "$config_dir")
assert_contains "$minted" 'ASSIGN-ALIAS-MINTED claude-glass-9 = "claude:claude-glass-9"'
assert_contains "$minted" 'ASSIGN role=reviewer alias=claude-glass-9 effort=medium provider=claude model=claude-glass-9'
assert_contains "$(cat "$config_dir/.linchpin-models.toml")" 'claude-glass-9 = "claude:claude-glass-9"'
# ...and the minted row is a real alias: config validation accepts it.
printf '%s\n' 'reviewer = "claude-glass-9"' > "$config_dir/.linchpin.toml"
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" config "$config_dir")" 'reviewer=claude-glass-9'

# A shipped row always wins over a repo-local row of the same name, so a repo
# cannot redefine a verified alias out from under a run.
printf '%s\n' 'luna = "claude:claude-opus-5"' >> "$config_dir/.linchpin-models.toml"
printf '%s\n' 'worker = "luna"' > "$config_dir/.linchpin.toml"
shadow_brief="$tmp_dir/shadow.brief"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture_dir/conforming-prd.md" lane-1 parallel pr \
  --config-dir "$config_dir" --out "$shadow_brief" >/dev/null
assert_contains "$(cat "$shadow_brief")" 'Worker provider: codex'
assert_contains "$(cat "$shadow_brief")" 'model=gpt-5.6-luna'
printf '%s\n' 'OBSERVED-RED a repo-local row redefining a shipped alias was ignored'
rm -f "$config_dir/.linchpin.toml" "$config_dir/.linchpin-models.toml"

# NEGATIVE CONTROL: a model term that verifies on neither provider is refused by
# name, and never guessed at or replaced with a fallback.
expect_failure 'model term that verifies on neither provider' \
  env LINCHPIN_MODELS_CACHE="$cache" LINCHPIN_CLAUDE_BIN="$fake_claude" \
      sh "$repo_root/scripts/linchpin.sh" assign 'use nimbus-9 medium as the reviewer' \
        --config-dir "$config_dir"
unresolved=$(env LINCHPIN_MODELS_CACHE="$cache" LINCHPIN_CLAUDE_BIN="$fake_claude" \
  sh "$repo_root/scripts/linchpin.sh" assign 'use nimbus-9 medium as the reviewer' \
    --config-dir "$config_dir" 2>&1 || true)
assert_contains "$unresolved" 'ASSIGN-UNRESOLVED nimbus-9'
case "$unresolved" in
  *'ASSIGN role='*) fail 'an unresolvable model term still produced an assignment' ;;
esac
[ ! -f "$config_dir/.linchpin.toml" ] || fail 'a refused assignment still wrote a config'

# An effort outside the resolved provider's domain is refused here rather than
# written into a config that every later command rejects.
expect_failure 'xhigh asked of a codex role' \
  env LINCHPIN_MODELS_CACHE="$cache" LINCHPIN_CLAUDE_BIN="$fake_claude" \
      sh "$repo_root/scripts/linchpin.sh" assign 'run terra xhigh as the executor' \
        --config-dir "$config_dir" --write

pass 'a sentence resolves to roles, aliases, efforts, providers, and models, or is refused by name'
