#!/usr/bin/env bash
# Mechanical pre-commit gate for Ingary.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

fail() { echo -e "${RED}✗ pre-commit:${NC} $*" >&2; exit 1; }
note() { echo -e "${YELLOW}…${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }

staged_files="$(git diff --cached --name-only --diff-filter=ACM)"

if echo "$staged_files" | grep -qE '^backends/rust-ingary/|Cargo\.(toml|lock)$'; then
  note "rust fmt/test..."
  (cd backends/rust-ingary && cargo fmt --check && cargo test) || fail "Rust checks failed"
  ok "Rust checks clean"
fi

if echo "$staged_files" | grep -qE '^backends/go-ingary/'; then
  note "go test..."
  (cd backends/go-ingary && go test ./...) || fail "Go checks failed"
  ok "Go checks clean"
fi

if echo "$staged_files" | grep -qE '^backends/elixir-ingary/'; then
  note "elixir format/test..."
  (cd backends/elixir-ingary && mix format --check-formatted && mix test) || fail "Elixir checks failed"
  ok "Elixir checks clean"
fi

if echo "$staged_files" | grep -qE '^frontend/web/'; then
  note "frontend build..."
  (cd frontend/web && npm run build) || fail "Frontend build failed"
  ok "Frontend build clean"
fi

if echo "$staged_files" | grep -qE '^tests/|^contracts/'; then
  note "python contract files..."
  python3 -m py_compile tests/*.py || fail "Python contract files failed to compile"
  ok "Python contract files compile"
fi

note "gitleaks (staged only)..."
GITLEAKS=""
if command -v gitleaks >/dev/null 2>&1; then
  GITLEAKS="$(command -v gitleaks)"
elif [[ -x /opt/homebrew/bin/gitleaks ]]; then
  GITLEAKS=/opt/homebrew/bin/gitleaks
elif [[ -x /usr/local/bin/gitleaks ]]; then
  GITLEAKS=/usr/local/bin/gitleaks
elif command -v go >/dev/null 2>&1 && [[ -x "$(go env GOPATH)/bin/gitleaks" ]]; then
  GITLEAKS="$(go env GOPATH)/bin/gitleaks"
fi

if [[ -z "$GITLEAKS" ]]; then
  if [[ "${PRE_COMMIT_SKIP_GITLEAKS:-}" == "1" ]]; then
    note "gitleaks missing and PRE_COMMIT_SKIP_GITLEAKS=1 — skipping by override"
  else
    fail "gitleaks not installed. Install it or set PRE_COMMIT_SKIP_GITLEAKS=1 for this commit and document why."
  fi
else
  "$GITLEAKS" protect --staged --config .gitleaks.toml >/dev/null 2>&1 || {
    "$GITLEAKS" protect --staged --config .gitleaks.toml 2>&1 | tail -20
    fail "gitleaks found a secret-shaped pattern in staged changes"
  }
  ok "gitleaks clean"
fi

ok "pre-commit gate passed"
