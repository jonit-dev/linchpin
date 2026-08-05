#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# The coordinator calls a run without a ledger unresumable, then asks a manager
# model to type fifteen fields per lane from memory. These controls cover the
# rows that memory gets wrong: a delivered lane whose sha nobody created, a
# delivered lane with no gate evidence on disk, and a blocked lane with no way
# to resume it.
linchpin="$repo_root/scripts/linchpin.sh"
target="$tmp_dir/ledger-repo"
mkdir -p "$target"
git -C "$target" init -q .
printf 'tracked\n' > "$target/tracked.txt"
git -C "$target" add tracked.txt
git -C "$target" -c user.email=t@example.com -c user.name=t commit -qm 'init'
real_sha=$(git -C "$target" rev-parse HEAD)
mkdir -p "$target/.linchpin"
ledger="$target/.linchpin/run-1.md"
printf 'gate evidence\n' > "$target/.linchpin/gates-a.md"

first=$(sh "$linchpin" lane "$ledger" lane-a --set state=RUNNING --set prd=docs/PRDs/a.md --set branch=linchpin/lane-a)
assert_contains "$first" 'LANE-RECORDED lane-a state=RUNNING'
[ -f "$ledger" ] || fail 'lane did not create the run ledger'

# A second lane must not disturb the first, and a re-record must keep the fields
# an earlier call wrote instead of rewriting the row from this call's flags.
sh "$linchpin" lane "$ledger" lane-b --set state=PENDING --set prd=docs/PRDs/b.md >/dev/null
sh "$linchpin" lane "$ledger" lane-a --set state=PARTIAL >/dev/null
kept=$(sh "$linchpin" status "$ledger" || true)
assert_contains "$kept" 'PARTIAL lane=lane-a prd=docs/PRDs/a.md branch=linchpin/lane-a'
assert_contains "$kept" 'PENDING lane=lane-b'

delivered=$(sh "$linchpin" lane "$ledger" lane-a \
  --set 'state=DELIVERED(pr)' --set "commit=$real_sha" \
  --set gates=.linchpin/gates-a.md --set review=approve)
assert_contains "$delivered" 'LANE-RECORDED lane-a state=DELIVERED(pr)'
heading_count=$(grep -Fc '## Lane: lane-a' "$ledger" || true)
[ "$heading_count" -eq 1 ] || fail "re-recording a lane duplicated its block: $heading_count"

# Exit code is the whole point of `status`: a goal loop needs "keep going" and
# "stop, a human is required" to be different answers from "done".
if sh "$linchpin" status "$ledger" >/dev/null; then
  fail 'status exited zero while a lane was still open'
fi
sh "$linchpin" lane "$ledger" lane-b --set state=BLOCKED --set 'reason=upstream API is down' \
  --set 'resume=sh scripts/linchpin.sh lane .linchpin/run-1.md lane-b --set state=RUNNING' >/dev/null
sh "$linchpin" status "$ledger" >"$tmp_dir/blocked.out" 2>&1 && blocked_exit=0 || blocked_exit=$?
[ "$blocked_exit" -eq 2 ] || fail "status did not report blocked-only with exit 2: $blocked_exit"
assert_contains "$(cat "$tmp_dir/blocked.out")" 'RUN-STATUS delivered=1 partial=0 blocked=1'

sh "$linchpin" lane "$ledger" lane-b --set 'state=DELIVERED(branch)' --set prd=docs/PRDs/b.md \
  --set branch=linchpin/lane-b --set "commit=$real_sha" --set gates=NOT-DECLARED --set review=approve >/dev/null
sh "$linchpin" status "$ledger" >"$tmp_dir/done.out" || fail 'status did not exit zero with every lane delivered'
assert_contains "$(cat "$tmp_dir/done.out")" 'RUN-STATUS delivered=2 partial=0 blocked=0'

# Observed-red controls.
expect_failure 'lane state that is not a terminal form' \
  sh "$linchpin" lane "$ledger" lane-c --set state=DONE
expect_failure 'MERGED recorded as a product state' \
  sh "$linchpin" lane "$ledger" lane-c --set state=MERGED
expect_failure 'lane row with no state' \
  sh "$linchpin" lane "$ledger" lane-c --set prd=docs/PRDs/c.md
expect_failure 'delivered lane with no commit' \
  sh "$linchpin" lane "$ledger" lane-c --set 'state=DELIVERED(pr)' --set prd=docs/PRDs/c.md \
    --set branch=linchpin/lane-c --set gates=NOT-DECLARED --set review=approve
expect_failure 'delivered lane whose commit sha does not exist' \
  sh "$linchpin" lane "$ledger" lane-c --set 'state=DELIVERED(pr)' --set prd=docs/PRDs/c.md \
    --set branch=linchpin/lane-c --set commit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
    --set gates=NOT-DECLARED --set review=approve
expect_failure 'delivered lane whose gate evidence is not on disk' \
  sh "$linchpin" lane "$ledger" lane-c --set 'state=DELIVERED(pr)' --set prd=docs/PRDs/c.md \
    --set branch=linchpin/lane-c --set "commit=$real_sha" \
    --set gates=.linchpin/gates-missing.md --set review=approve
expect_failure 'blocked lane with no resume command' \
  sh "$linchpin" lane "$ledger" lane-c --set state=BLOCKED --set 'reason=upstream API is down'
expect_failure 'lane field with an empty value' \
  sh "$linchpin" lane "$ledger" lane-c --set state=RUNNING --set prd=
expect_failure 'lane recorded with no fields at all' \
  sh "$linchpin" lane "$ledger" lane-c
expect_failure 'status of a ledger that does not exist' \
  sh "$linchpin" status "$tmp_dir/no-such-ledger.md"

# A rejected row must not be half-written: lane-c failed every way above, so it
# must not appear in the ledger at all.
if grep -Fq '## Lane: lane-c' "$ledger"; then
  fail 'a rejected lane row was written to the ledger anyway'
fi

pass 'the run ledger is written by a helper that refuses a claim it cannot verify'
