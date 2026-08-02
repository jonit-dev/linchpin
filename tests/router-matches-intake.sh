#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

intake_ids=$(grep -oE 'ROUTE-[A-Z-]+' "$repo_root/references/intake.md" | sort -u)
router_ids=$(grep -oE 'ROUTE-[A-Z-]+' "$repo_root/skills/linchpin/SKILL.md" | sort -u)
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
