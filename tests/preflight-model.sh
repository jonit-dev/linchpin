#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

real_cache="${LINCHPIN_MODELS_CACHE:-${CODEX_HOME:-$HOME/.codex}/models_cache.json}"
sh "$repo_root/scripts/linchpin.sh" preflight "$real_cache" >/dev/null
expect_failure 'model cache without the worker capability' sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-without-luna.json"

# The multi-provider cache is the one later phases test against, and the
# zero-config run has to pass on it unchanged: both shipped roles are codex.
multi_config="$tmp_dir/multi-provider-repo"
mkdir -p "$multi_config"
multi_pass=$(env LINCHPIN_CONFIG_DIR="$multi_config" \
  sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-multi-provider.json")
assert_contains "$multi_pass" 'worker[provider=codex model=gpt-5.6-luna'
assert_contains "$multi_pass" 'reviewer[provider=codex model=gpt-5.6-sol'

# A claude role is verified by the CLI itself, and the stub stands in for it so
# the control costs nothing. A cache the claude role is absent from is not a
# refusal, because a cache is not how that provider is checked.
printf '%s\n' 'worker = "haiku-4.5"' 'worker_effort = "low"' > "$multi_config/.linchpin.toml"
stub_pass=$(env LINCHPIN_CONFIG_DIR="$multi_config" LINCHPIN_CLAUDE_BIN="$fixture_dir/fake-claude.sh" \
  sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-multi-provider.json")
assert_contains "$stub_pass" 'worker[provider=claude model=claude-haiku-4-5'
assert_contains "$stub_pass" 'verified=probed'
expect_failure 'claude worker the stub CLI does not know' \
  env LINCHPIN_CONFIG_DIR="$multi_config" LINCHPIN_CLAUDE_BIN="$fixture_dir/fake-claude.sh" \
      LINCHPIN_FAKE_CLAUDE_MODELS='claude-opus-5' \
      sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-multi-provider.json"
rm -f "$multi_config/.linchpin.toml"

# Every codex exec child writes its session state under CODEX_HOME before its
# model starts. A read-only CODEX_HOME killed the reviewer at the end of a lane,
# after all the worker time was already spent, and the run reported "committed
# but review-gated" with no review at all. Preflight is where that is found.
readonly_home="$tmp_dir/readonly-codex-home"
mkdir -p "$readonly_home"
cp "$fixture_dir/models-cache-with-luna.json" "$readonly_home/models_cache.json"
chmod 555 "$readonly_home"
if [ -w "$readonly_home" ]; then
  # Running as root, where no directory is unwritable. The control cannot be
  # observed red here, so say so rather than reporting a pass it did not earn.
  printf '%s\n' 'SKIP read-only CODEX_HOME control: this user can write any directory'
else
  expect_failure 'read-only CODEX_HOME' sh "$repo_root/scripts/linchpin.sh" preflight "$readonly_home/models_cache.json"
  refusal=$(sh "$repo_root/scripts/linchpin.sh" preflight "$readonly_home/models_cache.json" 2>&1 || true)
  assert_contains "$refusal" 'CODEX_HOME is not writable'
fi
chmod 755 "$readonly_home"

pass 'preflight checks each role by its own provider, and refuses a missing model or an unwritable CODEX_HOME'
