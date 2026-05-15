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

echo "── App ──────────────────────────────────────────────"
(cd app && mise exec -- mix format --check-formatted && mise exec -- mix test) && pass "app format/test" || fail "app format/test"

echo "── Python contracts ─────────────────────────────────"
python3 -m py_compile tests/*.py && pass "python compile" || fail "python compile"

if [ "$QUICK" = false ]; then
  python3 tests/storage_contract.py --store all --cases 50 && pass "storage contract" || fail "storage contract"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  pass "All checks passed"
  exit 0
fi

printf '✗ %s check(s) failed\n' "$FAILURES" >&2
exit 1
