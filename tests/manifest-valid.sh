#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

manifest="$repo_root/.codex-plugin/plugin.json"
command -v jq >/dev/null 2>&1 || fail 'jq is required for manifest validation'
jq empty "$manifest" >/dev/null
jq -e '
  (keys | sort) == ["author", "description", "interface", "keywords", "license", "name", "repository", "skills", "version"] and
  .name == "linchpin" and
  .skills == "./skills/" and
  (.author.name | type == "string" and length > 0) and
  .repository == "https://github.com/jonit-dev/linchpin" and
  .license == "MIT" and
  (.interface.displayName | type == "string" and length > 0) and
  (.interface.capabilities | type == "array" and length > 0) and
  (.interface.defaultPrompt | type == "array" and length > 0)
' "$manifest" >/dev/null
# A manifest that points at a listing asset which is not in the repository is
# the document-contradicts-code defect this plugin exists to catch, and the
# directory submission is exactly where it would surface. `interface.logo` is
# the field the submission portal actually rejects on, and it rejects a
# non-square image, so both are checked here rather than at upload time.
for icon_field in composerIcon logo; do
  icon=$(jq -r --arg field "$icon_field" '.interface[$field] // empty' "$manifest")
  [ -n "$icon" ] || fail "manifest declares no interface.$icon_field for the directory listing"
  [ -f "$repo_root/${icon#./}" ] || fail "manifest interface.$icon_field is not on disk: $icon"
done

# PNG width and height are four big-endian bytes each at offsets 16 and 20. Read
# them with od so the check needs no image library on any runner.
logo_path="$repo_root/$(jq -r '.interface.logo' "$manifest" | sed 's|^\./||')"
logo_dims=$(od -An -tu1 -j16 -N8 "$logo_path" | tr -s ' ' | sed 's/^ //')
logo_w=$(printf '%s\n' "$logo_dims" | cut -d' ' -f1-4 | awk '{ print $1*16777216 + $2*65536 + $3*256 + $4 }')
logo_h=$(printf '%s\n' "$logo_dims" | cut -d' ' -f5-8 | awk '{ print $1*16777216 + $2*65536 + $3*256 + $4 }')
[ "$logo_w" -gt 0 ] || fail "could not read logo dimensions: $logo_path"
[ "$logo_w" -eq "$logo_h" ] || fail "submission portal requires a square logo; got ${logo_w}x${logo_h}"
missing_icon="$tmp_dir/plugin-missing-icon.json"
jq '.interface.composerIcon = "./assets/does-not-exist.png"' "$manifest" > "$missing_icon"
expect_failure 'manifest pointing at an icon that is not in the repository' \
  sh -c 'icon=$(jq -r ".interface.composerIcon" "$1"); [ -f "$2/${icon#./}" ]' sh "$missing_icon" "$repo_root"

broken="$tmp_dir/plugin-broken.json"
jq '.options = {"unexpected": true}' "$manifest" > "$broken"
expect_failure 'invented manifest options key' sh -c 'jq -e '\''(keys | sort) == ["author", "description", "interface", "keywords", "license", "name", "repository", "skills", "version"]'\'' "$1"' sh "$broken"
pass 'Codex manifest is publish-ready and uses the accepted schema'
