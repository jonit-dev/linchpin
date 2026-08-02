#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fallback=$(sh "$repo_root/scripts/linchpin.sh" schedule auto fail lane-a lane-b)
assert_contains "$fallback" 'ANNOUNCE: git worktree add failed'
assert_contains "$fallback" 'mode=sequential'
suppressed=$(printf '%s\n' "$fallback" | sed '/^ANNOUNCE:/d')
if printf '%s\n' "$suppressed" | grep -q 'mode=sequential'; then
  printf '%s\n' 'OBSERVED-RED suppressed fallback announcement would be rejected'
else
  fail 'fallback negative control did not detect a suppressed announcement'
fi
expect_failure 'forced parallel worktree failure' sh "$repo_root/scripts/linchpin.sh" schedule parallel fail lane-a lane-b
pass 'worktree failure degrades to announced sequential scheduling'
