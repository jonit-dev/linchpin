#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# The user points at a .md; Linchpin executes what is in it. The contract is a
# standard for artifacts Linchpin authors, never an admission gate on the user's
# own document.
helper="$repo_root/scripts/linchpin.sh"
raw="$fixture_dir/raw-prd.md"
conforming="$fixture_dir/conforming-prd.md"

route_output=$(sh "$helper" route 'start these PRDs' "$raw")
assert_contains "$route_output" 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
case "$route_output" in
  *prd-creator*) fail 'a raw plan was routed to authoring instead of execution' ;;
esac

brief_file="$tmp_dir/raw-brief.txt"
sh "$helper" brief "$raw" --lane-id lane-1 --lane-mode sequential --delivery-mode branch > "$brief_file" ||
  fail 'brief refused a raw plan'
assert_contains "$(cat "$brief_file")" 'UNPARSED'
assert_contains "$(cat "$brief_file")" 'NOT DECLARED in this PRD'
assert_contains "$(cat "$brief_file")" 'Lane mode: sequential'
sh "$helper" brief-check "$raw" "$brief_file" >/dev/null || fail 'brief-check refused a raw plan'

# A plan with no parseable file list can still be scheduled; it just never
# claims an isolated lane.
mode_output=$(sh "$helper" mode auto "$raw" "$conforming")
assert_contains "$mode_output" 'ANNOUNCE:'
assert_contains "$mode_output" 'mode=sequential'

# Observed red: a path that is not on disk is the one real execution blocker.
expect_failure 'brief on a path that does not exist' sh "$helper" brief "$tmp_dir/absent.md"
assert_contains "$(sh "$helper" route 'start these' "$tmp_dir/absent.md")" 'ROUTE-EXECUTE-NONE -> ask-once'

pass 'a user-supplied plan executes as written without migration or rewriting'
