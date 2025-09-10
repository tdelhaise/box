#!/usr/bin/env bash
set -euo pipefail

shopt -s nullglob

files=(
  $(git ls-files '*.c' '*.h' | tr '\n' ' ')
)

if ! command -v clang-format >/dev/null 2>&1; then
  echo "clang-format not found; skipping format" >&2
  exit 0
fi

echo "Formatting ${#files[@]} files with clang-format..."
clang-format -i "${files[@]}"

