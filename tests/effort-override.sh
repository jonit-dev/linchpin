#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Changing the reviewer's effort should not require editing the installed
# plugin: runtime.md lives inside the plugin and an upgrade overwrites it.
fixture="$fixture_dir/conforming-prd.md"
config_dir="$tmp_dir/effort-repo"
mkdir -p "$config_dir"

# Zero-config keeps the runtime.md pins exactly as shipped.
default_values=$(sh "$repo_root/scripts/linchpin.sh" config "$config_dir")
assert_contains "$default_values" 'worker_effort='
assert_contains "$default_values" 'reviewer_effort='
assert_contains "$default_values" 'worker_effort=
'
assert_contains "$default_values" 'reviewer_effort=
'
pinned_effort() {
  awk -F '|' -v role="$1" '$2 ~ role { value = $4; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }' "$repo_root/references/runtime.md"
}
pinned_reviewer=$(pinned_effort Reviewer)
pinned_worker=$(pinned_effort Worker)
default_brief=$(sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr --config-dir "$config_dir")
# Both roles, or a silent downgrade of the unasserted one ships unnoticed.
assert_contains "$default_brief" "Reviewer runtime: model=gpt-5.6-sol; effort=$pinned_reviewer;"
assert_contains "$default_brief" "Worker runtime: model=gpt-5.6-luna; effort=$pinned_worker;"

# A repo-local override reaches both the runtime metadata and the invocation
# shape the manager copies, without touching the shipped pins.
printf '%s\n' 'reviewer_effort = "max"' 'worker_effort = "high"' > "$config_dir/.linchpin.toml"
brief_file="$tmp_dir/override-brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr \
  --config-dir "$config_dir" --out "$brief_file" >/dev/null
override_brief=$(cat "$brief_file")
assert_contains "$override_brief" 'Reviewer runtime: model=gpt-5.6-sol; effort=max;'
assert_contains "$override_brief" 'Worker runtime: model=gpt-5.6-luna; effort=high;'
assert_contains "$override_brief" "model_reasoning_effort=\"max\"' --sandbox read-only"

# The checker must resolve the same override, or a brief fails its own check.
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$brief_file" --config-dir "$config_dir" >/dev/null

# The model stays pinned: preflight verifies the worker model's capability, and
# an override that swapped it would leave the run unverified.
printf '%s\n' 'worker_model = "gpt-5.6-sol"' > "$config_dir/.linchpin.toml"
expect_failure 'model substitution through config' \
  sh "$repo_root/scripts/linchpin.sh" config "$config_dir"

printf '%s\n' 'reviewer_effort = "turbo"' > "$config_dir/.linchpin.toml"
expect_failure 'unrecognized effort value' \
  sh "$repo_root/scripts/linchpin.sh" config "$config_dir"

pass 'effort is repo-configurable, the model pin is not, and the checker honors both'
