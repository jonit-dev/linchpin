#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# The auditor is the expensive role, so the failure that matters is not "the
# audit was wrong" — it is paying for an audit nobody asked for, or being
# stopped by an auditor model a run was never going to launch. These are the
# controls for the role's resolution and for its cost boundary.

linchpin="$repo_root/scripts/linchpin.sh"
cache="$fixture_dir/models-cache-multi-provider.json"
fake_claude="$fixture_dir/fake-claude.sh"
complexity="$fixture_dir/complexity"
config_dir="$tmp_dir/auditor-repo"
mkdir -p "$config_dir"

# The shipped auditor comes off the Role pins table, through the same alias
# registry as every other role. No second source of slugs.
runtime="$repo_root/references/runtime.md"
auditor_row=$(awk -F '|' '$2 ~ /Auditor/ { print; exit }' "$runtime")
[ -n "$auditor_row" ] || fail 'references/runtime.md Role pins has no Auditor row'
for auditor_cell in 'codex' 'gpt-6-astra' 'medium' 'codex exec --sandbox read-only'; do
  assert_contains "$auditor_row" "$auditor_cell"
done
# The mechanism is read-only for the same reason the reviewer's is: an auditor
# that can edit what it judges makes its own findings unreviewable.
assert_contains "$(awk -F '|' '$2 ~ /Auditor mechanism/ { print; exit }' "$runtime")" '--sandbox read-only'

# Zero config resolves the auditor without being asked to, so a brief or a
# preflight can name it. The default worker and reviewer are untouched by its
# arrival.
zero=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$cache")
assert_contains "$zero" 'worker[provider=codex model=gpt-5.6-luna'
assert_contains "$zero" 'reviewer[provider=codex model=gpt-5.6-sol'
# An ineligible run does not check the auditor at all. This is the cost boundary.
assert_contains "$zero" 'auditor[not-eligible'
assert_contains "$zero" 'no capability check, probe, or launch for this run'

# An eligible run checks it, and says which model it checked.
eligible=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$cache" --audit-eligible yes)
assert_contains "$eligible" 'auditor[provider=codex model=gpt-6-astra effort=medium mechanism=codex exec --sandbox read-only'
assert_contains "$eligible" "verified=cache=$cache"

# The frozen decision drives it, not a second reading of the PRD: preflight and
# the runner must not be able to disagree about the same batch.
frozen_off="$tmp_dir/bootstrap-off.json"
sh "$linchpin" audit "$complexity/high-score.md" --mode off --config-dir "$config_dir" --out "$frozen_off" >/dev/null
from_off=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$cache" --bootstrap "$frozen_off")
assert_contains "$from_off" 'auditor[not-eligible'
frozen_on="$tmp_dir/bootstrap-on.json"
sh "$linchpin" audit "$complexity/high-score.md" --config-dir "$config_dir" --out "$frozen_on" >/dev/null
from_on=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$cache" --bootstrap "$frozen_on")
assert_contains "$from_on" 'auditor[provider=codex model=gpt-6-astra'
expect_failure 'preflight against bootstrap state with no resolved eligibility' \
  env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$cache" --bootstrap "$fixture_dir/models-cache-with-luna.json"

# THE CONTROL THAT PAYS FOR ITSELF: a cache without the auditor's model. An
# eligible run must refuse by name; an ineligible one must not notice.
missing="$fixture_dir/models-cache-with-luna.json"
ineligible_ok=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$missing")
assert_contains "$ineligible_ok" 'PREFLIGHT-PASS'
assert_contains "$ineligible_ok" 'auditor[not-eligible'
expect_failure 'an eligible run whose auditor model is not in the cache' \
  env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$missing" --audit-eligible yes
refusal=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$linchpin" preflight "$missing" --audit-eligible yes 2>&1 || true)
assert_contains "$refusal" 'gpt-6-astra'

# A claude auditor resolves through the alias, like any other role, and is
# probed the only way a claude role can be.
printf '%s\n' 'auditor = "opus-5"' 'auditor_effort = "xhigh"' > "$config_dir/.linchpin.toml"
claude_auditor=$(env LINCHPIN_CONFIG_DIR="$config_dir" LINCHPIN_CLAUDE_BIN="$fake_claude" \
  sh "$linchpin" preflight "$cache" --audit-eligible yes)
assert_contains "$claude_auditor" 'auditor[provider=claude model=claude-opus-5'
assert_contains "$claude_auditor" 'verified=probed'
# `xhigh` is in the claude domain and not in the codex one, so the effort is
# validated against the provider the alias resolved to, not a shared list.
assert_contains "$(sh "$linchpin" config "$config_dir")" 'auditor=opus-5'
printf '%s\n' 'auditor_effort = "xhigh"' > "$config_dir/.linchpin.toml"
expect_failure 'xhigh effort on the shipped codex auditor' \
  sh "$linchpin" config "$config_dir"
printf '%s\n' 'auditor = "not-a-model"' > "$config_dir/.linchpin.toml"
expect_failure 'an auditor alias with no row in the registry' \
  sh "$linchpin" config "$config_dir"
rm -f "$config_dir/.linchpin.toml"

# Selecting the auditor is not the same decision as turning it on. A run that
# names a model and never enables the audit stays ineligible.
printf '%s\n' 'auditor = "sol"' > "$config_dir/.linchpin.toml"
still_off=$(sh "$linchpin" audit "$complexity/medium-score.md" --config-dir "$config_dir")
assert_contains "$still_off" 'AUDIT-ELIGIBLE eligible=no'
rm -f "$config_dir/.linchpin.toml"

