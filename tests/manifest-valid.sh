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
broken="$tmp_dir/plugin-broken.json"
jq '.options = {"unexpected": true}' "$manifest" > "$broken"
expect_failure 'invented manifest options key' sh -c 'jq -e '\''(keys | sort) == ["author", "description", "interface", "keywords", "license", "name", "repository", "skills", "version"]'\'' "$1"' sh "$broken"
pass 'Codex manifest is publish-ready and uses the accepted schema'
