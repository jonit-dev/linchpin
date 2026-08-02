#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

fixture="$fixture_dir/conforming-prd.md"
good="$fixture_dir/gate-observed-red.md"
sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$good" >/dev/null
expect_failure 'all-green report with no observed-red evidence' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$fixture_dir/gate-all-green.md"
wrong_id="$tmp_dir/wrong-id.md"
sed 's/| contract |/| wrong-gate |/' "$good" > "$wrong_id"
expect_failure 'report with a wrong gate id' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$wrong_id"
duplicate_id="$tmp_dir/duplicate-id.md"
awk '{ print } /\| brief \|/ { print "| contract | PASS | RED observed: duplicate row | `command: sh tests/contract-conformance.sh`; result: RED observed: duplicate row; exit: 1 |" }' "$good" > "$duplicate_id"
expect_failure 'report with a duplicate gate id' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$duplicate_id"
extra_id="$tmp_dir/extra-id.md"
awk '{ print } END { print "| extra-gate | PASS | RED observed: extra row | `command: sh tests/contract-conformance.sh`; result: RED observed: extra row; exit: 1 |" }' "$good" > "$extra_id"
expect_failure 'report with an extra gate id' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$extra_id"
wrong_command="$tmp_dir/wrong-command.md"
sed 's#command: sh tests/contract-conformance.sh#command: sh tests/files-list-parseable.sh#' "$good" > "$wrong_command"
expect_failure 'report with the wrong documented command' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$wrong_command"
green_exit="$tmp_dir/green-exit.md"
sed 's/exit: 1/exit: 0/g' "$good" > "$green_exit"
expect_failure 'report with a zero exit result' sh "$repo_root/scripts/linchpin.sh" gate "$fixture" "$green_exit"
pass 'every inherited gate requires observed-red evidence before PASS'
