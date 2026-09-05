#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# The registry is a document, and a document is where a provider silently goes
# missing. Every downstream decision — which mechanism a role may use, which
# effort words it accepts, whether preflight reads a cache or spends a probe —
# is read out of these tables, so their shape is itself a contract.
runtime="$repo_root/references/runtime.md"
fixture="$fixture_dir/conforming-prd.md"

table_cell() {
  awk -F '|' -v table="$1" -v target="$2" -v column="$3" '
    /^## / { in_table = (index($0, "## " table) == 1); next }
    !in_table { next }
    {
      name = $2
      gsub(/`/, "", name); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == target) {
        value = $column
        gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$4"
}

# Every shipped role pin carries a provider, and the shipped set is all codex,
# so a zero-config run is the single-provider run it always was.
for shipped_role in Manager Author Worker Reviewer; do
  role_provider=$(table_cell 'Role pins' "$shipped_role" 3 "$runtime")
  [ "$role_provider" = codex ] ||
    fail "role pin $shipped_role has no codex provider cell: '$role_provider'"
done

shipped_aliases='luna codex gpt-5.6-luna
sol codex gpt-5.6-sol
terra codex gpt-5.6-terra
astra codex gpt-6-astra
opus-5 claude claude-opus-5
opus-4.8 claude claude-opus-4-8
sonnet-5 claude claude-sonnet-5
haiku-4.5 claude claude-haiku-4-5
fable-5.1 claude claude-fable-5-1'

config_dir="$tmp_dir/registry-repo"
mkdir -p "$config_dir"

# Every shipped row: the table's own cells, and the resolution the run actually
# performs. A table nobody reads back is a table that drifts.
printf '%s\n' "$shipped_aliases" | while read -r want_alias want_provider want_slug; do
  [ -n "$want_alias" ] || continue
  got_provider=$(table_cell 'Model aliases' "$want_alias" 3 "$runtime")
  got_slug=$(table_cell 'Model aliases' "$want_alias" 4 "$runtime")
  got_domain=$(table_cell 'Model aliases' "$want_alias" 5 "$runtime")
  [ "$got_provider" = "$want_provider" ] ||
    fail "alias $want_alias has provider cell '$got_provider', expected $want_provider"
  [ "$got_slug" = "$want_slug" ] ||
    fail "alias $want_alias has slug cell '$got_slug', expected $want_slug"
  case "$want_provider" in
    codex) [ "$got_domain" = 'low medium high max' ] ||
      fail "codex alias $want_alias has effort domain '$got_domain'" ;;
    claude) [ "$got_domain" = 'low medium high xhigh max' ] ||
      fail "claude alias $want_alias has effort domain '$got_domain'" ;;
  esac
  printf '%s\n' "worker = \"$want_alias\"" > "$config_dir/.linchpin.toml"
  row_brief=$(sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr --config-dir "$config_dir")
  assert_contains "$row_brief" "Worker provider: $want_provider"
  assert_contains "$row_brief" "--model $want_slug"
done
rm -f "$config_dir/.linchpin.toml"

# A floating alias is the stale pin the table exists to prevent, so the bare
# names have no rows even though the CLI resolves them.
for floating in opus sonnet haiku claude; do
  [ -z "$(table_cell 'Model aliases' "$floating" 3 "$runtime")" ] ||
    fail "floating alias $floating has a row; a moving target is not a pin"
done

# Four mechanism strings, one per provider per role, present verbatim.
grep -Eq '^## Provider mechanisms' "$runtime" ||
  fail 'runtime.md has no Provider mechanisms section'
for mechanism in \
  'codex exec --sandbox danger-full-access' \
  'codex exec --sandbox read-only' \
  'claude -p --permission-mode bypassPermissions' \
  'claude -p --permission-mode plan --disallowed-tools "Edit Write NotebookEdit"'; do
  grep -Fq "$mechanism" "$runtime" ||
    fail "provider mechanisms section is missing: $mechanism"
done

# NEGATIVE CONTROL: a provider cell is not optional and has no default. Deleting
# one makes the row unresolvable rather than quietly falling back to codex.
copy="$tmp_dir/registry-no-provider"
copy_repo "$copy"
sed 's/^| `opus-5` | `claude` |/| `opus-5` |  |/' "$repo_root/references/runtime.md" > "$copy/references/runtime.md"
grep -Fq '| `opus-5` |  |' "$copy/references/runtime.md" ||
  fail 'negative control did not remove the provider cell it meant to remove'
printf '%s\n' 'worker = "opus-5"' > "$config_dir/.linchpin.toml"
expect_failure 'opus-5 row with its provider cell deleted' \
  sh "$copy/scripts/linchpin.sh" config "$config_dir"
rm -f "$config_dir/.linchpin.toml"

pass 'the provider registry names a provider, slug, effort domain, and mechanism for every shipped role'
