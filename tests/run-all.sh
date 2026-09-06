#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests='import-fidelity.sh
contract-conformance.sh
execute-as-written.sh
legacy-migration.sh
brief-contains-ledger.sh
brief-requires-commit.sh
brief-prd-reachable-from-lane.sh
no-lane-recursion.sh
review-brief-carries-gates.sh
one-review-per-lane.sh
workspace-ignored.sh
run-ledger.sh
lane-worktree-isolation.sh
prune-after-run.sh
launch-detaches-lane.sh
await-group-not-poll.sh
files-list-parseable.sh
single-is-swarm-of-one.sh
mode-selection.sh
worktree-fallback.sh
intent-routing.sh
config-optional.sh
subcommand-help.sh
runtime-override.sh
provider-registry.sh
provider-preflight.sh
provider-invocation.sh
assign-natural-language.sh
gate-evidence.sh
audit-policy.sh
auditor-runtime.sh
runner-lifecycle.sh
runner-completion-requires-evidence.sh
run-local-auditor-carried.sh
role-command-enforces-sandbox.sh
review-budget-per-batch.sh
manager-is-the-current-session.sh
no-model-escalation.sh
gates-mode-invariant.sh
luna-never-native.sh
no-stray-pins.sh
preflight-model.sh
no-task-delegation.sh
manifest-valid.sh
marketplace-valid.sh
skills-discoverable.sh
helper-context-boundary.sh
portable-prd-evidence.sh
router-matches-intake.sh
router-not-a-gate.sh
no-duplicate-skills.sh
worker-can-commit.sh
post-swap-invoke.sh'

for test_name in $tests; do
  printf 'RUN %s\n' "$test_name"
  sh "$test_dir/$test_name"
done

printf '%s\n' 'ALL-TESTS-PASS positive paths and observed-red controls'
