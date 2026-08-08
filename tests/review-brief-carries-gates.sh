#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# The reviewer runs read-only: it cannot install, write, or run the repository's
# suites. Launched without the manager's gate evidence it can only report what it
# was unable to do, which is a rejection that says nothing about the code.
fixture="$fixture_dir/conforming-prd.md"
gates="$tmp_dir/gate-evidence.md"
cp "$fixture_dir/gate-all-green.md" "$gates"

# The round cap lives in the ledger, so a review brief needs one. Rounds
# themselves are covered by one-review-per-lane.sh; here it is only the row the
# other assertions need to exist.
repo="$tmp_dir/gates-repo"
mkdir -p "$repo/.linchpin"
ledger="$repo/.linchpin/run-test.md"
sh "$repo_root/scripts/linchpin.sh" lane "$ledger" lane-1 \
  --set state=RUNNING --set prd="$fixture" --repo "$repo" >/dev/null

expect_failure 'review brief without gate evidence' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 --commit abc1234 --ledger "$ledger"
expect_failure 'review brief without a lane commit' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 --gates "$gates" --ledger "$ledger"
expect_failure 'review brief with a malformed lane identity' \
  sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" 'bad lane' --gates "$gates" --commit abc1234 --ledger "$ledger"

review_file="$tmp_dir/review.md"
written=$(sh "$repo_root/scripts/linchpin.sh" review-brief "$fixture" lane-1 \
  --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$review_file")
assert_contains "$written" 'REVIEW-BRIEF-WRITTEN'

review_text=$(cat "$review_file")
assert_contains "$review_text" 'Lane commit under review: abc1234'
# The gate results must travel with the brief, the way the one lane that got them
# did: it was the only lane whose review found defects instead of missing tools.
assert_contains "$review_text" '## Manager Gate Evidence'
# Assert on a row only the gate file has. A markdown table separator also occurs
# in the PRD's own verbatim Negative Controls block, so matching one proves
# nothing about whether the gate evidence was inlined at all.
assert_contains "$review_text" 'result: all green checks passed; exit: 0'
# The reviewer's own sandbox is the expected condition, never a finding.
assert_contains "$review_text" 'That is the expected condition of this role, not a finding.'
# An evidence gap is recorded, not a veto.
assert_contains "$review_text" 'DEFECT'
assert_contains "$review_text" 'EVIDENCE-GAP never blocks delivery on its own'
assert_contains "$review_text" 'REQUEST_CHANGES requires at least one DEFECT'
# A brief that pre-classifies a fact guarantees the verdict it names.
assert_contains "$review_text" 'Facts stated in this brief are context, not findings.'
assert_contains "$review_text" 'APPROVE with zero findings is a valid and useful review.'

# The PRD's own acceptance criteria and controls still travel verbatim.
assert_contains "$review_text" '## Acceptance Criteria (verbatim)'
assert_contains "$review_text" '## Negative Controls (verbatim)'

pass 'review brief carries gate evidence and a committed lane, and bars evidence gaps from blocking'
