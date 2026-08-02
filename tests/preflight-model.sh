#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

real_cache="${LINCHPIN_MODELS_CACHE:-${CODEX_HOME:-$HOME/.codex}/models_cache.json}"
sh "$repo_root/scripts/linchpin.sh" preflight "$real_cache" >/dev/null
expect_failure 'model cache without the worker capability' sh "$repo_root/scripts/linchpin.sh" preflight "$fixture_dir/models-cache-without-luna.json"
pass 'preflight checks the configured cache and refuses missing Luna without fallback'
