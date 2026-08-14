#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# A manager that has not memorised the argument order asks the tool. Session
# logs have `lane --help`, `worktree --help`, `gate --help` and `brief --help`
# answered with `ERROR: usage:` at exit 1, or with `ERROR: missing file:
# --help`, which reads as a broken command rather than as an answer. The manager
# then guesses the arguments, and a guessed `lane` call is a ledger row that
# never gets written.

for helped in brief brief-check review-brief lane worktree gate status launch await mode route schedule config workspace preflight files contract migrate; do
  help_out="$tmp_dir/help-$helped.out"
  if ! sh "$repo_root/scripts/linchpin.sh" "$helped" --help > "$help_out" 2>&1; then
    cat "$help_out" >&2
    fail "$helped --help exited non-zero"
  fi
  help_text=$(cat "$help_out")
  case "$help_text" in
    *ERROR:*) fail "$helped --help answered with an error: $help_text" ;;
  esac
  # The answer has to be about the command that was asked about, not the whole
  # usage screen: a manager who gets the screen back is where this started.
  assert_contains "$help_text" "$helped "
  if [ "$(printf '%s\n' "$help_text" | grep -c '^linchpin.sh COMMAND')" -ne 0 ]; then
    fail "$helped --help returned the whole usage screen instead of its own entry"
  fi
done

# `-h` is the same question typed shorter.
short_out=$(sh "$repo_root/scripts/linchpin.sh" lane -h 2>&1)
assert_contains "$short_out" 'lane LEDGER LANE_ID'

# Multi-line entries keep their continuation lines; those hold the flags that
# the failing calls in the logs were missing.
review_help=$(sh "$repo_root/scripts/linchpin.sh" review-brief --help 2>&1)
assert_contains "$review_help" '--ledger PATH'
brief_help=$(sh "$repo_root/scripts/linchpin.sh" brief --help 2>&1)
assert_contains "$brief_help" '--config-dir DIR'

# Help for something that is not a command stays a failure; a tool that answers
# every question has answered none of them.
expect_failure 'help for a command that does not exist' \
  sh "$repo_root/scripts/linchpin.sh" not-a-command --help

# The bare invocation prints usage and fails, and says nothing else. The shift
# diagnostic that used to lead it is the first line a manager reads, and it
# points at the tool being broken rather than at the missing argument.
bare_err="$tmp_dir/bare.err"
if sh "$repo_root/scripts/linchpin.sh" >"$tmp_dir/bare.out" 2>"$bare_err"; then
  fail 'bare invocation should fail'
fi
if grep -q 'shift' "$bare_err"; then
  cat "$bare_err" >&2
  fail 'bare invocation printed a shell diagnostic before its usage text'
fi
assert_contains "$(cat "$bare_err")" 'linchpin.sh COMMAND [ARGS]'

pass 'every subcommand answers --help, and the bare invocation prints usage alone'
