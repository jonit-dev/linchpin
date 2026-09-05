#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

intake_ids=$(grep -oE 'ROUTE-[A-Z-]+' "$repo_root/references/intake.md" | sort -u)
router_ids=$(grep -oE 'ROUTE-[A-Z-]+' "$repo_root/skills/linchpin/SKILL.md" | sort -u)
# Parity of two empty sets is also parity. Name the routes that must exist, so a
# route dropped from both files fails here instead of passing quietly.
for required_route in ROUTE-WRITE-PRD ROUTE-BUILD-SMALL ROUTE-BUILD-LARGE \
                      ROUTE-EXECUTE-CONFORMING ROUTE-EXECUTE-UPGRADE \
                      ROUTE-EXECUTE-NONE ROUTE-ASSIGN-MODELS ROUTE-AMBIGUOUS; do
  assert_contains "$intake_ids" "$required_route"
  assert_contains "$router_ids" "$required_route"
done
printf '%s\n' "$intake_ids" > "$tmp_dir/intake-ids"
printf '%s\n' "$router_ids" > "$tmp_dir/router-ids"
cmp -s "$tmp_dir/intake-ids" "$tmp_dir/router-ids" || fail 'router route ids drift from intake'
broken="$tmp_dir/intake-extra.md"
cp "$repo_root/references/intake.md" "$broken"
printf '%s\n' '| `ROUTE-ONLY-IN-INTAKE` | new branch | none | fail |' >> "$broken"
broken_ids=$(grep -oE 'ROUTE-[A-Z-]+' "$broken" | sort -u)
if [ "$broken_ids" = "$router_ids" ]; then
  fail 'router parity negative control did not detect an added intake row'
fi
printf '%s\n' 'OBSERVED-RED intake-only route was rejected by parity comparison'
pass 'router branches and intake routes have matching ids'
