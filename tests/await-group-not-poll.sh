#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Waiting is a per-group call, not a per-lane keepalive. Field runs that polled
# each live subprocess on a short timer spent hundreds of turns restating that a
# lane was still running.

run_dir="$tmp_dir/run"
mkdir -p "$run_dir"

(sleep 1; printf '0\n' > "$run_dir/lane-a.pid.exit") &
printf '%s\n' "$!" > "$run_dir/lane-a.pid"
(sleep 2; printf '1\n' > "$run_dir/lane-b.pid.exit") &
printf '%s\n' "$!" > "$run_dir/lane-b.pid"

awaited=$(sh "$repo_root/scripts/linchpin.sh" await \
  "$run_dir/lane-a.pid" "$run_dir/lane-b.pid" --interval 1)
assert_contains "$awaited" 'AWAIT-DONE lane=lane-a'
assert_contains "$awaited" 'AWAIT-DONE lane=lane-b'
assert_contains "$awaited" 'exit=1'
assert_contains "$awaited" 'AWAIT-COMPLETE lanes=2'

# A timeout is not a delivery result: it reports what is still alive and exits
# non-zero so the manager inspects the real diff instead of calling it done.
(sleep 30) &
slow_pid="$!"
printf '%s\n' "$slow_pid" > "$run_dir/lane-slow.pid"
expect_failure 'await past its timeout' \
  sh "$repo_root/scripts/linchpin.sh" await "$run_dir/lane-slow.pid" --interval 1 --timeout 2
timed_out=$(sh "$repo_root/scripts/linchpin.sh" await "$run_dir/lane-slow.pid" --interval 1 --timeout 2 2>&1 || true)
assert_contains "$timed_out" 'AWAIT-TIMEOUT'
kill "$slow_pid" 2>/dev/null || true

expect_failure 'await with no pidfile' sh "$repo_root/scripts/linchpin.sh" await --interval 1
expect_failure 'await on a missing pidfile' sh "$repo_root/scripts/linchpin.sh" await "$run_dir/absent.pid"
expect_failure 'await with a zero interval' \
  sh "$repo_root/scripts/linchpin.sh" await "$run_dir/lane-a.pid" --interval 0

pass 'await blocks on a whole group and reports each lane exit once'
