#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Preflight is the one refusal that happens before a branch exists. Each
# provider is verified the only way it can be — codex against its capability
# cache, claude against a live probe — and neither has a fallback.
cache="$fixture_dir/models-cache-multi-provider.json"
fake_claude="$fixture_dir/fake-claude.sh"
config_dir="$tmp_dir/preflight-repo"
mkdir -p "$config_dir"

# Zero config: both roles codex, verified out of the cache, and the PASS line
# says so rather than implying it.
zero=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$repo_root/scripts/linchpin.sh" preflight "$cache")
assert_contains "$zero" 'PREFLIGHT-PASS'
assert_contains "$zero" 'worker[provider=codex'
assert_contains "$zero" "verified=cache=$cache"
assert_contains "$zero" 'reviewer[provider=codex'

# A claude worker beside a codex reviewer: one probe, one cache lookup, and the
# line names how each was checked. A run reports what it actually verified.
printf '%s\n' 'worker = "opus-5"' 'worker_effort = "medium"' \
  'reviewer = "astra"' 'reviewer_effort = "medium"' > "$config_dir/.linchpin.toml"
mixed=$(env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$fake_claude" \
  sh "$repo_root/scripts/linchpin.sh" preflight "$cache")
assert_contains "$mixed" 'worker[provider=claude model=claude-opus-5'
assert_contains "$mixed" 'verified=probed'
assert_contains "$mixed" 'reviewer[provider=codex model=gpt-6-astra'
assert_contains "$mixed" "verified=cache=$cache"

# The probe is a real invocation, so it carries the model and the print flag the
# provider actually needs. A probe that does not look like a run proves nothing.
argv_log="$tmp_dir/probe-argv"
: > "$argv_log"
env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$fake_claude" \
  LINCHPIN_FAKE_CLAUDE_ARGV="$argv_log" \
  sh "$repo_root/scripts/linchpin.sh" preflight "$cache" >/dev/null
assert_contains "$(cat "$argv_log")" '--model claude-opus-5'
assert_contains "$(cat "$argv_log")" '-p'
[ "$(wc -l < "$argv_log" | tr -d ' ')" -eq 1 ] ||
  fail 'preflight probed more than once for a single claude role'

# Both roles on claude, one shared slug: still exactly one probe. The cost of
# preflight is per distinct model, not per role.
printf '%s\n' 'worker = "opus-5"' 'worker_effort = "medium"' \
  'reviewer = "opus-5"' 'reviewer_effort = "medium"' > "$config_dir/.linchpin.toml"
: > "$argv_log"
env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$fake_claude" \
  LINCHPIN_FAKE_CLAUDE_ARGV="$argv_log" \
  sh "$repo_root/scripts/linchpin.sh" preflight "$cache" >/dev/null
[ "$(wc -l < "$argv_log" | tr -d ' ')" -eq 1 ] ||
  fail 'preflight probed the same claude slug twice'

# NEGATIVE CONTROL: a claude model the CLI will not accept is a hard refusal
# before any branch exists, with no fallback to a model that does work.
printf '%s\n' 'worker = "opus-5"' 'worker_effort = "medium"' > "$config_dir/.linchpin.toml"
expect_failure 'claude worker on a model the CLI rejects' \
  env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$fake_claude" \
      LINCHPIN_FAKE_CLAUDE_MODELS='claude-sonnet-5' \
      sh "$repo_root/scripts/linchpin.sh" preflight "$cache"
refusal=$(env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$fake_claude" \
  LINCHPIN_FAKE_CLAUDE_MODELS='claude-sonnet-5' \
  sh "$repo_root/scripts/linchpin.sh" preflight "$cache" 2>&1 || true)
assert_contains "$refusal" 'claude model probe failed: claude-opus-5'
case "$refusal" in
  *PREFLIGHT-PASS*) fail 'a failed claude probe still reported a pass' ;;
  *claude-sonnet-5*) fail 'preflight fell back to a model the config never asked for' ;;
esac

# The binary itself is part of the check: a claude role with no CLI on PATH is
# refused here rather than at the first lane.
expect_failure 'claude role with no Claude Code CLI' \
  env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$tmp_dir/not-a-claude" \
      sh "$repo_root/scripts/linchpin.sh" preflight "$cache"

# A codex role still fails on a cache that does not carry it.
printf '%s\n' 'reviewer = "terra"' > "$config_dir/.linchpin.toml"
expect_failure 'codex reviewer missing from the multi-provider cache' \
  env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$fake_claude" \
      sh "$repo_root/scripts/linchpin.sh" preflight "$cache"

pass 'preflight verifies codex roles by cache and claude roles by probe, and refuses either without falling back'
