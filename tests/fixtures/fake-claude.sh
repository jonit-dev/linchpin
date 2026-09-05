#!/bin/sh
# Stub Claude Code CLI. It stands in for `claude` wherever a test needs the
# real binary's argv, its stdin, or its refusal of an unknown model without
# spending a live request.
#
#   LINCHPIN_FAKE_CLAUDE_ARGV   file this stub appends its full argv to
#   LINCHPIN_FAKE_CLAUDE_STDIN  file this stub writes its stdin to
#   LINCHPIN_FAKE_CLAUDE_MODELS space-separated model ids it accepts
#                               (default: the shipped claude alias slugs)
#
# Exit 0 and print `ok` for a known model id; exit 1 naming the id otherwise.
set -eu

if [ -n "${LINCHPIN_FAKE_CLAUDE_ARGV:-}" ]; then
  printf '%s\n' "$*" >> "$LINCHPIN_FAKE_CLAUDE_ARGV"
fi

fake_model=''
fake_effort=''
fake_print=no
fake_cwd=$PWD
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) fake_model="${2:-}"; shift 2 ;;
    --model=*) fake_model="${1#--model=}"; shift ;;
    --effort) fake_effort="${2:-}"; shift 2 ;;
    --effort=*) fake_effort="${1#--effort=}"; shift ;;
    -p|--print) fake_print=yes; shift ;;
    *) shift ;;
  esac
done

if [ -n "${LINCHPIN_FAKE_CLAUDE_STDIN:-}" ]; then
  cat > "$LINCHPIN_FAKE_CLAUDE_STDIN" || : > "$LINCHPIN_FAKE_CLAUDE_STDIN"
fi

known="${LINCHPIN_FAKE_CLAUDE_MODELS:-claude-opus-5 claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5 claude-fable-5-1}"
for candidate in $known; do
  if [ "$candidate" = "$fake_model" ]; then
    printf 'ok model=%s effort=%s print=%s cwd=%s\n' \
      "$fake_model" "$fake_effort" "$fake_print" "$fake_cwd"
    exit 0
  fi
done

printf 'unknown model: %s\n' "$fake_model" >&2
exit 1
