#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# The brief is the handoff, so the shape a role is launched with has to be in it
# and has to be the shape its own provider takes. A codex flag on a claude role
# is a lane that dies at argument parsing, after the worktree exists.
fixture="$fixture_dir/conforming-prd.md"
config_dir="$tmp_dir/invocation-repo"
mkdir -p "$config_dir"

emit_brief() {
  sh "$repo_root/scripts/linchpin.sh" brief "$fixture" lane-1 parallel pr \
    --config-dir "$config_dir" --out "$1" >/dev/null
}

# Zero config is unchanged apart from the two provider lines: the codex worker
# still takes -C and its brief as an argument.
default_brief="$tmp_dir/default.brief"
emit_brief "$default_brief"
default_text=$(cat "$default_brief")
assert_contains "$default_text" 'Worker provider: codex'
assert_contains "$default_text" 'Reviewer provider: codex'
assert_contains "$default_text" "-c 'model_reasoning_effort=\"max\"' -C <lane> <brief>"
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$default_brief" --config-dir "$config_dir" >/dev/null

# A claude worker beside a codex reviewer: two providers, two shapes, in one
# brief. The claude role takes --effort and its brief on stdin; it never takes
# -C, because Claude Code has no such flag.
printf '%s\n' 'worker = "opus-5"' 'worker_effort = "xhigh"' \
  'reviewer = "astra"' 'reviewer_effort = "medium"' > "$config_dir/.linchpin.toml"
mixed_brief="$tmp_dir/mixed.brief"
emit_brief "$mixed_brief"
mixed_text=$(cat "$mixed_brief")
assert_contains "$mixed_text" 'Worker provider: claude'
assert_contains "$mixed_text" 'Reviewer provider: codex'
assert_contains "$mixed_text" 'Worker runtime: model=claude-opus-5; effort=xhigh; mechanism=claude -p --permission-mode bypassPermissions'
assert_contains "$mixed_text" 'claude -p --permission-mode bypassPermissions --model claude-opus-5 --effort xhigh'
assert_contains "$mixed_text" 'brief on stdin'
assert_contains "$mixed_text" "codex exec --model gpt-6-astra -c 'model_reasoning_effort=\"medium\"' --sandbox read-only"
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$mixed_brief" --config-dir "$config_dir" >/dev/null

# A claude reviewer is denied write tools outright; that is its read-only
# guarantee, and it has to reach the brief.
printf '%s\n' 'reviewer = "sonnet-5"' 'reviewer_effort = "high"' > "$config_dir/.linchpin.toml"
reviewer_brief="$tmp_dir/reviewer.brief"
emit_brief "$reviewer_brief"
assert_contains "$(cat "$reviewer_brief")" '--permission-mode plan --disallowed-tools "Edit Write NotebookEdit"'
sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$reviewer_brief" --config-dir "$config_dir" >/dev/null

# NEGATIVE CONTROL: a claude worker invocation carrying the codex effort flag is
# the stale shape a hand-edited brief produces. brief-check rejects it.
printf '%s\n' 'worker = "opus-5"' 'worker_effort = "medium"' > "$config_dir/.linchpin.toml"
stale_brief="$tmp_dir/stale.brief"
emit_brief "$stale_brief"
sed "s/--effort medium/-c 'model_reasoning_effort=\"medium\"'/" "$stale_brief" > "$stale_brief.tmp"
mv "$stale_brief.tmp" "$stale_brief"
expect_failure 'claude worker brief carrying the codex effort flag' \
  sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$stale_brief" --config-dir "$config_dir"

# NEGATIVE CONTROL: the provider line is checked exactly, so a brief built for
# one provider cannot be checked as another.
swapped_brief="$tmp_dir/swapped.brief"
emit_brief "$swapped_brief"
sed 's/^Worker provider: claude$/Worker provider: codex/' "$swapped_brief" > "$swapped_brief.tmp"
mv "$swapped_brief.tmp" "$swapped_brief"
expect_failure 'brief whose Worker provider line was rewritten' \
  sh "$repo_root/scripts/linchpin.sh" brief-check "$fixture" "$swapped_brief" --config-dir "$config_dir"

