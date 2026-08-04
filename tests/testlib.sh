#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_dir="$repo_root/tests/fixtures"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-tests.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

pass() {
  printf 'PASS %s\n' "$*"
}

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  label="$1"
  shift
  if "$@" >"$tmp_dir/expected-red.out" 2>&1; then
    cat "$tmp_dir/expected-red.out" >&2
    fail "$label unexpectedly passed"
  fi
  printf 'OBSERVED-RED %s\n' "$label"
}

copy_repo() {
  target="$1"
  mkdir -p "$target"
  cp -R "$repo_root"/. "$target"/
}

assert_contains() {
  haystack="$1"
  needle="$2"
  # `--` or the needle is read as grep options the moment it starts with a dash,
  # which is exactly what asserting on a command line looks like.
  printf '%s\n' "$haystack" | grep -Fq -- "$needle" || fail "missing expected text: $needle"
}
