#!/usr/bin/env bash
set -euo pipefail

shopt -s nullglob

# Collect C/C headers via git if available, otherwise fallback to find
files=()
if git ls-files -z '*.c' '*.h' >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z '*.c' '*.h')
else
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find include src test -type f \( -name '*.c' -o -name '*.h' \) -print0)
fi

if ! command -v clang-format >/dev/null 2>&1; then
  echo "clang-format not found; skipping format" >&2
  exit 0
fi

if [ ${#files[@]} -gt 0 ]; then
  echo "Formatting ${#files[@]} files with clang-format..."
  clang-format -i "${files[@]}"
fi
