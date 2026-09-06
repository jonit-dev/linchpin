#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Finding 1 of docs/codex-session-audit-2026-09-06.md. The shipped runner
# declared a run `complete` the moment no lane was pending, running, or
# blocked. It never ran the gate list it was handed, a nonzero lane exit became
# `PARTIAL` and still permitted completion, and an audit-eligible batch reached
# `complete` with `audit_attempts: 0`. Twelve saved field states said `complete`
# that way; seven of them were audit-eligible.
#
# Process completion is not task readiness. These are the controls that keep
# the two apart, and none of them costs a model call.

command -v jq >/dev/null 2>&1 || { printf 'SKIP runner completion controls need jq\n'; exit 0; }

linchpin="$repo_root/scripts/linchpin.sh"
export LINCHPIN_RUNNER_INTERVAL=1

new_repo() {
  repo="$tmp_dir/$1"
  mkdir -p "$repo/.linchpin" "$repo/lane-a"
  printf 'fixture\n' > "$repo/prd.md"
}

# $1 repo, $2 eligible, $3 worker argv json, $4 gates json, $5 out
bootstrap_json() {
  jq -n --arg repo "$1" --arg prd "$1/prd.md" --arg wt "$1/lane-a" \
    --arg eligible "$2" --argjson command "$3" --argjson gates "$4" \
    --arg class "$(if [ "$2" = yes ]; then printf HIGH; else printf LOW; fi)" '{
    bootstrap_contract: "v1", repo: $repo, base: "main", delivery: "pr", max_lanes: 4,
    audit: {mode: "auto", mode_source: "default", eligible: $eligible, reason: "fixture"},
    prds: [{path: $prd, class: $class}], gates: $gates,
    groups: [{id: "group-1", mode: "parallel", lanes: [
      {id: "lane-a", prd: $prd, cwd: $wt, command: $command}]}]
  }' > "$5"
}

run_id_of() {
  printf '%s\n' "$1" | sed -n 's/^RUN-[A-Z]* run=\([^ ]*\).*/\1/p'
}

