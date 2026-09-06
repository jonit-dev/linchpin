#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Finding 5 of docs/codex-session-audit-2026-09-06.md. The role pins table
# specified a Sol/medium manager. Nineteen matched orchestration sessions ran
# Luna/max, because the manager is not a process this plugin launches — it is
# the session already in front of the user. Preflight validated worker,
# reviewer, and an eligible auditor and never the manager, so the contract said
# one thing and every run did another.
#
# A pin nothing enforces and nothing can enforce is not a pin. The table has to
# say what is true, and preflight has to report the manager it actually has.

linchpin="$repo_root/scripts/linchpin.sh"
runtime="$repo_root/references/runtime.md"
cache="$fixture_dir/models-cache-multi-provider.json"

manager_row=$(grep '^| Manager ' "$runtime")
[ -n "$manager_row" ] || fail 'the role pins table has no Manager row'

# No model slug and no effort word may be pinned for a role nothing launches.
case "$manager_row" in
  *gpt-*|*claude-*) fail 'the Manager row still pins a model slug it cannot enforce' ;;
esac
printf '%s\n' 'OBSERVED-RED the Manager row pins no model'
assert_contains "$manager_row" 'current session'

# The worker, reviewer, and auditor rows are unaffected: those are real launches
# and their pins are enforced by preflight.
for role in Worker Reviewer Auditor; do
  row=$(grep "^| $role " "$runtime")
  case "$row" in
    *gpt-*|*claude-*) ;;
    *) fail "the $role row lost the model pin preflight verifies" ;;
  esac
done

# Preflight reports the manager rather than silently omitting it, so a run's
# own record says which session orchestrated it.
work="$tmp_dir/manager"
mkdir -p "$work"
preflight=$(env LINCHPIN_CONFIG_DIR="$work" sh "$linchpin" preflight "$cache")
assert_contains "$preflight" 'PREFLIGHT-PASS'
assert_contains "$preflight" 'manager[current session'
printf '%s\n' 'OBSERVED-RED preflight names the manager as the current session'

env LINCHPIN_MODELS_CACHE="$fixture_dir/models-cache-with-luna.json" sh "$repo_root/scripts/verify.sh" >/dev/null

pass 'the manager is described as the current session, not pinned to a model it never runs'
