#!/bin/sh
# A provider stand-in for runner tests. It records every actual invocation, so a
# duplicate launch is countable rather than inferred, and emits fixed output.
set -eu
[ -z "${LINCHPIN_FAKE_PROVIDER_LOG:-}" ] || printf '%s\n' "$*" >> "$LINCHPIN_FAKE_PROVIDER_LOG"
sleep "${LINCHPIN_FAKE_PROVIDER_SLEEP:-0}"
printf 'FAKE-PROVIDER lane=%s cwd=%s\n' "${1:-none}" "$PWD"
exit "${LINCHPIN_FAKE_PROVIDER_EXIT:-0}"
