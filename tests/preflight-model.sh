#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

real_cache="${LINCHPIN_MODELS_CACHE:-${CODEX_HOME:-$HOME/.codex}/models_cache.json}"
sh "$repo_root/scripts/linchpin.sh" preflight "$real_cache" >/dev/null
expect_failure 'model cache without the worker capability' sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-without-luna.json"

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

pass 'preflight checks the configured cache, refuses missing Luna, and refuses an unwritable CODEX_HOME'
