#!/usr/bin/env bash
set -euo pipefail

if [ -d build ]; then
  echo "Fast build: using existing build/"
  cmake --build build -j || {
    echo "Fast build failed" >&2
    exit 1
  }
else
  echo "Fast build: build/ not found — skipping"
fi

