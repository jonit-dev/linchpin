#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# The brief names the PRD; the lane reads it from inside its own worktree. Three
# days of Codex session logs have that path resolving to nothing in 80 of 172
# lane sessions across five repositories: the manager passes
# `docs/PRDs/<name>.md`, the worktree is checked out from `origin/<base>`, and a
# PRD written minutes before the run is not committed on that base. The worker's
# first `sed` on it fails and the lane proceeds on the excerpts alone; the
# read-only reviewer, which fails more often than the worker, then approves
# against those same excerpts instead of against the PRD.

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

# The PRD as the field has it: written into the source tree and not committed,
# because writing it and running it is one sitting.
mkdir -p "$main_repo/docs/PRDs"
cp "$fixture_dir/conforming-prd.md" "$main_repo/docs/PRDs/lane.md"

sh "$repo_root/scripts/linchpin.sh" workspace "$main_repo" >/dev/null
sh "$repo_root/scripts/linchpin.sh" worktree "$main_repo" lane-a release >/dev/null
lane_worktree="$main_repo/.worktrees/lane-a"
if [ -f "$lane_worktree/docs/PRDs/lane.md" ]; then
  fail 'test setup is wrong: the PRD is already committed on the lane base'
fi

# The manager types the path it has, which is the one relative to its own repo.
brief_file="$main_repo/.linchpin/lane-a.brief"
( cd "$main_repo" &&
  sh "$repo_root/scripts/linchpin.sh" brief docs/PRDs/lane.md lane-a parallel branch \
    --config-dir "$main_repo" --out "$brief_file" ) >/dev/null

briefed_prd=$(sed -n 's/^Source PRD: //p' "$brief_file")
[ -n "$briefed_prd" ] || fail 'worker brief names no source PRD'

# Read it the way the worker does: from inside the lane worktree, which is the
# only directory the worker is ever given.
if ! ( cd "$lane_worktree" && [ -f "$briefed_prd" ] ); then
  fail "worker brief names a PRD the lane cannot open: $briefed_prd"
fi
if ! ( cd "$lane_worktree" && grep -Fq '## 4. Execution Phases' "$briefed_prd" ); then
  fail "the path the lane resolves is not the PRD the manager briefed: $briefed_prd"
fi

# The path now points outside the lane, and the worker holds
# `--sandbox danger-full-access`. Naming it without bounding it trades a PRD the
# lane cannot read for a PRD the lane can edit under the manager's feet.
brief_text=$(cat "$brief_file")
assert_contains "$brief_text" 'Source rule:'
assert_contains "$brief_text" 'never write to it'

# Same path, same failure, on the half of the run that is supposed to catch it.
gates="$tmp_dir/gate-evidence.md"
cp "$fixture_dir/gate-all-green.md" "$gates"
ledger="$main_repo/.linchpin/run-test.md"
sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-a \
  --set state=RUNNING --set prd="$main_repo/docs/PRDs/lane.md" --repo "$main_repo" >/dev/null

review_file="$main_repo/.linchpin/lane-a.review"
( cd "$main_repo" &&
  sh "$repo_root/scripts/linchpin.sh" review-brief docs/PRDs/lane.md lane-a \
    --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$review_file" ) >/dev/null

reviewed_prd=$(sed -n 's/^Source PRD: //p' "$review_file")
[ -n "$reviewed_prd" ] || fail 'review brief names no source PRD'
if ! ( cd "$lane_worktree" && [ -f "$reviewed_prd" ] ); then
  fail "review brief names a PRD the reviewer cannot open: $reviewed_prd"
fi

# An absolute path the manager already resolved must survive untouched.
absolute_brief="$tmp_dir/absolute.brief"
( cd "$tmp_dir" &&
  sh "$repo_root/scripts/linchpin.sh" brief "$main_repo/docs/PRDs/lane.md" lane-b parallel branch \
    --config-dir "$main_repo" --out "$absolute_brief" ) >/dev/null
assert_contains "$(cat "$absolute_brief")" "Source PRD: $main_repo/docs/PRDs/lane.md"

pass 'worker and review briefs name a PRD the lane worktree can actually open'
