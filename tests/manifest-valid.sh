#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

manifest="$repo_root/.codex-plugin/plugin.json"
command -v jq >/dev/null 2>&1 || fail 'jq is required for manifest validation'
jq empty "$manifest" >/dev/null
jq -e '(keys | sort) == ["description", "interface", "name", "skills", "version"] and .skills == "./skills/"' "$manifest" >/dev/null
broken="$tmp_dir/plugin-broken.json"
jq '.options = {"unexpected": true}' "$manifest" > "$broken"
expect_failure 'invented manifest options key' sh -c 'jq -e '\''(keys | sort) == ["description", "interface", "name", "skills", "version"]'\'' "$1"' sh "$broken"
pass 'Codex manifest is valid and uses only the verified schema'
