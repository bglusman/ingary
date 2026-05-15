#!/usr/bin/env bash
# Full local pre-push checks for Wardwright.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

FAILURES=0
QUICK=false

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=true ;;
  esac
done

pass() { printf '✓ %s\n' "$1"; }
fail() { printf '✗ %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

echo "── Baseline ─────────────────────────────────────────"
mise run check && pass "mise check" || fail "mise check"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  pass "All checks passed"
  exit 0
fi

printf '✗ %s check(s) failed\n' "$FAILURES" >&2
exit 1
