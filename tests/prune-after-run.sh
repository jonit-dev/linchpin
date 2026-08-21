#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Closing a run has to leave the repository the way the user handed it over.
# The field failure this guards: after a batch, every finished lane was still a
# checked-out worktree and a local branch, and because the PRs had been squashed
# the user could not tell from `git branch` which of them were already shipped.

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

sh "$repo_root/scripts/linchpin.sh" workspace "$main_repo" >/dev/null
ledger="$main_repo/.linchpin/run-prune.md"

lane_commit() {
  lane_path="$main_repo/.worktrees/$1"
  printf '%s\n' "$1" > "$lane_path/$1.txt"
  git -C "$lane_path" add "$1.txt"
  git -C "$lane_path" commit --quiet -m "$1 work"
  git -C "$lane_path" rev-parse HEAD
}

for lane in lane-a lane-b lane-c lane-d; do
  sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo" "$lane" release >/dev/null
done
sha_a=$(lane_commit lane-a)
sha_b=$(lane_commit lane-b)
lane_commit lane-c >/dev/null
sha_d=$(lane_commit lane-d)

# lane-a shipped the way a PR normally lands: squashed onto the base, so its own
# commits are unreachable from release and `git branch -d` calls it unmerged.
git -C "$main_repo" merge --squash --quiet linchpin/lane-a >/dev/null
git -C "$main_repo" commit --quiet -m 'lane-a (squashed)'
git -C "$main_repo" push --quiet origin release
# lane-b is an open PR: unmerged, but its commits are on the remote.
git -C "$main_repo" push --quiet origin linchpin/lane-b
git -C "$main_repo" fetch --quiet origin
# lane-d never left the machine, and someone left an edit behind in it.
printf 'not committed\n' > "$main_repo/.worktrees/lane-d/scratch.txt"

record() {
  sh "$repo_root/scripts/linchpin.sh" lane "$ledger" "$1" \
    --set state="$2" --set prd=docs/PRDs/PRD-1.md --set branch="linchpin/$1" \
    --set commit="$3" --set gates=NOT-DECLARED --set review=approve >/dev/null
}
record lane-a 'DELIVERED(branch)' "$sha_a"
record lane-b 'DELIVERED(pr)' "$sha_b"
sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-c \
  --set state=PARTIAL --set prd=docs/PRDs/PRD-3.md --set branch=linchpin/lane-c >/dev/null
record lane-d 'DELIVERED(branch)' "$sha_d"

# The user's own uncommitted work in the source tree, which cleanup must not touch.
printf 'uncommitted edit\n' >> "$main_repo/file.txt"
dirty_before=$(git -C "$main_repo" status --porcelain)

dry=$(sh "$repo_root/scripts/linchpin.sh" prune "$ledger" --dry-run)
assert_contains "$dry" 'PRUNE-WOULD-REMOVE lane=lane-a'
assert_contains "$dry" 'PRUNE-WOULD-DELETE lane=lane-a'
[ -d "$main_repo/.worktrees/lane-a" ] || fail 'a dry run removed a lane worktree'
git -C "$main_repo" show-ref --verify --quiet refs/heads/linchpin/lane-a ||
  fail 'a dry run deleted a lane branch'

pruned=$(sh "$repo_root/scripts/linchpin.sh" prune "$ledger")

# A squash merge is the ordinary case, not the edge case.
assert_contains "$pruned" 'PRUNE-WORKTREE lane=lane-a'
assert_contains "$pruned" 'PRUNE-BRANCH lane=lane-a branch=linchpin/lane-a reason=squashed-onto-origin/release'
if [ -d "$main_repo/.worktrees/lane-a" ]; then fail 'delivered lane worktree was not removed'; fi
if git -C "$main_repo" show-ref --verify --quiet refs/heads/linchpin/lane-a; then
  fail 'squash-merged lane branch was not deleted'
fi

# An open PR still owns lane-b's commits, so the local branch is disposable.
assert_contains "$pruned" 'PRUNE-BRANCH lane=lane-b branch=linchpin/lane-b reason=pushed-to-origin/linchpin/lane-b'

# Nothing that is not delivered loses its worktree or its branch.
assert_contains "$pruned" 'PRUNE-KEPT lane=lane-c state=PARTIAL'
[ -d "$main_repo/.worktrees/lane-c" ] || fail 'PARTIAL lane lost its worktree'
git -C "$main_repo" show-ref --verify --quiet refs/heads/linchpin/lane-c ||
  fail 'PARTIAL lane lost its branch'

# Uncommitted work is never deleted on the strength of a ledger row.
assert_contains "$pruned" 'PRUNE-KEPT lane=lane-d state=DELIVERED(branch) worktree='
assert_contains "$pruned" 'reason=uncommitted-changes'
[ -f "$main_repo/.worktrees/lane-d/scratch.txt" ] || fail 'uncommitted lane work was deleted'

[ "$(git -C "$main_repo" status --porcelain)" = "$dirty_before" ] ||
  fail 'pruning modified the source working tree'

# Running it again finds nothing left to do rather than failing.
again=$(sh "$repo_root/scripts/linchpin.sh" prune "$ledger")
assert_contains "$again" 'PRUNE-DONE worktrees=0 branches=0 kept=2'

forced=$(sh "$repo_root/scripts/linchpin.sh" prune "$ledger" --force)
assert_contains "$forced" 'PRUNE-WORKTREE lane=lane-d'
if [ -d "$main_repo/.worktrees/lane-d" ]; then fail '--force did not remove the lane worktree'; fi
# Its commits are on no remote and in no base, so the branch survives the force
# with the command that removes it.
assert_contains "$forced" 'PRUNE-KEPT-BRANCH lane=lane-d branch=linchpin/lane-d reason=commits-only-here'
git -C "$main_repo" show-ref --verify --quiet refs/heads/linchpin/lane-d ||
  fail 'a branch whose commits exist nowhere else was deleted'

expect_failure 'prune run from inside a lane worktree' \
  sh "$repo_root/scripts/linchpin.sh" prune "$ledger" --repo "$main_repo/.worktrees/lane-c"

pass 'closing a run removes delivered lanes and keeps everything still in play'
