#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# A manager used to own the lane lifecycle: it built each launch command, then
# spent a model turn per interval restating that the lane was still running.
# These are the controls for the code that took that over. Every case here runs
# the real `linchpin.sh run` / `events` CLI against a fake provider that records
# each actual invocation, so a duplicate launch is counted rather than inferred.

command -v jq >/dev/null 2>&1 || { printf 'SKIP runner lifecycle needs jq\n'; exit 0; }

linchpin="$repo_root/scripts/linchpin.sh"
fake="$fixture_dir/fake-provider.sh"
invocations="$tmp_dir/invocations"
export LINCHPIN_FAKE_PROVIDER_LOG="$invocations"
export LINCHPIN_RUNNER_INTERVAL=1

new_repo() {
  # One disposable repository per scenario, with its lane working directories
  # already created: the runner refuses a bootstrap naming a cwd that is absent.
  repo="$tmp_dir/$1"
  mkdir -p "$repo/.linchpin" "$repo/lane-a" "$repo/lane-b"
  printf 'fixture\n' > "$repo/prd.md"
}

bootstrap_json() {
  # $1 repo, $2 mode, $3 sleep seconds, $4 output path
  jq -n --arg repo "$1" --arg prd "$1/prd.md" --arg fake "$fake" \
    --arg wta "$1/lane-a" --arg wtb "$1/lane-b" --arg mode "$2" '{
    bootstrap_contract: "v1", repo: $repo, base: "main", delivery: "pr", max_lanes: 4,
    audit: {mode: "auto", mode_source: "default", eligible: "no", reason: "no HIGH PRD"},
    prds: [{path: $prd, class: "LOW"}], gates: [],
    groups: [{id: "group-1", mode: $mode, lanes: [
      {id: "lane-a", prd: $prd, cwd: $wta, command: [$fake, "lane-a"]},
      {id: "lane-b", prd: $prd, cwd: $wtb, command: [$fake, "lane-b"]}]}]
  }' > "$4"
}

run_id_of() {
  printf '%s\n' "$1" | sed -n 's/^RUN-[A-Z]* run=\([^ ]*\).*/\1/p'
}

