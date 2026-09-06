#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Findings 3 and 5 of docs/codex-session-audit-2026-09-06.md. One FOLLOWUP
# manager launched three Astra auditors through native `multi_agent_v1__spawn_agent`
# calls with `fork_context: true`. Their prompts said read-only; their first
# turn contexts said `danger-full-access`. A read-only instruction in a prompt
# is not a read-only process.
#
# The same session shows the other half: worker session 01a072dc drifted from
# Luna/max to Astra/medium and back inside one worker identity, because the
# documented continuation shape carries a sandbox and no model.
#
# The fix under test: nobody assembles a role command by hand. One builder
# emits the argv, and the sandbox and the model are properties of the role.

command -v jq >/dev/null 2>&1 || { printf 'SKIP role command builder needs jq\n'; exit 0; }

linchpin="$repo_root/scripts/linchpin.sh"
work="$tmp_dir/role-command"
mkdir -p "$work/lane-a"
printf 'audit this\n' > "$work/audit.txt"
printf 'review this\n' > "$work/review.txt"
printf 'build this\n' > "$work/brief.txt"

argv_of() {
  printf '%s\n' "$1" | sed -n 's/^ARGV //p'
}

# ---------------------------------------------------------------------------
# The auditor. Read-only is emitted, not requested.
auditor=$(sh "$linchpin" role-command auditor --cwd "$work" --prompt "$work/audit.txt" --config-dir "$work")
assert_contains "$auditor" 'ROLE-COMMAND role=auditor'
assert_contains "$auditor" 'sandbox=read-only'
argv=$(argv_of "$auditor")
[ -n "$argv" ] || fail 'the auditor role command emitted no argv line'
printf '%s' "$argv" | jq -e 'type == "array" and length > 0' >/dev/null ||
  fail 'the auditor argv is not a JSON array'
printf '%s' "$argv" | jq -e 'index("--sandbox") as $i | $i != null and .[$i + 1] == "read-only"' >/dev/null ||
  fail 'the auditor argv does not carry --sandbox read-only'
case "$auditor" in
  *danger-full-access*) fail 'the auditor role command mentions full access' ;;
  *spawn_agent*|*fork_context*|*agent_type*) fail 'the auditor role command names a native spawn mechanism' ;;
esac
printf '%s\n' 'OBSERVED-RED the auditor command is built read-only rather than asked to be'

# The reviewer is the same rule.
reviewer=$(sh "$linchpin" role-command reviewer --cwd "$work/lane-a" --prompt "$work/review.txt" --config-dir "$work")
assert_contains "$reviewer" 'sandbox=read-only'
printf '%s' "$(argv_of "$reviewer")" |
  jq -e 'index("--sandbox") as $i | $i != null and .[$i + 1] == "read-only"' >/dev/null ||
  fail 'the reviewer argv does not carry --sandbox read-only'

# The worker is the one role that gets write access, and it says so.
worker=$(sh "$linchpin" role-command worker --cwd "$work/lane-a" --prompt "$work/brief.txt" --config-dir "$work")
assert_contains "$worker" 'sandbox=danger-full-access'

# ---------------------------------------------------------------------------
# Continuation carries the model and the effort explicitly. `exec resume` with
# only a sandbox is how one worker identity ran three different runtimes.
resumed=$(sh "$linchpin" role-command worker --resume 01a072dc-fc3f-7443-91be-8bdf59b7d42a \
  --cwd "$work/lane-a" --prompt "$work/brief.txt" --config-dir "$work")
resumed_argv=$(argv_of "$resumed")
assert_contains "$resumed" '01a072dc-fc3f-7443-91be-8bdf59b7d42a'
printf '%s' "$resumed_argv" | jq -e 'any(.[]; startswith("model="))' >/dev/null ||
  fail 'the resumed worker argv pins no model, so the lane can drift mid-run'
printf '%s' "$resumed_argv" | jq -e 'any(.[]; startswith("model_reasoning_effort="))' >/dev/null ||
  fail 'the resumed worker argv pins no effort'
printf '%s' "$resumed_argv" | jq -e 'any(.[]; startswith("sandbox_mode="))' >/dev/null ||
  fail 'the resumed worker argv drops its sandbox'
printf '%s\n' 'OBSERVED-RED a resumed worker carries its model and effort, not just a sandbox'

# A role the builder does not know is a refusal, not a default.
if sh "$linchpin" role-command manager --cwd "$work" --prompt "$work/audit.txt" \
     >"$tmp_dir/manager-command" 2>&1; then
  cat "$tmp_dir/manager-command" >&2
  fail 'the builder invented a command for the manager, which is the current session'
fi
printf '%s\n' 'OBSERVED-RED the builder refuses a role it has no launch shape for'

# ---------------------------------------------------------------------------
# The verifier now recognises the mechanism the FOLLOWUP manager actually used.
# `agent_type` and `fork_turns` alone did not name `spawn_agent`.
env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$repo_root/scripts/verify.sh" >/dev/null
copy="$tmp_dir/native-spawn"
copy_repo "$copy"
printf '%s\n' 'launch the auditor with multi_agent_v1__spawn_agent and fork_context: true' \
  >> "$copy/skills/prd-swarm-coordinator/SKILL.md"
if env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$copy/scripts/verify.sh" \
     >"$tmp_dir/spawn-verify" 2>&1; then
  cat "$tmp_dir/spawn-verify" >&2
  fail 'a skill telling the manager to spawn a native auditor was accepted'
fi
grep -F 'skills/prd-swarm-coordinator/SKILL.md:' "$tmp_dir/spawn-verify" >/dev/null ||
  fail 'the native-spawn failure did not name file:line'
printf '%s\n' 'OBSERVED-RED native spawn_agent guidance fails the verifier'

pass 'role commands carry their own sandbox, model, and effort'
