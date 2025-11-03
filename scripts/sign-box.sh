#!/usr/bin/env bash

# Signs the release build of the Box executable using the provided
# macOS code-signing identity (defaults to "Developer Apple").

set -euo pipefail

IDENTITY=${1:-"Developer ID Application: Thierry DELHAISE (SB7H9B6TY8)"}
BUILD_ROOT="${BUILD_ROOT:-$(git rev-parse --show-toplevel)}"
EXECUTABLE="${BUILD_ROOT}/.build/release/box"

if [[ ! -f "${EXECUTABLE}" ]]; then
    echo "error: expected executable at ${EXECUTABLE}. Run 'swift build -c release' first." >&2
    exit 1
fi

echo "Signing ${EXECUTABLE} with identity \"${IDENTITY}\"..."
codesign --force --options runtime --sign "${IDENTITY}" "${EXECUTABLE}"
codesign --verify --verbose=2 "${EXECUTABLE}"

echo "Done."
