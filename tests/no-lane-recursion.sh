#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# A lane worker inherits the same plugin the manager runs, so the word "PRD" in
# its brief is enough to make it open the router and re-run intake on the PRD it
# was already handed. One field run spent a worker turn printing a routing
# verdict the manager had already reached. The brief has to say not to.
fixture="$fixture_dir/conforming-prd.md"
brief_file="$tmp_dir/brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-recursion parallel pr > "$brief_file"
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$brief_file" >/dev/null

prohibited=$(grep -F 'Prohibited actions:' "$brief_file")
assert_contains "$prohibited" 're-entering linchpin'
assert_contains "$prohibited" 'linchpin.sh route'
assert_contains "$prohibited" 'routing already happened'
# The pre-existing prohibitions stay; this is an addition, not a replacement.
assert_contains "$prohibited" 'native Luna spawning'
assert_contains "$prohibited" 'runtime tier changes'

stripped="$tmp_dir/stripped.md"
grep -Fv 'Prohibited actions:' "$brief_file" > "$stripped"
expect_failure 'brief with the prohibited-actions line removed' \
  sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$stripped"

# A brief that keeps the label but drops the re-entry clause is a stale copy of
# the rule, and brief-check matches the whole line for exactly that reason.
weakened="$tmp_dir/weakened.md"
sed 's/^Prohibited actions:.*/Prohibited actions: native Luna spawning; runtime tier changes/' "$brief_file" > "$weakened"
expect_failure 'brief whose prohibitions dropped the re-entry clause' \
  sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$weakened"

pass 'the worker brief forbids re-entering linchpin inside a lane'
