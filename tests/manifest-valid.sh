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
# directory submission is exactly where it would surface.
icon=$(jq -r '.interface.composerIcon // empty' "$manifest")
[ -n "$icon" ] || fail 'manifest declares no composerIcon for the directory listing'
[ -f "$repo_root/${icon#./}" ] || fail "manifest composerIcon is not on disk: $icon"
missing_icon="$tmp_dir/plugin-missing-icon.json"
jq '.interface.composerIcon = "./assets/does-not-exist.png"' "$manifest" > "$missing_icon"
expect_failure 'manifest pointing at an icon that is not in the repository' \
  sh -c 'icon=$(jq -r ".interface.composerIcon" "$1"); [ -f "$2/${icon#./}" ]' sh "$missing_icon" "$repo_root"

broken="$tmp_dir/plugin-broken.json"
jq '.options = {"unexpected": true}' "$manifest" > "$broken"
expect_failure 'invented manifest options key' sh -c 'jq -e '\''(keys | sort) == ["author", "description", "interface", "keywords", "license", "name", "repository", "skills", "version"]'\'' "$1"' sh "$broken"
pass 'Codex manifest is publish-ready and uses the accepted schema'
