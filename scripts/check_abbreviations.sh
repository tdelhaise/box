#!/usr/bin/env bash
set -euo pipefail

# Scan for common abbreviated identifiers and emit warnings.
# Usage:
#   scripts/check_abbreviations.sh            # warn-only, exits 0
#   ENFORCE_ABBREV=1 scripts/check_abbreviations.sh  # fail on findings

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

echo "Checking for abbreviated identifiers (warn-only by default)..."

PATTERN='\b(buf|addr|var|len|sock|cfg|env|tmp|ptr|idx|cnt|fn|str|num|sz)\b'
FILES=$(rg -n --no-heading --color never -e "$PATTERN" include src test || true)

if [ -n "$FILES" ]; then
  echo "--- Abbreviation matches ---"
  echo "$FILES" | sed 's/^/  /'
  echo "----------------------------"
  if [ "${ENFORCE_ABBREV:-0}" != "0" ]; then
    echo "Abbreviation check: FAILED (set ENFORCE_ABBREV=0 to warn-only)"
    exit 1
  fi
else
  echo "No abbreviations found."
fi

echo "Abbreviation check: OK (warn-only mode)"

