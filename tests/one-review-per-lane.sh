#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# "One review and repair" was a sentence in the coordinator and nothing more. A
# real run launched seven reviewers at one PRD across nine and a half hours —
# review, review4, review5, review6, review-final, review-final2, review-final3,
# every one of them REQUEST_CHANGES against defects the previous repair had
# exposed — while its ledger still read `repair_rounds: 1`. Nothing in the
# helper could count the rounds, so nothing could stop them. These are the
# controls for the cap that replaced the sentence.

fixture="$fixture_dir/conforming-prd.md"
gates="$tmp_dir/gate-evidence.md"
cp "$fixture_dir/gate-all-green.md" "$gates"

# The ledger lives at <repo>/.linchpin/run-<timestamp>.md, and `lane` resolves
# the repository two levels up from it to verify a recorded commit.
repo="$tmp_dir/repo"
mkdir -p "$repo/.linchpin"
ledger="$repo/.linchpin/run-test.md"
sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-1 \
  --set state=RUNNING --set prd="$fixture" --repo "$repo" >/dev/null

# A review the ledger never saw is the one there is always room for another of.
expect_failure 'review brief without a ledger' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 \
    --gates "$gates" --commit abc1234
expect_failure 'review brief against a lane the ledger does not know' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-absent \
    --gates "$gates" --commit abc1234 --ledger "$ledger"

# Round 1 is the ordinary path and needs no ceremony.
first=$(sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 \
  --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$tmp_dir/review-1.md")
assert_contains "$first" 'REVIEW-BRIEF-WRITTEN'
assert_contains "$first" 'round=1/2'
# The count is in the ledger, not in the manager's memory of it.
assert_contains "$(cat "$ledger")" '- review_rounds: 1'
assert_contains "$(cat "$ledger")" '- review_used: true'

# Round 2 exists, but drifting into it does not. This is the exact step the real
# run took six times without ever naming it.
expect_failure 'a second review that was not asked for' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 \
    --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$tmp_dir/review-2.md"
# A refused round is not a spent one.
assert_contains "$(cat "$ledger")" '- review_rounds: 1'

second=$(sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 \
  --gates "$gates" --commit abc1234 --ledger "$ledger" --round 2 --out "$tmp_dir/review-2.md")
assert_contains "$second" 'round=2/2'
assert_contains "$(cat "$ledger")" '- review_rounds: 2'

# Round 3 is refused however it is asked for. There is no flag that buys it.
expect_failure 'a third review' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 \
    --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$tmp_dir/review-3.md"
expect_failure 'a third review requested explicitly' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 \
    --gates "$gates" --commit abc1234 --ledger "$ledger" --round 3 --out "$tmp_dir/review-3.md"

# The other half of the loop: PARTIAL is what `status` calls still-open, so a
# lane parked there after its last review is a standing invitation to run one
# more round. The exhausted lane must resolve to something a person can act on.
expect_failure 'a PARTIAL lane that has spent its reviews' \
  sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-1 \
    --set state=PARTIAL --repo "$repo"
expect_failure 'a blocked lane with no resume command' \
  sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-1 \
    --set state=BLOCKED --set reason='replay divergence unresolved' --repo "$repo"

blocked=$(sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-1 \
  --set state=BLOCKED --set reason='replay divergence unresolved' \
  --set resume='codex exec resume abc123' --repo "$repo")
assert_contains "$blocked" 'LANE-RECORDED lane-1 state=BLOCKED'

# A lane that never reached its cap is untouched by any of this: PARTIAL after
# one review is an ordinary, resumable state and must stay recordable.
sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-2 \
  --set state=RUNNING --set prd="$fixture" --repo "$repo" >/dev/null
sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-2 \
  --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$tmp_dir/review-lane2.md" >/dev/null
partial=$(sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-2 \
  --set state=PARTIAL --repo "$repo")
assert_contains "$partial" 'LANE-RECORDED lane-2 state=PARTIAL'

pass 'review rounds are counted in the ledger, capped at two, and an exhausted lane cannot stay PARTIAL'
