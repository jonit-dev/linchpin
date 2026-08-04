#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Workers left finished work uncommitted because the commit requirement lived in
# the manager's skill and never reached the worker's prompt. It has to be in the
# brief the worker actually reads.
fixture="$fixture_dir/conforming-prd.md"
brief_file="$tmp_dir/brief.md"
sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-commit parallel pr > "$brief_file"
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$brief_file" >/dev/null

brief_text=$(cat "$brief_file")
assert_contains "$brief_text" 'Commit rule:'
assert_contains "$brief_text" 'An uncommitted working tree is PARTIAL'
assert_contains "$brief_text" 'the manager owns delivery'
# A PRD that forbids committing outranks the default; that lane is complete, not
# partial, and must never be handed a repair round for obeying its own criteria.
assert_contains "$brief_text" 'Commit rule exception:'
# A worktree without dependencies is unfinished setup, not a verification result.
assert_contains "$brief_text" 'Environment rule:'

# The scope rule bounds what changes; it must not read as a ban on committing.
scope_line=$(grep -F 'Scope rule:' "$brief_file")
assert_contains "$scope_line" 'it never forbids committing what you did change'

# A worker with no resolved file set has nothing definite to stage, which is how
# correct work ended up uncommitted. The rule must fire whenever the file set did
# not resolve — including when the parser printed paths on its way to failing,
# where a plain "is the list empty" test wrongly reports success.
mangled="$tmp_dir/mangled-count.md"
sed 's/^\*\*Files ([0-9]*):\*\*$/**Files (99):**/' "$fixture" > "$mangled"
mangled_brief=$(sh "$repo_root/scripts/linchpin.sh" brief "$mangled" lane-x parallel pr)
assert_contains "$mangled_brief" 'UNPARSED'
assert_contains "$mangled_brief" 'File-set rule:'
# The resolved case must not carry it.
if printf '%s\n' "$brief_text" | grep -Fq 'File-set rule:'; then
  fail 'file-set rule was emitted for a PRD whose file set parsed'
fi

for required in 'Commit rule:' 'Commit rule exception:' 'Environment rule:'; do
  stripped="$tmp_dir/stripped.md"
  grep -Fv "$required" "$brief_file" > "$stripped"
  expect_failure "brief with $required removed" \
    sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$stripped"
done

pass 'worker brief states the commit requirement, its PRD exception, and the environment rule'
