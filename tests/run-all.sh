#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tests='import-fidelity.sh
contract-conformance.sh
brief-contains-ledger.sh
files-list-parseable.sh
single-is-swarm-of-one.sh
mode-selection.sh
worktree-fallback.sh
intent-routing.sh
config-optional.sh
gate-evidence.sh
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
router-matches-intake.sh
router-not-a-gate.sh
no-duplicate-skills.sh
post-swap-invoke.sh'

for test_name in $tests; do
  printf 'RUN %s\n' "$test_name"
  sh "$test_dir/$test_name"
done

printf '%s\n' 'ALL-TESTS-PASS positive paths and observed-red controls'
