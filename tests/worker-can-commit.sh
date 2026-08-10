#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# A lane is a worktree plus a commit. Under codex's default workspace-write
# sandbox the worker can do neither, so the invocation the manager is told to
# run must carry the flag that lifts it. This test holds that shape in place.

fixture="$fixture_dir/conforming-prd.md"
brief=$(sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr)
invocation=$(printf '%s\n' "$brief" | grep -F 'Runtime invocation: worker=')
[ -n "$invocation" ] || fail 'brief carries no runtime invocation line'
assert_contains "$invocation" 'worker=codex exec --sandbox danger-full-access'
# The reviewer half of the same line stays read-only: the whole point of paying
# for a second model is that it cannot touch what it judges.
assert_contains "$invocation" '--sandbox read-only -C <lane> <review>'

# The reason the flag exists, asserted against real git rather than restated.
# A worktree keeps its metadata in the parent repository, so the directory the
# sandbox makes writable is not the directory git must write to commit.
origin="$tmp_dir/worktree-metadata"
mkdir -p "$origin"
git init -q "$origin"
git -C "$origin" config user.email linchpin@example.com
git -C "$origin" config user.name linchpin
printf '%s\n' seed > "$origin/seed.txt"
git -C "$origin" add seed.txt
git -C "$origin" commit -qm seed
git -C "$origin" worktree add -q "$tmp_dir/lane" -b lane-branch
lane_git_dir=$(git -C "$tmp_dir/lane" rev-parse --absolute-git-dir)
case "$lane_git_dir" in
  "$tmp_dir/lane"/*) fail "worktree git metadata is inside the lane; the sandbox rationale is stale: $lane_git_dir" ;;
esac
printf 'OBSERVED %s\n' "lane git dir resolves outside the lane: $lane_git_dir"

# Observed-red control: drop the flag from the Worker row and every brief must
# refuse to be written, rather than emitting a lane that cannot commit.
copy="$tmp_dir/no-sandbox-flag"
copy_repo "$copy"
sed 's/`codex exec --sandbox danger-full-access`/`codex exec`/' "$copy/references/runtime.md" > "$copy/references/runtime.md.tmp"
mv "$copy/references/runtime.md.tmp" "$copy/references/runtime.md"
grep -F '| Worker | ' "$copy/references/runtime.md" | grep -F 'danger-full-access' >/dev/null &&
  fail 'control did not actually remove the flag from the Worker row'
expect_failure 'worker row without its sandbox flag' \
  sh "$copy/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr

pass 'worker invocation can write the worktree it is given, reviewer stays read-only'
