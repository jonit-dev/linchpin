#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

jq -e '.skills == "./skills/" and .name == "linchpin"' "$repo_root/.codex-plugin/plugin.json" >/dev/null
for skill in linchpin prd-creator prd-swarm-coordinator; do
  [ -f "$repo_root/skills/$skill/SKILL.md" ] || fail "missing discoverable skill: $skill"
done
[ ! -e "$repo_root/skills/prd-executor/SKILL.md" ] || fail 'retired skill is discoverable'
printf '%s\n' 'STATIC-DISCOVERY-PASS manifest points at ./skills/ and all three shipped skills exist.'
printf '%s\n' 'MANUAL-INSTALL-GATE codex plugin list --json was not run because external installation is owner-confirmed.'
pass 'plugin discovery surface is complete without mutating a live Codex install'
