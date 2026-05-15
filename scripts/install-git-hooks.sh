#!/usr/bin/env bash
# Idempotent installer for Wardwright git hooks.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

install_hook() {
  local name="$1"
  local source="$2"
  local target=".git/hooks/$name"
  local rel_source="../../$source"

  if [[ ! -f "$source" ]]; then
    echo "missing hook source: $source" >&2
    return 1
  fi

  if [[ -e "$target" && ! -L "$target" ]]; then
    local backup="$target.backup-$(date +%Y%m%dT%H%M%S)"
    mv "$target" "$backup"
    echo "backed up existing $name -> $backup"
  fi

  if [[ -L "$target" ]]; then
    rm "$target"
  fi

  ln -s "$rel_source" "$target"
  chmod +x "$source"
  echo "installed $name"
}

install_hook pre-commit scripts/pre-commit-hook.sh
install_hook pre-push scripts/pre-push.sh