# THE SENTENCE PATH. "leave auditor off" is one sentence to a user and a
# run-local mode decision underneath. It costs no probe and no config byte.
: > "$config_dir/.linchpin.toml"
printf '%s\n' 'execution = "sequential"' > "$config_dir/.linchpin.toml"
before=$(cat "$config_dir/.linchpin.toml")
off_sentence=$(sh "$linchpin" assign 'execute PRD-007 with @linchpin but leave auditor off' \
  --config-dir "$config_dir" --write)
assert_contains "$off_sentence" 'ASSIGN-AUDIT mode=off scope=run-local'
assert_contains "$off_sentence" '.linchpin.toml is not touched'
[ "$before" = "$(cat "$config_dir/.linchpin.toml")" ] ||
  fail 'a run-local audit sentence rewrote the repository configuration'
# The PRD named in the same sentence is not a model term. Hunting for one there
# is how a request that turned the audit off ends in ASSIGN-UNRESOLVED.
case "$off_sentence" in
  *ASSIGN-UNRESOLVED*) fail 'the audit sentence tried to resolve the PRD name as a model' ;;
esac
on_sentence=$(sh "$linchpin" assign 'execute docs/PRDs/007.md with @linchpin and use an auditor' \
  --config-dir "$config_dir" --write)
assert_contains "$on_sentence" 'ASSIGN-AUDIT mode=on scope=run-local'
auto_sentence=$(sh "$linchpin" assign 'execute XYZ with @linchpin using auditor auto' --config-dir "$config_dir")
assert_contains "$auto_sentence" 'ASSIGN-AUDIT mode=auto scope=run-local'
[ "$before" = "$(cat "$config_dir/.linchpin.toml")" ] ||
  fail 'an audit sentence rewrote the repository configuration'

# A run-local auditor model is run-local too. Persistence has to be asked for.
run_local=$(sh "$linchpin" assign 'use Sol high as auditor for this run' --config-dir "$config_dir" --write)
assert_contains "$run_local" 'ASSIGN role=auditor alias=sol effort=high provider=codex model=gpt-5.6-sol scope=run-local'
[ "$before" = "$(cat "$config_dir/.linchpin.toml")" ] ||
  fail 'a run-local auditor assignment was persisted'
persistent=$(sh "$linchpin" assign 'always use astra medium as the auditor' --config-dir "$config_dir" --write)
assert_contains "$persistent" 'scope=persistent'
assert_contains "$(cat "$config_dir/.linchpin.toml")" 'auditor = "astra"'
assert_contains "$(cat "$config_dir/.linchpin.toml")" 'execution = "sequential"'
rm -f "$config_dir/.linchpin.toml"

# "use an auditor but leave the auditor off" has no defensible reading. One
# clarification, before anything paid is launched.
expect_failure 'a sentence asking for an auditor and for no auditor' \
  sh "$linchpin" assign 'use an auditor but leave the auditor off' --config-dir "$config_dir"

# The router announces the run-local mode beside the execution route, so a
# manager does not have to notice it by reading.
routed=$(sh "$linchpin" route 'execute the batch with @linchpin but leave auditor off' \
  "$complexity/high-score.md" --config-dir "$config_dir")
assert_contains "$routed" 'ROUTE-AUDIT-RUN-LOCAL -> audit --mode off'
assert_contains "$routed" 'ROUTE-EXECUTE-CONFORMING'

# Worker and reviewer defaults are exactly what they were before the auditor
# existed. A new role must not move an existing pin.
assert_contains "$(awk -F '|' '$2 ~ /Worker/ { print; exit }' "$runtime")" 'gpt-5.6-luna'
assert_contains "$(awk -F '|' '$2 ~ /Worker/ { print; exit }' "$runtime")" '--sandbox danger-full-access'

# NEGATIVE CONTROL. Force the auditor preflight despite an ineligible run in an
# isolated copy: the zero-probe assertion above has to fail.
forced="$tmp_dir/forced-auditor"
copy_repo "$forced"
sed -i.bak "s/  preflight_audit_eligible=no/  preflight_audit_eligible=yes/" "$forced/scripts/linchpin.sh"
rm -f "$forced/scripts/linchpin.sh.bak"
grep -Fq 'preflight_audit_eligible=yes' "$forced/scripts/linchpin.sh" ||
  fail 'the forced-preflight control did not patch the eligibility default'
forced_out=$(env LINCHPIN_CONFIG_DIR="$config_dir" sh "$forced/scripts/linchpin.sh" preflight "$cache")
if printf '%s\n' "$forced_out" | grep -Fq 'auditor[not-eligible'; then
  fail 'the forced-preflight control still skipped the auditor; the control proves nothing'
fi
printf 'OBSERVED-RED %s\n' 'an ineligible run whose auditor is preflighted anyway reports a checked auditor'
# And with the model absent from the cache, the forced copy fails a run that
# should have passed. That is the cost of probing a role nobody asked for.
expect_failure 'a forced auditor preflight on a cache without its model' \
  env LINCHPIN_CONFIG_DIR="$config_dir" sh "$forced/scripts/linchpin.sh" preflight "$missing"

# The second control: strip the Auditor row and the role stops resolving at all,
# while `off` runs stay usable only because they never ask for it.
stripped="$tmp_dir/no-auditor-row"
copy_repo "$stripped"
sed -i.bak '/^| Auditor | /d' "$stripped/references/runtime.md"
rm -f "$stripped/references/runtime.md.bak"
expect_failure 'an eligible run with no Auditor row in runtime.md' \
  env LINCHPIN_CONFIG_DIR="$config_dir" sh "$stripped/scripts/linchpin.sh" preflight "$cache" --audit-eligible yes

pass 'the auditor resolves through the shared registry, is probed only when eligible, and its run-local selection never touches repository config'
