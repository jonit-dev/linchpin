#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# A lane worktree must come from linchpin, not from whatever worktree helper the
# manager finds on the machine. The field failure this guards: a foreign helper
# pulled the base branch inside the user's dirty source tree and left an
# unresolved merge across twenty uncommitted files.

origin_repo="$tmp_dir/origin.git"
main_repo="$tmp_dir/main"
git init --quiet --bare "$origin_repo"
git init --quiet "$main_repo"
git -C "$main_repo" config user.email linchpin@example.invalid
git -C "$main_repo" config user.name 'Linchpin Tests'
printf 'base\n' > "$main_repo/file.txt"
git -C "$main_repo" add file.txt
git -C "$main_repo" commit --quiet -m 'base commit'
git -C "$main_repo" branch -M release
git -C "$main_repo" remote add origin "$origin_repo"
git -C "$main_repo" push --quiet origin release

# Run output is claimed before the first write, exactly as a real run does, so a
# lane worktree never shows up as untracked clutter in the user's git status.
sh "$repo_root/scripts/linchpin.sh" workspace "$main_repo" >/dev/null

# The user's own uncommitted work. It must be exactly as it was afterwards.
printf 'uncommitted edit\n' >> "$main_repo/file.txt"
dirty_before=$(git -C "$main_repo" status --porcelain)
head_before=$(git -C "$main_repo" rev-parse HEAD)

ready=$(sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo" lane-a release)
assert_contains "$ready" 'WORKTREE-READY'
assert_contains "$ready" 'branch=linchpin/lane-a'
assert_contains "$ready" 'base=origin/release'
[ -d "$main_repo/.worktrees/lane-a" ] || fail 'lane worktree was not created'

[ "$(git -C "$main_repo" status --porcelain)" = "$dirty_before" ] ||
  fail 'creating a lane modified the source working tree'
[ "$(git -C "$main_repo" rev-parse HEAD)" = "$head_before" ] ||
  fail 'creating a lane moved the source branch'
if [ -e "$main_repo/.git/MERGE_HEAD" ]; then
  fail 'creating a lane left a merge in progress'
fi

# Nesting: the same command run from inside the lane must refuse rather than
# build `.worktrees/lane-a/.worktrees/lane-b` off lane A's branch.
expect_failure 'lane created from inside another lane' \
  sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo/.worktrees/lane-a" lane-b release
nested=$(sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo/.worktrees/lane-a" lane-b release 2>&1 || true)
assert_contains "$nested" 'WORKTREE-FAIL nested'

expect_failure 'reused lane slug' \
  sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo" lane-a release
expect_failure 'base ref that does not resolve' \
  sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo" lane-c no-such-base
expect_failure 'malformed lane slug' \
  sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo" '../escape' release

pass 'lane worktrees are isolated, never nested, and never touch the source tree'
