#!/usr/bin/env bash
set -euo pipefail

if ! command -v clang-format >/dev/null 2>&1; then
  echo "clang-format not found; skipping format check" >&2
  exit 0
fi

rc=0
while IFS= read -r -d '' f; do
  if clang-format --dry-run -Werror "$f" 2>/dev/null; then
    :
  else
    echo "[FORMAT] $f needs formatting" >&2
    rc=1
  fi
done < <(git ls-files -z '*.c' '*.h')

exit $rc

