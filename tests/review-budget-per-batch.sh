#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Finding 4 of docs/codex-session-audit-2026-09-06.md. The review limit was
# stored per ledger row and consumed per lane id, so it was keyed to a name a
# manager chooses rather than to the work being reviewed. The AutopilotRank
# ledger recorded five successive lanes for one source PRD — repair and
# supersession lanes, not five independent PRDs — whose review rounds summed to
# 2 + 2 + 1 + 2 + 1 = 8, corroborated by eight distinct reviewer sessions. Every
# lane passed its own cap while the same task was reviewed eight times.
#
# Renaming the lane must not refill the budget. The budget belongs to the PRD.

linchpin="$repo_root/scripts/linchpin.sh"
fixture="$fixture_dir/conforming-prd.md"
gates="$tmp_dir/gate-evidence.md"
cp "$fixture_dir/gate-all-green.md" "$gates"

repo="$tmp_dir/repo"
mkdir -p "$repo/.linchpin"
ledger="$repo/.linchpin/run-test.md"

# A second PRD, so the control below can show the cap is keyed to the PRD and
# not merely to "any review in this ledger".
other="$tmp_dir/other-prd.md"
cp "$fixture" "$other"

lane() {
  sh "$linchpin" lane "$ledger" "$1" --set state=RUNNING --set prd="$2" --repo "$repo" >/dev/null
}

review() {
  sh "$linchpin" review-brief "$1" "$2" --gates "$gates" --commit abc1234 \
    --ledger "$ledger" --out "$tmp_dir/review-$2-$3.md" ${3:+--round "$3"}
}

# Two lanes, one PRD: the repair lane and the lane it supersedes.
lane lane-1 "$fixture"
lane lane-1-repair "$fixture"

first=$(review "$fixture" lane-1 '')
assert_contains "$first" 'round=1/2'
second=$(review "$fixture" lane-1 2)
assert_contains "$second" 'round=2/2'

# The batch's two reviews are spent. A new lane id over the same PRD is the
# rename the field ledger performed five times.
expect_failure 'a renamed repair lane refilling the review budget' \
  sh "$linchpin" review-brief "$fixture" lane-1-repair \
    --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$tmp_dir/review-repair.md"
expect_failure 'a renamed repair lane asking for the round explicitly' \
  sh "$linchpin" review-brief "$fixture" lane-1-repair --round 3 \
    --gates "$gates" --commit abc1234 --ledger "$ledger" --out "$tmp_dir/review-repair.md"
printf '%s\n' 'OBSERVED-RED a renamed lane over the same PRD gets no fresh reviews'

# The refusal has to name the PRD budget, or a manager reads it as this lane's
# own cap and renames again.
refusal=$(sh "$linchpin" review-brief "$fixture" lane-1-repair \
  --gates "$gates" --commit abc1234 --ledger "$ledger" 2>&1 || true)
assert_contains "$refusal" "$fixture"
case "$refusal" in
  *'lane-1'*) ;;
  *) fail 'the refusal does not name the lanes that already spent the budget' ;;
esac

# A genuinely different PRD is a different batch and keeps its own two reviews.
lane lane-2 "$other"
other_first=$(review "$other" lane-2 '')
assert_contains "$other_first" 'round=1/2'

pass 'the review budget is keyed to the PRD, so a lane rename cannot refill it'
