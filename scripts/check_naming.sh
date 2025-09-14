#!/usr/bin/env bash
set -euo pipefail

fail=0

echo "Checking naming conventions..."

# 1) src/include: only BF*.h headers
bad_headers=$(find src/include -maxdepth 1 -type f -name '*.h' ! -name 'BF*.h' -print || true)
if [ -n "${bad_headers}" ]; then
  echo "[ERROR] Non-BF headers in src/include/:"
  echo "${bad_headers}"
  fail=1
fi

# 2) include/box should not contain .c files
bad_impls=$(find src/include -maxdepth 1 -type f -name '*.c' -print || true)
if [ -n "${bad_impls}" ]; then
  echo "[ERROR] Implementation files (.c) found under src/include:"
  echo "${bad_impls}"
  fail=1
fi

# 3) src/lib: only BF*.c sources
bad_sources=$(find src/lib -maxdepth 1 -type f -name '*.c' ! -name 'BF*.c' -print || true)
if [ -n "${bad_sources}" ]; then
  echo "[ERROR] Non-BF sources in src/lib/:"
  echo "${bad_sources}"
  fail=1
fi

# 4) includes to box/<header> should use BF* headers
headers=$(grep -R -n --include='*.c' --include='*.h' '#include \"box/' src test | sed -E 's/.*#include "box\/([^\"]+)".*/\1/' || true)
bad_includes=$(printf "%s\n" ${headers:-} | grep -v '^BF' || true)
if [ -n "${bad_includes}" ]; then
  echo "[ERROR] Non-BF includes detected (use box/BF*.h):"
  printf "%s\n" ${bad_includes}
  fail=1
fi

# 5) tests should be named test_BF*.c (enforced)
bad_tests=$(find test -maxdepth 1 -type f -name 'test_*.c' ! -name 'test_BF*.c' -print || true)
if [ -n "${bad_tests}" ]; then
  echo "[ERROR] Tests must follow 'test_BF*.c' naming:"
  echo "${bad_tests}"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "Naming convention check: FAILED"
  exit 1
fi

echo "Naming convention check: OK"