# NEGATIVE CONTROL: restore the gpt-only slug filter in the resolver. A Claude
# id then cannot survive alias resolution, and config refuses rather than
# silently running the shipped pin.
copy="$tmp_dir/gpt-only-resolver"
copy_repo "$copy"
sed 's/\^(gpt-|codex-|claude-)/^gpt-/g' "$repo_root/scripts/linchpin.sh" > "$copy/scripts/linchpin.sh"
grep -q 'slug !~ /\^gpt-/' "$copy/scripts/linchpin.sh" ||
  fail 'negative control did not narrow the resolver slug filter'
expect_failure 'claude worker against a resolver gated on ^gpt-' \
  sh "$copy/scripts/linchpin.sh" config "$config_dir"

# `launch --cwd` starts the lane inside its own worktree, because Claude Code
# has no -C and a lane started elsewhere commits to the wrong repository.
lane_dir="$tmp_dir/lane-worktree"
mkdir -p "$lane_dir"
launch_stdin="$tmp_dir/launch.brief"
printf '%s\n' 'BRIEF BODY ON STDIN' > "$launch_stdin"
argv_log="$tmp_dir/launch-argv"
stdin_log="$tmp_dir/launch-stdin"
: > "$argv_log"
env LINCHPIN_FAKE_CLAUDE_ARGV="$argv_log" LINCHPIN_FAKE_CLAUDE_STDIN="$stdin_log" \
  sh "$repo_root/scripts/linchpin.sh" launch \
    --pid "$tmp_dir/lane-1.pid" --log "$tmp_dir/lane-1.log" --settle 0 \
    --cwd "$lane_dir" --stdin "$launch_stdin" \
    -- sh -c "\"$fixture_dir/fake-claude.sh\" -p --model claude-opus-5 --effort medium; sleep 3" >/dev/null
launch_waited=0
while [ "$launch_waited" -lt 15 ] && [ ! -f "$tmp_dir/lane-1.pid.exit" ]; do
  sleep 1
  launch_waited=$((launch_waited + 1))
done
[ -f "$tmp_dir/lane-1.pid.exit" ] || fail 'launched lane never recorded an exit code'
assert_contains "$(cat "$tmp_dir/lane-1.log")" "cwd=$lane_dir"
assert_contains "$(cat "$stdin_log")" 'BRIEF BODY ON STDIN'

# NEGATIVE CONTROL: without --cwd the lane runs wherever the manager stood, and
# the recorded cwd proves it is not the worktree.
: > "$argv_log"
env LINCHPIN_FAKE_CLAUDE_ARGV="$argv_log" \
  sh "$repo_root/scripts/linchpin.sh" launch \
    --pid "$tmp_dir/lane-2.pid" --log "$tmp_dir/lane-2.log" --settle 0 \
    -- sh -c "\"$fixture_dir/fake-claude.sh\" -p --model claude-opus-5 --effort medium; sleep 3" >/dev/null
launch_waited=0
while [ "$launch_waited" -lt 15 ] && [ ! -f "$tmp_dir/lane-2.pid.exit" ]; do
  sleep 1
  launch_waited=$((launch_waited + 1))
done
case "$(cat "$tmp_dir/lane-2.log")" in
  *"cwd=$lane_dir"*) fail 'a lane launched without --cwd still landed in the worktree' ;;
esac
printf '%s\n' 'OBSERVED-RED a claude lane launched without --cwd runs outside its worktree'

# Both options are optional; omitting them is exactly today's behavior.
sh "$repo_root/scripts/linchpin.sh" launch \
  --pid "$tmp_dir/lane-3.pid" --log "$tmp_dir/lane-3.log" --settle 0 \
  -- sh -c 'sleep 1' >/dev/null
expect_failure 'launch --cwd pointed at something that is not a directory' \
  sh "$repo_root/scripts/linchpin.sh" launch \
    --pid "$tmp_dir/lane-4.pid" --log "$tmp_dir/lane-4.log" --settle 0 \
    --cwd "$tmp_dir/no-such-directory" -- sh -c 'true'
expect_failure 'launch --stdin pointed at a file that is not there' \
  sh "$repo_root/scripts/linchpin.sh" launch \
    --pid "$tmp_dir/lane-5.pid" --log "$tmp_dir/lane-5.log" --settle 0 \
    --stdin "$tmp_dir/no-such-brief" -- sh -c 'true'

pass 'each role is emitted, checked, and launched in its own provider shape'
