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

# The announced reason has to be the reason that happened. A dirty tree does not
# get reported as a worktree failure that was never attempted.
dirty=$(sh "$repo_root/scripts/linchpin.sh" schedule auto dirty-tree lane-a lane-b)
assert_contains "$dirty" 'could not be safely stashed'
case "$dirty" in
  *'git worktree add failed'*) fail 'a dirty tree was announced as a worktree failure' ;;
esac
assert_contains "$(sh "$repo_root/scripts/linchpin.sh" schedule auto unparsed-files lane-a)" 'no separable file set'
expect_failure 'unknown degradation status' sh "$repo_root/scripts/linchpin.sh" schedule auto invented lane-a

pass 'each degradation announces the reason that actually happened'
