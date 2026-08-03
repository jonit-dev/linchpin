#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

marketplace="$repo_root/.agents/plugins/marketplace.json"
[ -f "$marketplace" ] || fail 'missing GitHub marketplace manifest'
command -v jq >/dev/null 2>&1 || fail 'jq is required for marketplace validation'
jq empty "$marketplace" >/dev/null
jq -e '
  (keys | sort) == ["interface", "name", "plugins"] and
  .name == "linchpin" and
  (.plugins | length) == 1 and
  .plugins[0].name == "linchpin" and
  .plugins[0].source.source == "url" and
  .plugins[0].source.url == "https://github.com/jonit-dev/linchpin.git" and
  .plugins[0].source.ref == "main" and
  .plugins[0].policy.installation == "AVAILABLE" and
  .plugins[0].policy.authentication == "ON_INSTALL" and
  .plugins[0].category == "Productivity"
' "$marketplace" >/dev/null
pass 'GitHub marketplace manifest points at the shipped plugin'
