#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# A lane launched with a hand-written `&` from inside an agent tool call is
# reaped with that call's process group: the field run that did it got a pid, a
# zero-byte log, and an `AWAIT-DONE` after waiting zero seconds. `launch` owns
# the detach, records the real exit code for `await`, and refuses to report a
# lane as running when it died at launch.

run_dir="$tmp_dir/run"
mkdir -p "$run_dir"

launched=$(sh "$repo_root/scripts/linchpin.sh" launch \
  --pid "$run_dir/lane-live.pid" --log "$run_dir/lane-live.log" --settle 2 \
  -- sh -c 'printf "working\n"; sleep 30')
assert_contains "$launched" 'LAUNCH-READY lane=lane-live'
assert_contains "$launched" "log=$run_dir/lane-live.log"

live_pid=$(tr -dc '0-9' < "$run_dir/lane-live.pid")
kill -0 "$live_pid" 2>/dev/null || fail 'launched lane is not alive after settle'
assert_contains "$(cat "$run_dir/lane-live.log")" 'working'

# The lane runs in its own session, so the shell that started it going away does
# not take the lane with it — the exact failure this command exists to prevent.
if command -v setsid >/dev/null 2>&1 && ps -o sid= -p $$ >/dev/null 2>&1; then
  lane_sid=$(ps -o sid= -p "$live_pid" | tr -d ' ')
  caller_sid=$(ps -o sid= -p $$ | tr -d ' ')
  [ -n "$lane_sid" ] || fail 'launched lane has no session id to compare'
  [ "$lane_sid" = "$caller_sid" ] &&
    fail 'launched lane shares the caller session and would be reaped with it'
fi
kill "$live_pid" 2>/dev/null || true

# A lane that exits during the settle window is a launch failure, not a lane
# that finished. Its log tail is the reason, and the exit code is recorded where
# `await` reads it.
expect_failure 'launch of a command that dies immediately' \
  sh "$repo_root/scripts/linchpin.sh" launch \
  --pid "$run_dir/lane-dead.pid" --log "$run_dir/lane-dead.log" --settle 2 \
  -- sh -c 'printf "boom: no such model\n" >&2; exit 3'
died=$(sh "$repo_root/scripts/linchpin.sh" launch \
  --pid "$run_dir/lane-dead.pid" --log "$run_dir/lane-dead.log" --settle 2 \
  -- sh -c 'printf "boom: no such model\n" >&2; exit 3' 2>&1 || true)
assert_contains "$died" 'LAUNCH-FAIL died-immediately'
assert_contains "$died" 'exit=3'
assert_contains "$died" 'boom: no such model'
assert_contains "$(cat "$run_dir/lane-dead.pid.exit")" '3'

# The silent shape: gone with nothing written at all. That is what a reaped
# process group looks like, and it must never read as a completed lane.
silent=$(sh "$repo_root/scripts/linchpin.sh" launch \
  --pid "$run_dir/lane-silent.pid" --log "$run_dir/lane-silent.log" --settle 2 \
  -- true 2>&1 || true)
assert_contains "$silent" 'LAUNCH-FAIL died-immediately'
assert_contains "$silent" 'LAUNCH-LOG-EMPTY'

# `await` reads the exit code `launch` recorded, so a lane that failed is
# reported with its own status rather than the bare word `exited`.
awaited=$(sh "$repo_root/scripts/linchpin.sh" await "$run_dir/lane-dead.pid" --interval 1)
assert_contains "$awaited" 'AWAIT-DONE lane=lane-dead'
assert_contains "$awaited" 'exit=3'

expect_failure 'launch with no command' \
  sh "$repo_root/scripts/linchpin.sh" launch --pid "$run_dir/x.pid" --log "$run_dir/x.log" --
expect_failure 'launch without a pid file' \
  sh "$repo_root/scripts/linchpin.sh" launch --log "$run_dir/x.log" -- sleep 1
expect_failure 'launch of a command that is not on PATH' \
  sh "$repo_root/scripts/linchpin.sh" launch --pid "$run_dir/x.pid" --log "$run_dir/x.log" \
  -- linchpin-no-such-binary

pass 'launch detaches a lane, records its exit, and fails loudly when it dies at launch'
