#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Changing which model or effort a role uses should not require editing the
# installed plugin: runtime.md ships inside it and an upgrade overwrites it.
fixture="$fixture_dir/conforming-prd.md"
config_dir="$tmp_dir/runtime-repo"
mkdir -p "$config_dir"

pinned_field() {
  awk -F '|' -v role="$1" -v column="$2" '$2 ~ role { value = $column; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' "$repo_root/references/runtime.md"
}
pinned_worker_model=$(pinned_field Worker 3)
pinned_worker_effort=$(pinned_field Worker 4)
pinned_reviewer_model=$(pinned_field Reviewer 3)
pinned_reviewer_effort=$(pinned_field Reviewer 4)

# Zero-config keeps every shipped pin exactly as it is.
default_values=$(sh "$repo_root/scripts/linchpin.sh" config "$config_dir")
for empty_key in 'worker=' 'reviewer=' 'worker_effort=' 'reviewer_effort='; do
  assert_contains "$default_values" "$empty_key
"
done
default_brief=$(sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr --config-dir "$config_dir")
# Both roles, or a silent change to the unasserted one ships unnoticed.
assert_contains "$default_brief" "Worker runtime: model=$pinned_worker_model; effort=$pinned_worker_effort;"
assert_contains "$default_brief" "Reviewer runtime: model=$pinned_reviewer_model; effort=$pinned_reviewer_effort;"

# A repo selects models by alias, and the alias reaches both the runtime
# metadata and the invocation shape the manager copies.
printf '%s\n' 'worker = "terra"' 'worker_effort = "high"' \
  'reviewer = "luna"' 'reviewer_effort = "max"' > "$config_dir/.linchpin.toml"
brief_file="$tmp_dir/override-brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr \
  --config-dir "$config_dir" --out "$brief_file" >/dev/null
override_brief=$(cat "$brief_file")
assert_contains "$override_brief" 'Worker runtime: model=gpt-5.6-terra; effort=high;'
assert_contains "$override_brief" 'Reviewer runtime: model=gpt-5.6-luna; effort=max;'
assert_contains "$override_brief" "--model gpt-5.6-terra -c 'model_reasoning_effort=\"high\"'"
assert_contains "$override_brief" "--model gpt-5.6-luna -c 'model_reasoning_effort=\"max\"' --sandbox read-only"

# The checker must resolve the same override, or a brief fails its own check.
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$brief_file" --config-dir "$config_dir" >/dev/null

# Preflight must verify the models the run will actually use, not the shipped
# defaults; a cache without the configured worker has to refuse.
printf '%s\n' 'worker = "terra"' > "$config_dir/.linchpin.toml"
expect_failure 'configured worker missing from the model cache' \
  env LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-with-luna.json"
# The reviewer is checked too, not only the worker.
printf '%s\n' 'reviewer = "terra"' > "$config_dir/.linchpin.toml"
expect_failure 'configured reviewer missing from the model cache' \
  env LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-with-luna.json"

# Only aliases from the runtime.md table are accepted. A raw slug is a pin that
# goes stale when the class moves, so it is rejected as firmly as a typo.
# runtime.md holds several tables with the same column shape. A role name is not
# an alias, and an unscoped lookup would resolve it to a real model, letting a
# value the allowlist should reject select the run's worker.
for bad_alias in 'gpt-5.6-luna' 'gpt-9' 'LUNA' 'Manager' 'Author' 'Worker' 'Reviewer'; do
  printf '%s\n' "worker = \"$bad_alias\"" > "$config_dir/.linchpin.toml"
  expect_failure "worker alias outside the runtime table: $bad_alias" \
    sh "$repo_root/scripts/linchpin.sh" config "$config_dir"
done

printf '%s\n' 'reviewer_effort = "turbo"' > "$config_dir/.linchpin.toml"
expect_failure 'unrecognized effort value' \
  sh "$repo_root/scripts/linchpin.sh" config "$config_dir"

# Preflight refuses before any branch exists, so a config error must surface
# there. Swallowing it produces a PASS that names a model the config never asked
# for, which is worse than no preflight at all.
real_cache="${LINCHPIN_MODELS_CACHE:-${CODEX_HOME:-$HOME/.codex}/models_cache.json}"
for broken_config in 'bogus = 1' 'worker = "gpt-5.6-terra"' 'worker_effort = "turbo"'; do
  printf '%s\n' "$broken_config" > "$config_dir/.linchpin.toml"
  expect_failure "preflight on a rejected config: $broken_config" \
    env LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" preflight "$real_cache"
done

# An absent config is the zero-config default, not an error.
rm -f "$config_dir/.linchpin.toml"
env LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" preflight "$real_cache" >/dev/null

pass 'models and effort are repo-configurable by alias, and preflight verifies what the run will use'