settle() {
  # $1 run dir, $2 seconds. Wait until the supervisor has left `running`; the
  # forbidden poll is a model turn per interval, not a fixture's sleep.
  settle_waited=0
  while [ "$settle_waited" -lt "$2" ]; do
    case "$(jq -r '.status' "$1/state.json")" in
      pending|running) ;;
      *) return 0 ;;
    esac
    sleep 1
    settle_waited=$((settle_waited + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# An audit-eligible run whose lane succeeded is not complete. Nothing has
# audited it yet, and `complete` is the word a manager reads as delivered.
new_repo audit-required
bootstrap_json "$repo" yes '["/bin/true"]' '[]' "$tmp_dir/audit-required.json"
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/audit-required.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
settle "$run_dir" 30 || fail 'the audit-eligible run never left running'
status=$(jq -r '.status' "$run_dir/state.json")
[ "$status" != complete ] ||
  fail 'an audit-eligible run with no audit receipt reached complete'
[ "$status" = awaiting_audit ] ||
  fail "an audit-eligible run should await its audit, not sit at '$status'"
printf '%s\n' 'OBSERVED-RED audit-eligible run refuses to call itself complete'

# The receipt is what completes it, and it names the session that produced it.
receipted=$(sh "$linchpin" audit-receipt "$run" --repo "$repo" \
  --session 01a07620-c2c3-7490-a05d-ea86a200f18e --verdict pass)
assert_contains "$receipted" 'AUDIT-RECEIPT-RECORDED'
[ "$(jq -r '.status' "$run_dir/state.json")" = complete ] ||
  fail 'a passing audit receipt did not complete the run'
[ "$(jq -r '.counters.audit_attempts' "$run_dir/state.json")" = 1 ] ||
  fail 'the audit receipt did not increment audit_attempts'
[ "$(jq -r '.audit.receipt.session' "$run_dir/state.json")" = 01a07620-c2c3-7490-a05d-ea86a200f18e ] ||
  fail 'the audit receipt did not record its session identity'

# One audit per batch. The FOLLOWUP manager launched three; the allowance is
# not a suggestion, and a second one has to be spent on purpose.
if sh "$linchpin" audit-receipt "$run" --repo "$repo" --session second --verdict pass \
     >"$tmp_dir/second-audit" 2>&1; then
  cat "$tmp_dir/second-audit" >&2
  fail 'a second audit receipt was accepted without an explicit extension'
fi
printf '%s\n' 'OBSERVED-RED second audit receipt refused without --extend'
sh "$linchpin" audit-receipt "$run" --repo "$repo" --session second --verdict pass --extend >/dev/null
[ "$(jq -r '.counters.audit_attempts' "$run_dir/state.json")" = 2 ] ||
  fail 'a deliberately extended audit was not counted'

# ---------------------------------------------------------------------------
# A failing gate blocks the run. The gate list was stored and never executed.
new_repo gate-red
bootstrap_json "$repo" no '["/bin/true"]' \
  '[{"id":"unit","command":["/bin/false"],"required":true}]' "$tmp_dir/gate-red.json"
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/gate-red.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
settle "$run_dir" 30 || fail 'the failing-gate run never left running'
[ "$(jq -r '.status' "$run_dir/state.json")" = blocked ] ||
  fail 'a required gate that exited nonzero still allowed the run to complete'
[ "$(jq -r '.gate_results[] | select(.id == "unit") | .exit' "$run_dir/state.json")" != 0 ] ||
  fail 'the failing gate was not recorded with its exit code'
assert_contains "$(sh "$linchpin" events "$run" --repo "$repo" --after 0)" '"type":"gate_failed"'
printf '%s\n' 'OBSERVED-RED required gate failure blocks the run'

# A green gate is recorded too, so a reader can tell "ran and passed" from
# "never ran".
new_repo gate-green
bootstrap_json "$repo" no '["/bin/true"]' \
  '[{"id":"unit","command":["/bin/true"],"required":true}]' "$tmp_dir/gate-green.json"
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/gate-green.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
settle "$run_dir" 30 || fail 'the green-gate run never left running'
[ "$(jq -r '.status' "$run_dir/state.json")" = complete ] ||
  fail 'a run whose gates all passed did not complete'
[ "$(jq -r '.gate_results[] | select(.id == "unit") | .exit' "$run_dir/state.json")" = 0 ] ||
  fail 'a passing gate left no recorded result'

# ---------------------------------------------------------------------------
# A lane that exited nonzero is unfinished, not done. `PARTIAL` plus `complete`
# is the pair that let a failed FOLLOWUP run report success.
new_repo worker-red
bootstrap_json "$repo" no '["/bin/false"]' '[]' "$tmp_dir/worker-red.json"
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/worker-red.json")
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
settle "$run_dir" 30 || fail 'the failed-worker run never left running'
[ "$(jq -r '.status' "$run_dir/state.json")" = blocked ] ||
  fail 'a run with a PARTIAL lane reached complete'
printf '%s\n' 'OBSERVED-RED a nonzero lane exit keeps the run out of complete'

# ---------------------------------------------------------------------------
# `run --audit on` changes the decision, so it must change the decision's
# result. The shipped override rewrote `mode` and left `eligible: no` and
# `reason: audit disabled` in place beside it.
new_repo override
bootstrap_json "$repo" no '["/bin/true"]' '[]' "$tmp_dir/override.json"
jq '.audit = {mode: "off", mode_source: "default", eligible: "no", reason: "audit disabled"}' \
  "$tmp_dir/override.json" > "$tmp_dir/override-off.json"
started=$(sh "$linchpin" run --bootstrap "$tmp_dir/override-off.json" --audit on)
run=$(run_id_of "$started")
run_dir="$repo/.linchpin/runs/$run"
[ "$(jq -r '.audit.eligible' "$run_dir/state.json")" = yes ] ||
  fail 'run --audit on left a stale eligibility beside the new mode'
case "$(jq -r '.audit.reason' "$run_dir/state.json")" in
  *disabled*) fail 'run --audit on kept the reason of the mode it replaced' ;;
esac
settle "$run_dir" 30 || fail 'the overridden run never left running'
[ "$(jq -r '.status' "$run_dir/state.json")" = awaiting_audit ] ||
  fail 'run --audit on did not actually require the audit it turned on'
printf '%s\n' 'OBSERVED-RED --audit on recomputes eligibility rather than only the mode'

pass 'run completion requires its gates, its lane exits, and its audit receipt'
