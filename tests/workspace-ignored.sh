#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Run output that shows up in `git status` is leftover the user cleans up by
# hand. The workspace command claims the ignore entries before the first write.
target="$tmp_dir/workspace-repo"
mkdir -p "$target"
git -C "$target" init -q .
printf 'tracked\n' > "$target/tracked.txt"
git -C "$target" add tracked.txt
git -C "$target" -c user.email=t@example.com -c user.name=t commit -qm 'init'

first=$(sh "$repo_root/scripts/linchpin.sh" workspace "$target")
assert_contains "$first" 'WORKSPACE-IGNORED .linchpin/'
assert_contains "$first" 'WORKSPACE-IGNORED .worktrees/'
assert_contains "$first" 'WORKSPACE-READY'
[ -d "$target/.linchpin" ] || fail 'workspace did not create the run directory'

# The ignore entry must not itself be a change to the user's tracked files.
git -C "$target" diff --quiet || fail 'workspace modified a tracked file'

printf 'ledger\n' > "$target/.linchpin/run-1.md"
mkdir -p "$target/.worktrees/lane-a"
status=$(git -C "$target" status --porcelain)
[ -z "$status" ] || fail "linchpin run output appeared in git status: $status"

# A second run must not append duplicate entries.
second=$(sh "$repo_root/scripts/linchpin.sh" workspace "$target")
assert_contains "$second" 'WORKSPACE-ALREADY-IGNORED .linchpin/'
entry_count=$(grep -Fxc '.linchpin/' "$target/.git/info/exclude" || true)
[ "$entry_count" -eq 1 ] || fail "workspace duplicated its exclude entry: $entry_count"

# A repository that already ignores the path needs no second entry.
other="$tmp_dir/pre-ignored-repo"
mkdir -p "$other"
git -C "$other" init -q .
printf '%s\n' '.linchpin/' '.worktrees/' > "$other/.gitignore"
pre=$(sh "$repo_root/scripts/linchpin.sh" workspace "$other")
assert_contains "$pre" 'WORKSPACE-ALREADY-IGNORED .linchpin/'
if [ -f "$other/.git/info/exclude" ] && grep -Fxq '.linchpin/' "$other/.git/info/exclude"; then
  fail 'workspace re-ignored a path .gitignore already covered'
fi

# Linchpin runs its own lanes in linked worktrees, so this is the common case.
# A linked worktree's own gitdir has an `info/exclude` that git never reads;
# writing there looks like success and ignores nothing. This needs a repository
# that has NOT already been prepared — a worktree of an excluded repo inherits
# the exclude and would pass without ever exercising the write path.
lane_parent="$tmp_dir/lane-parent"
mkdir -p "$lane_parent"
git -C "$lane_parent" init -q .
printf 'tracked\n' > "$lane_parent/tracked.txt"
git -C "$lane_parent" add tracked.txt
git -C "$lane_parent" -c user.email=t@example.com -c user.name=t commit -qm 'init'
git -C "$lane_parent" worktree add -q "$tmp_dir/lane-worktree" -b lane-branch
linked=$(sh "$repo_root/scripts/linchpin.sh" workspace "$tmp_dir/lane-worktree")
assert_contains "$linked" 'WORKSPACE-IGNORED .linchpin/'
assert_contains "$linked" 'WORKSPACE-READY'
printf 'ledger\n' > "$tmp_dir/lane-worktree/.linchpin/run-1.md"
mkdir -p "$tmp_dir/lane-worktree/.worktrees/nested"
linked_status=$(git -C "$tmp_dir/lane-worktree" status --porcelain)
[ -z "$linked_status" ] || fail "run output appeared in a linked worktree's git status: $linked_status"

expect_failure 'workspace outside a Git repository' \
  sh "$repo_root/scripts/linchpin.sh" workspace "$tmp_dir"

pass 'workspace ignores run output before the first write and stays out of git status'