wait_for_status() {
  # $1 run dir, $2 status, $3 seconds. Polling a fixture is not the thing this
  # PRD forbids — the forbidden poll is a model turn per interval.
  wait_waited=0
  while [ "$wait_waited" -lt "$3" ]; do
    [ "$(jq -r '.status' "$1/state.json")" != "$2" ] || return 0
    sleep 1
    wait_waited=$((wait_waited + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# One batch, two parallel lanes: two provider invocations, monotonic cursors,
# and a terminal state that says which one it reached.
: > "$invocations"
new_repo happy
bootstrap_json "$repo" parallel 2 "$tmp_dir/happy.json"
export LINCHPIN_FAKE_PROVIDER_SLEEP=2
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/happy.json")
assert_contains "$started" 'RUN-STARTED'
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
wait_for_status "$run_dir" complete 30 || fail 'the happy-path run never reached a terminal state'
[ "$(awk 'NF' "$invocations" | wc -l | tr -d ' ')" -eq 2 ] ||
  fail "two lanes produced $(awk 'NF' "$invocations" | wc -l | tr -d ' ') provider invocations"
events=$(sh "$linchpin" events "$run" --repo "$repo" --after 0)
assert_contains "$events" '"type":"run_started"'
assert_contains "$events" '"type":"operation_intent"'
assert_contains "$events" '"type":"operation_launched"'
assert_contains "$events" '"type":"run_complete"'
assert_contains "$events" 'EVENTS-CURSOR'
# Monotonic, gapless cursors. A stream that can repeat a cursor is a stream a
# caller cannot resume from.
cursors=$(jq -r '.cursor' "$run_dir/events.jsonl")
[ "$(printf '%s\n' "$cursors" | sort -n | uniq | wc -l | tr -d ' ')" -eq "$(printf '%s\n' "$cursors" | wc -l | tr -d ' ')" ] ||
  fail 'the event stream repeated a cursor'
[ "$(printf '%s\n' "$cursors" | sort -n | tr '\n' ' ')" = "$(printf '%s\n' "$cursors" | tr '\n' ' ')" ] ||
  fail 'the event stream is not monotonic'
# Intent is recorded before the launch it describes, for every operation.
for op in op-lane-a-1 op-lane-b-1; do
  intent_cursor=$(jq -r --arg op "$op" 'select(.operation == $op and .type == "operation_intent") | .cursor' "$run_dir/events.jsonl")
  launch_cursor=$(jq -r --arg op "$op" 'select(.operation == $op and .type == "operation_launched") | .cursor' "$run_dir/events.jsonl")
  [ "$intent_cursor" -lt "$launch_cursor" ] || fail "$op was launched before its intent was recorded"
  [ -f "$run_dir/operations/$op/intent.json" ] || fail "$op has no launch receipt on disk"
  [ -f "$run_dir/operations/$op/receipt.json" ] || fail "$op has no provider receipt on disk"
  [ -f "$run_dir/operations/$op/log" ] || fail "$op kept no raw log"
done
# The raw log stays on disk; the event carries identities and a reason.
assert_contains "$(cat "$run_dir/operations/op-lane-a-1/log")" 'FAKE-PROVIDER lane=lane-a'
if jq -r '.reason' "$run_dir/events.jsonl" | grep -Fq 'FAKE-PROVIDER'; then
  fail 'the event stream inlined the raw provider log'
fi
# A resume after the fact is a no-op that says so, not a second batch.
terminal=$(sh "$linchpin" run --resume "$run" --repo "$repo")
assert_contains "$terminal" 'RUN-TERMINAL'
assert_contains "$terminal" 'status=complete'
[ "$(awk 'NF' "$invocations" | wc -l | tr -d ' ')" -eq 2 ] ||
  fail 'resuming a finished run launched something'

# ---------------------------------------------------------------------------
# THE CASE THAT PAYS FOR ITSELF: two resumes against a lane that is still
# running. One provider invocation, one stable operation id, no second charge.
: > "$invocations"
new_repo resume
bootstrap_json "$repo" sequential 8 "$tmp_dir/resume.json"
export LINCHPIN_FAKE_PROVIDER_SLEEP=8
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/resume.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
sleep 3
[ "$(jq -r '.groups[0].lanes[0].state' "$run_dir/state.json")" = RUNNING ] ||
  fail 'the first lane is not RUNNING while its provider is still alive'
first_resume=$(sh "$linchpin" run --resume "$run" --repo "$repo")
second_resume=$(sh "$linchpin" run --resume "$run" --repo "$repo")
assert_contains "$first_resume" 'RUN-RECONNECTED'
assert_contains "$second_resume" 'RUN-RECONNECTED'
[ "$(awk 'NF' "$invocations" | wc -l | tr -d ' ')" -eq 1 ] ||
  fail "two resumes against a running lane produced $(awk 'NF' "$invocations" | wc -l | tr -d ' ') provider invocations"
[ "$(jq -r '.groups[0].lanes[0].operation' "$run_dir/state.json")" = op-lane-a-1 ] ||
  fail 'the operation id moved under a resume'
[ "$(jq -r '.groups[0].lanes[0].attempts' "$run_dir/state.json")" -eq 1 ] ||
  fail 'a resume counted a second launch attempt against a live operation'

# The wait is bounded and says nothing that asks a model to reason. This is the
# call that replaced 954 thirty-second polls.
heartbeat=$(sh "$linchpin" events "$run" --repo "$repo" \
  --after "$(jq -r '.cursor' "$run_dir/events.jsonl" | tail -1)" --wait --timeout 2)
assert_contains "$heartbeat" 'EVENTS-HEARTBEAT'
assert_contains "$heartbeat" 'nothing to decide, call again'
assert_contains "$heartbeat" 'bounded host wait'
case "$heartbeat" in
  *ERROR*|*'?'*) fail 'the wait timeout asked a question instead of reporting a heartbeat' ;;
esac
wait_for_status "$run_dir" complete 40 || fail 'the sequential run never finished'
[ "$(awk 'NF' "$invocations" | wc -l | tr -d ' ')" -eq 2 ] ||
  fail 'the sequential group did not run both lanes exactly once'
# Sequential means one at a time: the second lane's intent comes after the
# first lane's exit.
first_exit=$(jq -r 'select(.operation == "op-lane-a-1" and .type == "operation_exited") | .cursor' "$run_dir/events.jsonl")
second_intent=$(jq -r 'select(.operation == "op-lane-b-1" and .type == "operation_intent") | .cursor' "$run_dir/events.jsonl")
[ "$first_exit" -lt "$second_intent" ] || fail 'a sequential group launched its second lane before the first exited'

# ---------------------------------------------------------------------------
# Crash in the launch window. The child recorded no pid, so the provider may or
# may not have been reached. Neither a relaunch nor a completion may be assumed.
: > "$invocations"
new_repo uncertain
bootstrap_json "$repo" parallel 1 "$tmp_dir/uncertain.json"
export LINCHPIN_FAKE_PROVIDER_SLEEP=1
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/uncertain.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
wait_for_status "$run_dir" complete 30 || fail 'the fixture run for the uncertain case never finished'
# Rewrite one lane back into the ambiguous state and resume.
rm -rf "$run_dir/operations/op-lane-a-2"
mkdir -p "$run_dir/operations/op-lane-a-2"
jq -n '{operation: "op-lane-a-2", lane: "lane-a", group: "group-1", command: []}' \
  > "$run_dir/operations/op-lane-a-2/intent.json"
jq -n '{operation: "op-lane-a-2", state: "launch_uncertain", at: "now"}' \
  > "$run_dir/operations/op-lane-a-2/receipt.json"
jq '(.groups[0].lanes[0]) |= (.state = "RUNNING" | .operation = "op-lane-a-2" | .exit = null) | .status = "running" | del(.supervisor)' \
  "$run_dir/state.json" > "$run_dir/state.next" && mv "$run_dir/state.next" "$run_dir/state.json"
before_uncertain=$(awk 'NF' "$invocations" | wc -l | tr -d ' ')
sh "$linchpin" run --resume "$run" --repo "$repo" >/dev/null
wait_for_status "$run_dir" running 30 || true
sleep 3
[ "$(awk 'NF' "$invocations" | wc -l | tr -d ' ')" -eq "$before_uncertain" ] ||
  fail 'a lane that crashed in its launch window was relaunched'
assert_contains "$(jq -r '.type' "$run_dir/events.jsonl" | tr '\n' ' ')" 'decision_required'
assert_contains "$(jq -r 'select(.type == "decision_required") | .reason' "$run_dir/events.jsonl")" \
  'reconcile the provider session'
[ "$(jq -r '.groups[0].lanes[0].state' "$run_dir/state.json")" = BLOCKED ] ||
  fail 'an unreconcilable lane did not end BLOCKED'
[ "$(jq -r '.status' "$run_dir/state.json")" = blocked ] ||
  fail 'a run holding a blocked lane did not end blocked'

# ---------------------------------------------------------------------------
# PID reuse. A recorded pid that is alive but is not the process the receipt
# identified is not a running lane.
: > "$invocations"
new_repo pidreuse
bootstrap_json "$repo" parallel 1 "$tmp_dir/pidreuse.json"
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/pidreuse.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
wait_for_status "$run_dir" complete 30 || fail 'the fixture run for the pid-reuse case never finished'
mkdir -p "$run_dir/operations/op-lane-b-2"
jq -n '{operation: "op-lane-b-2", lane: "lane-b", group: "group-1", command: []}' \
  > "$run_dir/operations/op-lane-b-2/intent.json"
# $$ is alive right now, and its start-time token is certainly not this one.
jq -n --arg pid "$$" '{operation: "op-lane-b-2", state: "running", pid: $pid, process_identity: "0"}' \
  > "$run_dir/operations/op-lane-b-2/receipt.json"
jq '(.groups[0].lanes[1]) |= (.state = "RUNNING" | .operation = "op-lane-b-2" | .exit = null) | .status = "running" | del(.supervisor)' \
  "$run_dir/state.json" > "$run_dir/state.next" && mv "$run_dir/state.next" "$run_dir/state.json"
sh "$linchpin" run --resume "$run" --repo "$repo" >/dev/null
sleep 4
[ "$(jq -r '.status' "$run_dir/state.json")" != running ] ||
  fail 'a recycled pid was mistaken for a live lane and the run waited on it'
assert_contains "$(jq -r 'select(.type == "decision_required") | .reason' "$run_dir/events.jsonl")" \
  'lane-b'

# ---------------------------------------------------------------------------
# A completed result is accepted once, by operation id.
: > "$invocations"
new_repo duplicate
bootstrap_json "$repo" parallel 1 "$tmp_dir/duplicate.json"
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/duplicate.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
wait_for_status "$run_dir" complete 30 || fail 'the fixture run for the duplicate case never finished'
exited_events=$(jq -r 'select(.type == "operation_exited" and .operation == "op-lane-a-1")' "$run_dir/events.jsonl" | jq -s 'length')
[ "$exited_events" -eq 1 ] || fail "one operation produced $exited_events exit events"
# Force a second intake of the same finished operation.
jq '(.groups[0].lanes[0]) |= (.state = "RUNNING" | .exit = null) | .status = "running" | del(.supervisor)' \
  "$run_dir/state.json" > "$run_dir/state.next" && mv "$run_dir/state.next" "$run_dir/state.json"
sh "$linchpin" run --resume "$run" --repo "$repo" >/dev/null
sleep 4
assert_contains "$(jq -r '.type' "$run_dir/events.jsonl" | tr '\n' ' ')" 'operation_result_duplicate'
[ "$(awk 'NF' "$invocations" | wc -l | tr -d ' ')" -eq 2 ] ||
  fail 'a duplicate result intake relaunched the provider'

# ---------------------------------------------------------------------------
# Incomplete bootstrap state is refused rather than guessed at.
new_repo bootstrap
bootstrap_json "$repo" parallel 1 "$tmp_dir/valid.json"
for broken in \
  'del(.gates)' \
  'del(.repo)' \
  '.groups = []' \
  '.groups[0].lanes[0].command = []' \
  '.groups[0].mode = "whenever"' \
  '.audit.eligible = "unresolved"' \
  '.bootstrap_contract = "v2"' \
  '.groups[0].lanes[0].cwd = "/nonexistent/lane"'; do
  jq "$broken" "$tmp_dir/valid.json" > "$tmp_dir/broken.json"
  expect_failure "bootstrap state with: $broken" \
    sh "$linchpin" run --bootstrap "$tmp_dir/broken.json"
done
expect_failure 'a resume naming a run that does not exist' \
  sh "$linchpin" run --resume run-not-here --repo "$repo"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. Disable launch deduplication in an isolated copy: the
# resume that reconnected must now invoke the provider a second time.
: > "$invocations"
dedup_off="$tmp_dir/dedup-disabled"
copy_repo "$dedup_off"
# `runner_operation_live` is the dedup. With it always false, a live lane reads
# as a dead one and the supervisor relaunches it.
sed -i.bak 's/^runner_operation_live() {/runner_operation_live() {\n  return 1/' "$dedup_off/scripts/runner.sh"
rm -f "$dedup_off/scripts/runner.sh.bak"
grep -Fq 'runner_operation_live() {' "$dedup_off/scripts/runner.sh" ||
  fail 'the dedup control did not patch the runner'
new_repo dedup
bootstrap_json "$repo" sequential 8 "$tmp_dir/dedup.json"
export LINCHPIN_FAKE_PROVIDER_SLEEP=8
started=$(sh "$dedup_off/scripts/linchpin.sh" run --bootstrap "$tmp_dir/dedup.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
sleep 3
jq 'del(.supervisor)' "$run_dir/state.json" > "$run_dir/state.next" && mv "$run_dir/state.next" "$run_dir/state.json"
sh "$dedup_off/scripts/linchpin.sh" run --resume "$run" --repo "$repo" >/dev/null
sleep 4
dedup_invocations=$(awk 'NF' "$invocations" | wc -l | tr -d ' ')
[ "$dedup_invocations" -gt 1 ] ||
  fail 'the dedup control produced no duplicate launch; the control proves nothing'
printf 'OBSERVED-RED %s\n' "launch deduplication disabled: one lane invoked the provider $dedup_invocations times"
# Let the duplicated providers finish on their own rather than killing by
# pattern: a `pkill -f` wide enough to catch them is wide enough to catch the
# shell that is running this test.
wait_for_status "$run_dir" running 40 || true

pass 'the runner owns process lifecycle: bounded scheduling, receipts before launches, resume without a second charge, and a wait that costs no inference'
