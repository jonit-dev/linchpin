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

# A plan with no parseable `Files (N)` list still declared its paths in prose.
# Read them for grouping so a legacy batch is not collapsed into one queue.
mode_output=$(sh "$helper" mode auto "$raw" "$conforming")
assert_contains "$mode_output" 'derived from its prose'
assert_contains "$mode_output" 'mode=parallel'

# A document that declares no file set at all takes its own group and says so,
# rather than dragging every other lane behind it.
silent="$tmp_dir/no-files.md"
printf '# Plan\n\nProse only. No file declaration anywhere.\n' > "$silent"
silent_output=$(sh "$helper" mode auto "$silent" "$conforming")
assert_contains "$silent_output" 'isolation is unproven'
assert_contains "$silent_output" 'group=2'
expect_failure 'forced parallel over a PRD that declares no file set' \
  sh "$helper" mode parallel "$silent" "$conforming"

# Delivery is not an admission gate either. A raw plan that never declared
# Negative Controls reports them as not declared instead of blocking the lane.
report="$tmp_dir/gate-report.md"
printf '## Gate Evidence\n| Gate | Result | Observed-red evidence | Exact command/result |\n|---|---|---|---|\n' > "$report"
gate_output=$(sh "$helper" gate "$raw" "$report") || fail 'gate refused a raw plan at delivery'
assert_contains "$gate_output" 'GATES-NOT-DECLARED'

# The controls a PRD *does* declare stay binding: green-only evidence is red.
expect_failure 'green-only evidence against a declared control' \
  sh "$helper" gate "$conforming" "$fixture_dir/gate-all-green.md"
assert_contains "$(sh "$helper" gate "$conforming" "$fixture_dir/gate-observed-red.md")" 'GATES-PASS'

# Observed red: a path that is not on disk is the one real execution blocker.
expect_failure 'brief on a path that does not exist' sh "$helper" brief "$tmp_dir/absent.md"
assert_contains "$(sh "$helper" route 'start these' "$tmp_dir/absent.md")" 'ROUTE-EXECUTE-NONE -> ask-once'

pass 'a user-supplied plan executes as written without migration or rewriting'
